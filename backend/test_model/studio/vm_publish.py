"""Publish a locally-ingested book by SSHing to the production VM and
running `sync_to_db.py` there directly.

This is the third sync path the studio offers, alongside:
  • /sync         — runs sync_to_db.py LOCALLY (needs MinIO+Postgres on
                    the studio host; fails when those services aren't up)
  • /sync-remote  — pushes through the public REST API (no local infra
                    needed; ~80 round-trips per book; the recommended
                    default for normal volume)
  • /sync-vm      — this module: tar the book → SCP to VM → run
                    sync_to_db.py there. One round-trip for the whole
                    book, runs against MinIO+Postgres on localhost
                    inside the VM. Best for bulk loads or when the API
                    server is rate-limiting you.

Three phases, each explicit and observable:

    PHASE 1: COMPRESS — write storage/{slug}/ to a tar.gz on disk under
              storage/{slug}/_publish/{slug}.tgz. A real file you can
              inspect, retry, or copy by hand if the upload fails.
    PHASE 2: UPLOAD  — SFTP the tarball to /tmp/inkx-{slug}-{ts}.tgz
              on the VM. Streamed from disk via paramiko's put() so we
              don't hold the whole archive in RAM during the transfer.
    PHASE 3: EXTRACT + SYNC — SSH `tar -xzf` to land it under
              {remote_backend_root}/{remote_storage_subdir}/{slug},
              then run sync_to_db.py against the VM's local MinIO
              and Postgres.

Security: paramiko's AutoAddPolicy is fine for trusted-VM dev/admin
use; the studio user is already trusted with the VM's password.
"""

from __future__ import annotations

import asyncio
import shlex
import tarfile
import time
from pathlib import Path
from typing import Any, Awaitable, Callable

import paramiko

from book_ingest import persist


# Where the inkspacex codebase lives on the VM. The studio sends the
# book's storage dir under {remote_backend_root}/{remote_storage_subdir}.
_DEFAULT_REMOTE_BACKEND = "/home/azureuser/write/backend"
_DEFAULT_REMOTE_STORAGE = "test_model/storage/books"
_SSH_TIMEOUT = 30


class VmPublishError(RuntimeError):
    """Wraps SSH/SFTP failures with enough context for the UI to show
    something more useful than the raw paramiko exception."""

    def __init__(self, message: str, *, stage: str | None = None, body: str | None = None):
        super().__init__(message)
        self.stage = stage
        self.body = body


# ---------------------------------------------------------------------------
# PHASE 1 — Compress to disk
# ---------------------------------------------------------------------------

def _compress_book(slug: str) -> Path:
    """Tar+gzip the book's storage dir to a real file on disk.

    Output: storage/{slug}/_publish/{slug}.tgz

    Writing to disk (vs in-memory bytes) means:
      • the artifact is inspectable — `ls -lh` shows the size
      • SFTP can stream from disk via put() instead of holding the
        whole archive in RAM during the upload
      • a failed upload doesn't lose the compression work — re-running
        skips compress when the .tgz is fresh
    """
    book_dir = persist.book_dir(slug)
    if not book_dir.exists():
        raise VmPublishError(f"book dir missing: {book_dir}", stage="compress")

    publish_dir = book_dir / "_publish"
    publish_dir.mkdir(exist_ok=True)
    archive_path = publish_dir / f"{slug}.tgz"

    # If a previous compress is fresher than the newest book artifact,
    # skip — saves 5-30s on retry. We compare against the manifest's
    # mtime as a cheap proxy for "anything in the book changed".
    manifest = book_dir / "manifest.json"
    if archive_path.exists() and manifest.exists():
        if archive_path.stat().st_mtime >= manifest.stat().st_mtime:
            return archive_path

    # arcname = slug so extraction on VM lands at
    # `{remote_storage}/{slug}/...`, not the full local path.
    tmp_path = archive_path.with_suffix(archive_path.suffix + ".part")
    with tarfile.open(tmp_path, mode="w:gz") as tar:
        # filter out the _publish dir itself so the tarball doesn't
        # recursively contain prior tarballs.
        def _skip_publish(tinfo: tarfile.TarInfo) -> tarfile.TarInfo | None:
            parts = Path(tinfo.name).parts
            if "_publish" in parts:
                return None
            return tinfo
        tar.add(book_dir, arcname=slug, filter=_skip_publish)
    tmp_path.replace(archive_path)
    return archive_path


# ---------------------------------------------------------------------------
# SSH execution (blocking paramiko, run in a thread for asyncio)
# ---------------------------------------------------------------------------

def _do_publish_blocking(
    *,
    slug: str,
    vm_ip: str,
    username: str,
    password: str,
    remote_backend_root: str,
    remote_storage_subdir: str,
    archive_path: Path,
    force: bool,
    emit: Callable[[str, dict[str, Any]], None],
) -> dict[str, Any]:
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())

    emit("connecting", {"vm_ip": vm_ip, "user": username})
    try:
        ssh.connect(
            hostname=vm_ip,
            username=username,
            password=password,
            timeout=_SSH_TIMEOUT,
            allow_agent=False,
            look_for_keys=False,
        )
    except paramiko.AuthenticationException as exc:
        raise VmPublishError("SSH authentication failed", stage="connect", body=str(exc))
    except Exception as exc:  # noqa: BLE001
        raise VmPublishError(f"SSH connect failed: {exc}", stage="connect")

    try:
        # ---- PHASE 2: UPLOAD ----
        # Stream the archive from disk via SFTP put() — paramiko handles
        # the chunking and we get a callback for every block written, so
        # the UI sees a real percentage instead of just "uploading".
        archive_size = archive_path.stat().st_size
        remote_archive = f"/tmp/inkx-{slug}-{int(time.time())}.tgz"
        emit("uploading", {
            "local_path": str(archive_path),
            "remote_path": remote_archive,
            "bytes": archive_size,
        })

        sftp = ssh.open_sftp()
        try:
            last_pct = [-1]

            def _put_progress(transferred: int, total: int) -> None:
                if total <= 0:
                    return
                pct = int(transferred * 100 / total)
                # Throttle to every 5% so we don't spam the event log.
                if pct != last_pct[0] and pct % 5 == 0:
                    emit("upload_progress", {
                        "pct": pct,
                        "bytes": transferred,
                        "total": total,
                    })
                    last_pct[0] = pct

            sftp.put(str(archive_path), remote_archive, callback=_put_progress)
        finally:
            sftp.close()
        emit("uploaded", {"bytes": archive_size, "remote_path": remote_archive})

        # ---- PHASE 3: EXTRACT + SYNC on the VM ----
        # Auto-discover the backend root if the configured one doesn't
        # exist. We search common locations + the user's home for a
        # directory containing test_model/sync_to_db.py — that's the
        # unique fingerprint of this codebase. Saves the user from
        # having to figure out the exact path.
        backend_q = shlex.quote(remote_backend_root)
        storage = shlex.quote(remote_storage_subdir)
        archive_q = shlex.quote(remote_archive)
        slug_q = shlex.quote(slug)
        force_flag = " --force" if force else ""

        cmd = (
            f"set -e; "
            # Resolve the backend root: prefer the configured value,
            # then probe a list of candidates, finally `find` under $HOME.
            f"BE={backend_q}; "
            f"if [ ! -d \"$BE\" ]; then "
            f"  for c in \"$HOME/write/backend\" \"$HOME/inkspacex/backend\" "
            f"           \"$HOME/inkx/backend\" \"$HOME/backend\" "
            f"           \"/srv/inkspacex/backend\" \"/opt/inkspacex/backend\"; do "
            f"    if [ -f \"$c/test_model/sync_to_db.py\" ]; then BE=\"$c\"; break; fi; "
            f"  done; "
            f"fi; "
            f"if [ ! -f \"$BE/test_model/sync_to_db.py\" ]; then "
            f"  found=$(find \"$HOME\" -maxdepth 5 -type f -name sync_to_db.py "
            f"                  -path '*/test_model/sync_to_db.py' 2>/dev/null | head -1); "
            f"  if [ -n \"$found\" ]; then BE=$(dirname \"$(dirname \"$found\")\"); fi; "
            f"fi; "
            f"if [ ! -f \"$BE/test_model/sync_to_db.py\" ]; then "
            f"  echo \"ERROR: could not locate test_model/sync_to_db.py — checked $BE and \\$HOME tree\" >&2; "
            f"  exit 2; "
            f"fi; "
            f"echo \"[vm-publish] backend root: $BE\"; "
            f"cd \"$BE\"; "
            f"mkdir -p {storage}; "
            # Extract the tarball — overwrites any previous contents
            # for this slug so re-publishes work.
            f"tar -xzf {archive_q} -C {storage}; "
            # Drop the uploaded archive once extracted; /tmp would
            # otherwise accumulate one tarball per publish.
            f"rm -f {archive_q}; "
            # Pick the right python: prefer .venv if the project has
            # one, fall back to system python3.
            f"if [ -x .venv/bin/python ]; then PY=.venv/bin/python; "
            f"elif [ -x venv/bin/python ]; then PY=venv/bin/python; "
            f"else PY=python3; fi; "
            f"echo \"[vm-publish] python: $PY\"; "
            f"$PY test_model/sync_to_db.py {slug_q}{force_flag}"
        )

        emit("extracting", {
            "remote_archive": remote_archive,
            "extract_to": f"<auto-resolved>/{remote_storage_subdir}",
        })
        emit("executing", {"cmd": cmd[:200] + ("…" if len(cmd) > 200 else "")})

        stdin, stdout, stderr = ssh.exec_command(cmd, get_pty=False, timeout=600)
        # Drain stdout line-by-line so the UI sees sync_to_db.py's
        # progress in real time.
        out_chunks: list[str] = []
        for line in iter(stdout.readline, ""):
            out_chunks.append(line)
            stripped = line.rstrip()
            if stripped:
                emit("stdout", {"line": stripped[:300]})
        exit_code = stdout.channel.recv_exit_status()
        stderr_text = stderr.read().decode("utf-8", errors="replace")

        emit("finished", {"exit": exit_code, "stderr_bytes": len(stderr_text)})

        return {
            "ok": exit_code == 0,
            "exit_code": exit_code,
            "stdout": "".join(out_chunks),
            "stderr": stderr_text,
            "archive_path": str(archive_path),
            "archive_bytes": archive_size,
        }
    finally:
        try:
            ssh.close()
        except Exception:  # noqa: BLE001
            pass


# ---------------------------------------------------------------------------
# Public async entry point
# ---------------------------------------------------------------------------

async def publish_to_vm(
    slug: str,
    *,
    vm_ip: str,
    username: str,
    password: str,
    remote_backend_root: str = _DEFAULT_REMOTE_BACKEND,
    remote_storage_subdir: str = _DEFAULT_REMOTE_STORAGE,
    force: bool = False,
    on_event: Callable[[str, dict[str, Any]], Awaitable[None] | None] | None = None,
) -> dict[str, Any]:
    """Three explicit phases:

        1. COMPRESS  → write storage/{slug}/_publish/{slug}.tgz on disk
        2. UPLOAD    → SFTP put the file to /tmp on the VM
        3. EXTRACT   → SSH `tar -xzf` + run sync_to_db.py on the VM

    `on_event(name, payload)` fires at every milestone so the studio
    UI can show live progress. Sync or async callbacks both work.
    """
    loop = asyncio.get_running_loop()

    async def _emit(name: str, payload: dict[str, Any]) -> None:
        if not on_event:
            return
        result = on_event(name, payload)
        if asyncio.iscoroutine(result):
            await result

    def _sync_emit(name: str, payload: dict[str, Any]) -> None:
        # paramiko's blocking I/O runs in a thread executor; bridge
        # back to the asyncio loop so the user's async callback runs
        # on the main loop.
        asyncio.run_coroutine_threadsafe(_emit(name, payload), loop)

    # ---- PHASE 1: COMPRESS ----
    await _emit("compressing", {"slug": slug})
    archive_path = await loop.run_in_executor(None, _compress_book, slug)
    archive_size = archive_path.stat().st_size
    await _emit("compressed", {
        "path": str(archive_path),
        "bytes": archive_size,
        "human": _human_size(archive_size),
    })

    # ---- PHASE 2 + 3 (PHASE 2 happens inside the blocking helper so
    # SFTP and SSH can share one connection) ----
    result = await loop.run_in_executor(
        None,
        lambda: _do_publish_blocking(
            slug=slug,
            vm_ip=vm_ip,
            username=username,
            password=password,
            remote_backend_root=remote_backend_root,
            remote_storage_subdir=remote_storage_subdir,
            archive_path=archive_path,
            force=force,
            emit=_sync_emit,
        ),
    )

    await _emit("done", result)
    return result


def _human_size(n: int) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024:
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} TB"
