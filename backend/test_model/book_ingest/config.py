"""Runtime config — Azure image generation + optional SSH deploy.

Claude Code does all the text work; the backend only needs Azure for
image generation, and (optionally) SSH credentials for pushing finished
books to a remote VM.
"""
from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


def _load_dotenv() -> None:
    """Load `.env` at the project root into os.environ (without overwriting
    existing shell exports). Plain implementation — no python-dotenv dep."""
    root = Path(__file__).resolve().parent.parent
    env_path = root / ".env"
    if not env_path.is_file():
        return
    for raw in env_path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        os.environ.setdefault(
            key.strip(),
            value.strip().strip('"').strip("'"),
        )


_load_dotenv()


_PROJECT_ROOT = Path(__file__).resolve().parent.parent


@dataclass(frozen=True)
class Config:
    # ── Azure image generation (gpt-image-2 or newer on Azure) ─────────
    azure_image_endpoint: str = os.getenv(
        "AZURE_IMAGE_ENDPOINT", "",
    ).rstrip("/")
    azure_image_api_key: str = os.getenv("AZURE_IMAGE_API_KEY", "")
    azure_image_deployment: str = os.getenv(
        "AZURE_IMAGE_DEPLOYMENT", "gpt-image-2",
    )
    azure_image_api_version: str = os.getenv(
        "AZURE_IMAGE_API_VERSION", "2024-02-01",
    )
    # /images/edits (with-refs) needs a newer api-version on Azure.
    azure_image_edits_api_version: str = os.getenv(
        "AZURE_IMAGE_EDITS_API_VERSION", "2025-04-01-preview",
    )

    # ── Storage / studio ──────────────────────────────────────────────
    storage_root: str = os.getenv(
        "STORAGE_ROOT",
        str(_PROJECT_ROOT / "storage" / "books"),
    )
    studio_port: int = int(os.getenv("STUDIO_PORT", "8765"))

    # ── SSH deploy target (optional) ──────────────────────────────────
    ssh_host: str = os.getenv("DEPLOY_SSH_HOST", "")
    ssh_user: str = os.getenv("DEPLOY_SSH_USER", "")
    ssh_password: str = os.getenv("DEPLOY_SSH_PASSWORD", "")
    # Unused by the new deploy path (book_ingest/deploy.py auto-resolves
    # the backend root on the VM). Kept for back-compat / health probe.
    ssh_remote_path: str = os.getenv(
        "DEPLOY_REMOTE_PATH",
        "/home/azureuser/inkspacex/backend/test_model/storage/books",
    )


config = Config()
