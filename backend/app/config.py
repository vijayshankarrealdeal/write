from pydantic import Field, field_validator
from pydantic_settings import BaseSettings


_INSECURE_JWT_PLACEHOLDERS = {
    "",
    "change-this-to-a-random-secret-in-production",
    "changeme",
}


class Settings(BaseSettings):
    database_url: str = "postgresql+asyncpg://inkspacex:changeme@localhost:5432/inkspacex"

    # Tags every AppLog row so the admin viewer can filter dev vs prod
    # noise. Read from ENV — local .env keeps it "dev"; the GitHub Actions
    # deploy overlays ENV=prod from a repo secret.
    environment: str = Field(default="dev", validation_alias="ENV")

    jwt_secret: str
    jwt_algorithm: str = "HS256"
    access_token_expire_minutes: int = 15
    refresh_token_expire_days: int = 30

    admin_username: str
    admin_password: str

    minio_endpoint: str = "localhost:9000"
    minio_access_key: str = "minioadmin"
    minio_secret_key: str = "minioadmin"
    minio_bucket: str = "inkspacex"
    minio_use_ssl: bool = False
    minio_public_url: str = "http://localhost:9000"

    google_client_id: str = ""
    google_client_secret: str = ""
    google_oauth_redirect_uri: str = ""
    frontend_origin: str = ""
    cors_origins: str = "http://localhost:3000,http://localhost:8080,http://localhost:5174"

    azure_openai_api_key: str = ""
    azure_openai_endpoint: str = ""
    azure_openai_api_version: str = "2024-12-01-preview"
    azure_openai_chat_deployment: str = "gpt-5.4-mini"
    azure_openai_embedding_deployment: str = "text-embedding-ada-002"
    embedding_dim: int = 1536

    # Offline downloads (Phase 4): base64-encoded 32-byte Ed25519 seed.
    # Empty disables the feature — the offline router returns 503 in
    # that case so a misconfigured deployment fails loudly, not quietly.
    inkx_license_signing_key: str = ""

    # Redis pub/sub for SSE fanout across multiple Uvicorn workers. Empty
    # falls back to the in-memory hub (single-worker dev). Required when
    # running with --workers >1, otherwise SSE subscribers on workers
    # other than the one handling a mutation go silent.
    redis_url: str = ""

    # `extra="ignore"` matches prod's docker-compose `environment:` injection (which
    # passes vars not declared here, e.g. AZURE_OPENAI_MAP_DEPLOYMENT consumed by
    # app.ai.* via os.getenv). Without it, env_file loads (local dev) reject those.
    # `populate_by_name=True` so the `ENV` validation_alias on `environment`
    # doesn't block reading the field by its python name in tests.
    model_config = {"env_file": ".env", "extra": "ignore", "populate_by_name": True}

    @field_validator("jwt_secret")
    @classmethod
    def _reject_placeholder_jwt(cls, v: str) -> str:
        if v.strip().lower() in _INSECURE_JWT_PLACEHOLDERS or len(v) < 32:
            raise ValueError(
                "JWT_SECRET must be set to a random value of at least 32 characters "
                "(e.g. `openssl rand -hex 32`)."
            )
        return v

    @field_validator("admin_password")
    @classmethod
    def _reject_weak_admin_password(cls, v: str) -> str:
        if len(v) < 12:
            raise ValueError(
                "ADMIN_PASSWORD must be at least 12 characters. Set it in .env."
            )
        return v


settings = Settings()
