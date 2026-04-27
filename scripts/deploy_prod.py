#!/usr/bin/env python3
"""Production deploy wrapper.

Reads SSH credentials from `.deploy.secrets` (gitignored), one-time
bootstraps key-based auth on the remote (so future ssh/rsync calls
don't need the password), then execs `./deploy.sh` with `SSH_HOST` /
`SSH_KEY` set so the existing build-and-ship pipeline works as-is.

Idempotent: re-running just verifies the key is in place and re-runs
the deploy.

Run from repo root:
    /home/verti/miniconda3/bin/python scripts/deploy_prod.py
"""
from __future__ import annotations

import os
import shlex
import subprocess
import sys
from pathlib import Path

import paramiko

REPO_ROOT = Path(__file__).resolve().parent.parent
SECRETS = REPO_ROOT / ".deploy.secrets"


def load_secrets() -> dict[str, str]:
    if not SECRETS.exists():
        sys.exit(f"missing {SECRETS} — see deploy.sh header for required vars")
    out: dict[str, str] = {}
    for raw in SECRETS.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[k.strip()] = v.strip().strip('"').strip("'")
    return out


def ensure_keypair(key_path: Path) -> None:
    """Generate an ed25519 keypair at `key_path` if missing."""
    if key_path.exists():
        return
    key_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    subprocess.run(
        ["ssh-keygen", "-t", "ed25519", "-N", "", "-C", "inkspacex-deploy",
         "-f", str(key_path)],
        check=True,
    )


def install_pubkey(host: str, user: str, password: str, pubkey: str) -> None:
    """Append `pubkey` to remote ~/.ssh/authorized_keys if not already present.

    Uses paramiko with password auth — this is the one and only time the
    password leaves the local machine. After this, deploy.sh runs with
    key-based auth.
    """
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(
        host, username=user, password=password,
        look_for_keys=False, allow_agent=False, timeout=30,
    )
    try:
        # Idempotent install: mkdir, touch, grep-or-append. Single command so
        # a stale ~/.ssh perms can't leave us in a half-set-up state.
        quoted = shlex.quote(pubkey)
        cmd = (
            "set -e; "
            "mkdir -p ~/.ssh && chmod 700 ~/.ssh; "
            "touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys; "
            f"grep -qxF {quoted} ~/.ssh/authorized_keys "
            f"|| echo {quoted} >> ~/.ssh/authorized_keys; "
            "echo OK"
        )
        _, stdout, stderr = client.exec_command(cmd, timeout=30)
        out = stdout.read().decode().strip()
        err = stderr.read().decode().strip()
        if out != "OK":
            sys.exit(f"pubkey install failed: out={out!r} err={err!r}")
    finally:
        client.close()


def main() -> int:
    creds = load_secrets()
    ssh_host = creds.get("SSH_HOST")
    password = creds.get("SSH_PASSWORD")
    key_path = Path(creds.get("SSH_KEY") or (Path.home() / ".ssh" / "inkspacex_prod"))
    if not ssh_host or "@" not in ssh_host or not password:
        sys.exit("SSH_HOST (user@host) and SSH_PASSWORD are required in .deploy.secrets")
    user, host = ssh_host.split("@", 1)

    print(f"→ ensuring keypair at {key_path}")
    ensure_keypair(key_path)
    pubkey = key_path.with_suffix(".pub").read_text().strip()

    print(f"→ ensuring pubkey is on {ssh_host}")
    install_pubkey(host, user, password, pubkey)

    print("→ running deploy.sh with key-based auth")
    env = os.environ.copy()
    env["SSH_HOST"] = ssh_host
    env["SSH_KEY"] = str(key_path)
    rc = subprocess.run(["./deploy.sh"], cwd=REPO_ROOT, env=env).returncode
    return rc


if __name__ == "__main__":
    sys.exit(main())
