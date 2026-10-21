import os
from collections.abc import Iterator
from pathlib import Path

import pytest

TOKEN = "a1" * 32  # 64 hex chars

# app.main builds a module-level app at import time, which reads Settings.
os.environ.setdefault("MEETING_API_TOKEN", TOKEN)

from fastapi.testclient import TestClient  # noqa: E402

from app.config import get_settings  # noqa: E402
from app.main import create_app  # noqa: E402


@pytest.fixture
def data_dir(tmp_path: Path) -> Path:
    return tmp_path / "data"


@pytest.fixture
def client(monkeypatch: pytest.MonkeyPatch, data_dir: Path) -> Iterator[TestClient]:
    monkeypatch.setenv("MEETING_API_TOKEN", TOKEN)
    monkeypatch.setenv("DATA_DIR", str(data_dir))
    monkeypatch.setenv("MAX_UPLOAD_MB", "1")
    monkeypatch.setenv("WORKER_ENABLED", "false")
    monkeypatch.delenv("DATABASE_URL", raising=False)
    monkeypatch.delenv("ENABLE_DOCS", raising=False)
    get_settings.cache_clear()
    with TestClient(create_app()) as c:
        c.headers["Authorization"] = f"Bearer {TOKEN}"
        yield c
    get_settings.cache_clear()


@pytest.fixture
def meeting_id(client: TestClient) -> str:
    return client.post("/meetings", json={"title": "Weekly sync"}).json()["id"]
