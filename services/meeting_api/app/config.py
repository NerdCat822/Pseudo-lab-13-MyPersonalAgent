from functools import lru_cache
from pathlib import Path

from pydantic import field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    meeting_api_token: str
    data_dir: Path = Path("data")
    database_url: str = ""
    max_upload_mb: int = 200
    enable_docs: bool = False

    # Transcription / summary pipeline (W2)
    openai_api_key: str = ""
    transcribe_model: str = "gpt-4o-transcribe-diarize"
    summary_model: str = "gpt-5-mini"
    worker_enabled: bool = True
    worker_poll_sec: float = 2.0
    segment_max_retries: int = 3

    @field_validator("meeting_api_token")
    @classmethod
    def _strong_token(cls, value: str) -> str:
        if value == "change-me" or len(value) < 32:
            raise ValueError(
                "MEETING_API_TOKEN must be at least 32 characters (try: openssl rand -hex 32)"
            )
        return value

    @model_validator(mode="after")
    def _default_database_url(self) -> "Settings":
        if not self.database_url:
            self.database_url = f"sqlite:///{self.data_dir / 'meeting_api.db'}"
        return self

    @property
    def max_upload_bytes(self) -> int:
        return self.max_upload_mb * 1024 * 1024


@lru_cache
def get_settings() -> Settings:
    return Settings()
