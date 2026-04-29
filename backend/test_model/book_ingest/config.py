"""Runtime config for the ingest pipeline.

Reads from env vars first, falls back to the backend's `app.config.settings`
when imported alongside the FastAPI app. The image-generation deployment is
distinct from the chat deployment, so it gets its own keys.

Loads `<repo-root>/.env` at import time so a fresh `uvicorn` (or any
direct `python` invocation of these scripts) picks up the file without
needing the parent FastAPI app to have been imported first. uvicorn's
`--reload` only watches Python files; if the user edits `.env` they must
still restart the process, but at least the values are read on startup.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


def _load_dotenv_once() -> None:
    """Load /home/.../write/.env (the repo root) into os.environ if not
    already set. Walks up from this file's location to find the first
    `.env`. We don't depend on python-dotenv to keep this importable in
    a stripped-down env."""
    here = Path(__file__).resolve()
    for ancestor in (here, *here.parents):
        candidate = ancestor / ".env"
        if not candidate.is_file():
            continue
        try:
            for raw in candidate.read_text(encoding="utf-8").splitlines():
                line = raw.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" not in line:
                    continue
                key, _, value = line.partition("=")
                key = key.strip()
                value = value.strip().strip('"').strip("'")
                # Existing env wins so a real shell export can override
                # the file (e.g. for one-off runs).
                os.environ.setdefault(key, value)
        except OSError:
            pass
        return


_load_dotenv_once()


def _env(name: str, default: str = "") -> str:
    return os.getenv(name, default)


@dataclass(frozen=True)
class IngestConfig:
    # --- chat (map + reduce) ---
    azure_endpoint: str = _env("AZURE_OPENAI_ENDPOINT")
    azure_api_key: str = _env("AZURE_OPENAI_API_KEY")
    azure_api_version: str = _env("AZURE_OPENAI_API_VERSION", "2024-12-01-preview")
    map_deployment: str = _env("AZURE_OPENAI_MAP_DEPLOYMENT", "gpt-4o-mini")
    reduce_deployment: str = _env("AZURE_OPENAI_REDUCE_DEPLOYMENT", "gpt-4o")

    # --- embeddings (often a separate Azure resource — Microsoft commonly
    # deploys text-embedding-* on a different account from chat). Falls
    # back to the chat endpoint/key when the embedding-specific env vars
    # are unset, so a single-resource setup still works. ---
    azure_embedding_endpoint: str = _env(
        "AZURE_OPENAI_EMBEDDING_ENDPOINT",
        _env("AZURE_OPENAI_ENDPOINT"),
    )
    azure_embedding_api_key: str = _env(
        "AZURE_OPENAI_EMBEDDING_API_KEY",
        _env("AZURE_OPENAI_API_KEY"),
    )
    azure_embedding_api_version: str = _env(
        "AZURE_OPENAI_EMBEDDING_API_VERSION",
        _env("AZURE_OPENAI_API_VERSION", "2024-12-01-preview"),
    )
    embedding_deployment: str = _env(
        "AZURE_OPENAI_EMBEDDING_DEPLOYMENT",
        "text-embedding-ada-002",
    )

    # --- image generation (lifted from test.ipynb) ---
    image_endpoint: str = _env(
        "AZURE_IMAGE_ENDPOINT",
        "https://suppo-mnrzep2b-eastus2.cognitiveservices.azure.com",
    )
    image_api_key: str = _env("AZURE_IMAGE_API_KEY")
    image_deployment: str = _env("AZURE_IMAGE_DEPLOYMENT", "gpt-image-2")
    image_api_version: str = _env("AZURE_IMAGE_API_VERSION", "2024-02-01")

    # --- pipeline tuning (defaults assume a high-throughput Azure deployment;
    # cost is not the constraint, wallclock is) ---
    map_parallelism: int = int(_env("INGEST_MAP_PARALLELISM", "16"))
    reduce_parallelism: int = int(_env("INGEST_REDUCE_PARALLELISM", "12"))
    image_parallelism: int = int(_env("INGEST_IMAGE_PARALLELISM", "6"))
    embed_parallelism: int = int(_env("INGEST_EMBED_PARALLELISM", "16"))
    cleaner_parallelism: int = int(_env("INGEST_CLEANER_PARALLELISM", "16"))
    reduce_top_fraction: float = float(_env("INGEST_REDUCE_TOP_FRACTION", "0.20"))
    default_image_budget: int = int(_env("INGEST_IMAGE_BUDGET", "30"))

    # --- cleaner agent: cheap model that rewrites raw PDF-extracted text
    # into clean readable markdown before any other phase touches it. ---
    cleaner_deployment: str = _env("AZURE_OPENAI_CLEANER_DEPLOYMENT", "gpt-5.4-mini")
    # The cleaner deployment is currently only on the clarity-analytic
    # Azure resource (same one as embeddings), not the suppo-mnrzep2b
    # chat resource. Default the cleaner endpoint/key to the embedding
    # resource and allow explicit override.
    cleaner_endpoint: str = _env(
        "AZURE_OPENAI_CLEANER_ENDPOINT",
        _env("AZURE_OPENAI_EMBEDDING_ENDPOINT")
        or _env("AZURE_OPENAI_ENDPOINT"),
    )
    cleaner_api_key: str = _env(
        "AZURE_OPENAI_CLEANER_API_KEY",
        _env("AZURE_OPENAI_EMBEDDING_API_KEY")
        or _env("AZURE_OPENAI_API_KEY"),
    )
    cleaner_api_version: str = _env(
        "AZURE_OPENAI_CLEANER_API_VERSION",
        _env("AZURE_OPENAI_EMBEDDING_API_VERSION")
        or _env("AZURE_OPENAI_API_VERSION", "2024-12-01-preview"),
    )
    storage_root: str = _env(
        "INGEST_STORAGE_ROOT",
        os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "storage", "books"),
    )


config = IngestConfig()
