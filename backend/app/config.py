from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    database_url: str = "postgresql+asyncpg://inkspacex:changeme@localhost:5432/inkspacex"

    jwt_secret: str = "change-this-to-a-random-secret-in-production"
    jwt_algorithm: str = "HS256"
    access_token_expire_minutes: int = 15
    refresh_token_expire_days: int = 30

    minio_endpoint: str = "localhost:9000"
    minio_access_key: str = "minioadmin"
    minio_secret_key: str = "minioadmin"
    minio_bucket: str = "inkspacex"
    minio_use_ssl: bool = False
    minio_public_url: str = "http://localhost:9000"

    google_client_id: str = ""
    cors_origins: str = "http://localhost:3000,http://localhost:8080,http://localhost:5174"

    azure_openai_api_key: str = ""
    azure_openai_endpoint: str = ""
    azure_openai_api_version: str = "2024-12-01-preview"
    azure_openai_chat_deployment: str = "gpt-4o"
    azure_openai_embedding_deployment: str = "text-embedding-ada-002"

    model_config = {"env_file": ".env"}


settings = Settings()
