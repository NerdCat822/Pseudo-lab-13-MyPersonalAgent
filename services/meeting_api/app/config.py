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

    # Transcription / summary pipeline
    openai_api_key: str = ""
    transcribe_model: str = "gpt-4o-transcribe-diarize"
    summary_model: str = "gpt-5-mini"
    chat_model: str = "gpt-5-mini"
    worker_enabled: bool = True
    worker_poll_sec: float = 2.0
    segment_max_retries: int = 3
    # Long uploads (imported files) are cut into chunks of at most this many seconds before
    # diarization; speaker reference clips carry speaker identity across chunks.
    transcribe_chunk_sec: int = 600
    auto_speaker_refs: bool = True

    # Live captions (server relays app audio to the OpenAI Realtime transcription API)
    live_transcribe_model: str = "gpt-live-transcribe"
    live_languages: str = "ko"  # comma-separated ISO codes
    live_delay: str = "low"  # minimal | low | medium | high | xhigh
    openai_realtime_url: str = "wss://api.openai.com/v1/realtime?intent=transcription"
    # A periodic "실시간 요약" is produced once this much new caption text and time accumulated.
    live_summary_min_chars: int = 300
    live_summary_min_sec: float = 120.0

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

    @property
    def live_language_list(self) -> list[str]:
        return [c.strip() for c in self.live_languages.split(",") if c.strip()]


@lru_cache
def get_settings() -> Settings:
    return Settings()
