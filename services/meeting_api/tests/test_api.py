import threading
import uuid
from collections.abc import Iterator
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError
from sqlalchemy.exc import IntegrityError

from app.config import Settings, get_settings
from app.main import create_app
from app.models import Utterance


def upload(client: TestClient, mid: str, index: int = 0, name: str = "a.m4a", data=b"fake-audio"):
    return client.post(
        f"/meetings/{mid}/segments",
        data={"index": index, "start_offset_sec": index * 600.0, "duration_sec": 600.0},
        files={"file": (name, data, "audio/mp4")},
    )


def add_speaker(client: TestClient, mid: str, name: str = "Alice", filename: str = "ref.wav"):
    return client.post(
        f"/meetings/{mid}/speakers",
        data={"display_name": name},
        files={"file": (filename, b"RIFF", "audio/wav")},
    )


def finish(client: TestClient, mid: str, count: int = 2, **extra):
    return client.post(f"/meetings/{mid}/finish", json={"segment_count": count, **extra})


def files_in(path: Path) -> list[Path]:
    return sorted(path.iterdir()) if path.exists() else []


# ---- health, docs, auth -------------------------------------------------------------------


def test_health_without_auth(client: TestClient) -> None:
    r = client.get("/health", headers={"Authorization": ""})
    assert r.status_code == 200
    assert r.json()["status"] == "ok"
    assert r.json()["version"]


def test_docs_disabled_by_default(client: TestClient) -> None:
    for path in ("/docs", "/redoc", "/openapi.json"):
        assert client.get(path).status_code == 404


def test_docs_can_be_enabled(client: TestClient, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ENABLE_DOCS", "true")
    get_settings.cache_clear()
    with TestClient(create_app()) as c:
        c.headers["Authorization"] = client.headers["Authorization"]
        assert c.get("/openapi.json").status_code == 200


ROUTES = [
    ("get", "/meetings"),
    ("post", "/meetings"),
    ("get", "/meetings/{id}"),
    ("post", "/meetings/{id}/segments"),
    ("post", "/meetings/{id}/speakers"),
    ("post", "/meetings/{id}/finish"),
]


@pytest.mark.parametrize("auth", [None, "Bearer nope", "Basic abc"])
@pytest.mark.parametrize(("method", "path"), ROUTES)
def test_auth_required_everywhere(
    client: TestClient, meeting_id: str, method: str, path: str, auth: str | None
) -> None:
    headers = {"Authorization": auth or ""}
    r = client.request(method, path.format(id=meeting_id), headers=headers)
    assert r.status_code == 401
    assert r.headers["www-authenticate"] == "Bearer"
    assert r.json()["detail"]["code"] == "unauthorized"


# ---- config -------------------------------------------------------------------------------


@pytest.mark.parametrize("token", ["change-me", "short", "x" * 31])
def test_weak_token_rejected(token: str) -> None:
    with pytest.raises(ValidationError):
        Settings(meeting_api_token=token)


def test_strong_token_accepted() -> None:
    assert Settings(meeting_api_token="y" * 32).database_url.endswith("meeting_api.db")


# ---- meetings -----------------------------------------------------------------------------


def test_create_meeting(client: TestClient) -> None:
    r = client.post("/meetings", json={"title": "Kickoff"})
    assert r.status_code == 201
    body = r.json()
    assert body["title"] == "Kickoff"
    assert body["status"] == "recording"
    assert body["segments_total"] == 0
    assert body["cost_usd"] == 0.0
    assert body["expected_segments"] is None
    assert body["speakers"] == []


def test_create_meeting_without_body(client: TestClient) -> None:
    assert client.post("/meetings").status_code == 201


def test_unknown_meeting_404(client: TestClient) -> None:
    missing = str(uuid.uuid4())
    r = client.get(f"/meetings/{missing}")
    assert r.status_code == 404
    assert r.json()["detail"]["code"] == "not_found"
    assert upload(client, missing).status_code == 404
    assert add_speaker(client, missing).status_code == 404
    assert finish(client, missing).status_code == 404


def test_non_uuid_path_422(client: TestClient) -> None:
    assert client.get("/meetings/not-a-uuid").status_code == 422


def test_timestamps_are_utc(client: TestClient, meeting_id: str) -> None:
    created = client.get(f"/meetings/{meeting_id}").json()["created_at"]
    assert created.endswith("Z") or created.endswith("+00:00")
    seg = upload(client, meeting_id).json()
    assert seg["created_at"].endswith("Z") or seg["created_at"].endswith("+00:00")


def test_list_with_query(client: TestClient) -> None:
    for title in ["Budget review", "Team standup", "budget planning"]:
        client.post("/meetings", json={"title": title})
    all_items = client.get("/meetings").json()
    assert len(all_items) == 3
    assert all_items[0]["title"] == "budget planning"
    found = client.get("/meetings", params={"q": "BUDGET"}).json()
    assert sorted(m["title"] for m in found) == ["Budget review", "budget planning"]
    assert len(client.get("/meetings", params={"limit": 1, "offset": 1}).json()) == 1
    assert client.get("/meetings", params={"q": "%"}).json() == []


def test_foreign_keys_enforced(client: TestClient) -> None:
    with client.app.state.session_factory() as db:
        db.add(Utterance(meeting_id=str(uuid.uuid4()), start_sec=0, end_sec=1, text="x"))
        with pytest.raises(IntegrityError):
            db.commit()


# ---- segments -----------------------------------------------------------------------------


def test_upload_segment(client: TestClient, meeting_id: str, data_dir: Path) -> None:
    r = upload(client, meeting_id)
    assert r.status_code == 202
    seg = r.json()
    assert seg["status"] == "received"
    path = data_dir / "meetings" / meeting_id / "segments" / f"{seg['id']}.m4a"
    assert path.read_bytes() == b"fake-audio"
    detail = client.get(f"/meetings/{meeting_id}").json()
    assert detail["segments_received"] == 1
    assert detail["segments_total"] == 1
    assert detail["segments_done"] == 0


def test_hostile_filename_stays_inside(client: TestClient, meeting_id: str, data_dir: Path) -> None:
    r = upload(client, meeting_id, name="../../x.m4a")
    assert r.status_code == 202
    seg_dir = data_dir / "meetings" / meeting_id / "segments"
    assert [p.name for p in files_in(seg_dir)] == [f"{r.json()['id']}.m4a"]
    assert not (data_dir / "x.m4a").exists()


def test_duplicate_index_is_idempotent(client: TestClient, meeting_id: str, data_dir: Path) -> None:
    first = upload(client, meeting_id)
    second = upload(client, meeting_id)
    assert first.status_code == 202
    assert second.status_code == 200
    assert second.json()["id"] == first.json()["id"]
    assert len(files_in(data_dir / "meetings" / meeting_id / "segments")) == 1


def test_concurrent_duplicate_uploads(client: TestClient, meeting_id: str, data_dir: Path) -> None:
    barrier = threading.Barrier(2)
    results: list[tuple[int, str]] = []

    def worker() -> None:
        barrier.wait()
        r = upload(client, meeting_id, data=b"x" * 200_000)
        results.append((r.status_code, r.json()["id"]))

    threads = [threading.Thread(target=worker) for _ in range(2)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert len(results) == 2
    assert {code for code, _ in results} <= {200, 202}
    assert len({sid for _, sid in results}) == 1
    assert client.get(f"/meetings/{meeting_id}").json()["segments_total"] == 1
    assert len(files_in(data_dir / "meetings" / meeting_id / "segments")) == 1


def test_bad_extension(client: TestClient, meeting_id: str, data_dir: Path) -> None:
    r = upload(client, meeting_id, name="a.exe")
    assert r.status_code == 422
    assert r.json()["detail"]["code"] == "unsupported_extension"


@pytest.mark.parametrize("index", [-1, 10**20, 10000])
def test_bad_index(client: TestClient, meeting_id: str, index: int) -> None:
    assert upload(client, meeting_id, index=index).status_code == 422


@pytest.mark.parametrize("field", ["start_offset_sec", "duration_sec"])
@pytest.mark.parametrize("value", ["inf", "nan", "-1"])
def test_bad_floats(client: TestClient, meeting_id: str, field: str, value: str) -> None:
    form = {"index": 0, "start_offset_sec": 0, "duration_sec": 1}
    form[field] = value
    r = client.post(
        f"/meetings/{meeting_id}/segments",
        data=form,
        files={"file": ("a.m4a", b"x", "audio/mp4")},
    )
    assert r.status_code == 422


def test_finish_then_late_segment_accepted(client: TestClient, meeting_id: str) -> None:
    r = finish(client, meeting_id, count=2, duration_sec=1234.5)
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "processing"
    assert body["duration_sec"] == 1234.5
    assert body["expected_segments"] == 2
    assert upload(client, meeting_id, index=1).status_code == 202


def test_index_out_of_range(client: TestClient, meeting_id: str, data_dir: Path) -> None:
    finish(client, meeting_id, count=2)
    r = upload(client, meeting_id, index=2)
    assert r.status_code == 409
    assert r.json()["detail"]["code"] == "index_out_of_range"
    assert files_in(data_dir / "meetings" / meeting_id / "segments") == []


def test_finish_validation_and_conflict(client: TestClient, meeting_id: str) -> None:
    assert client.post(f"/meetings/{meeting_id}/finish", json={}).status_code == 422
    assert finish(client, meeting_id, count=0).status_code == 422
    assert finish(client, meeting_id).status_code == 200
    again = finish(client, meeting_id)
    assert again.status_code == 409
    assert again.json()["detail"]["code"] == "meeting_not_recording"


def test_finish_rejects_count_below_uploaded_index(client: TestClient, meeting_id: str) -> None:
    assert upload(client, meeting_id, index=3).status_code == 202
    r = finish(client, meeting_id, count=3)
    assert r.status_code == 409
    assert r.json()["detail"]["code"] == "segment_count_too_small"
    assert finish(client, meeting_id, count=4).status_code == 200


@pytest.mark.parametrize("state", ["merging", "summarizing", "done", "failed"])
def test_closed_meeting_rejects_segments(client: TestClient, meeting_id: str, state: str) -> None:
    with client.app.state.session_factory() as db:
        from app.models import Meeting

        db.get(Meeting, meeting_id).status = state
        db.commit()
    r = upload(client, meeting_id)
    assert r.status_code == 409
    assert r.json()["detail"]["code"] == "meeting_closed"


# ---- speakers -----------------------------------------------------------------------------


def test_speakers_limit(client: TestClient, meeting_id: str, data_dir: Path) -> None:
    for i in range(4):
        r = add_speaker(client, meeting_id, name=f"Person {i}")
        assert r.status_code == 201
        assert r.json()["raw_label"] is None
        assert Path(r.json()["reference_clip_path"]).exists()
    r = add_speaker(client, meeting_id, name="Fifth")
    assert r.status_code == 409
    assert r.json()["detail"]["code"] == "speaker_limit"
    assert len(client.get(f"/meetings/{meeting_id}").json()["speakers"]) == 4
    assert len(files_in(data_dir / "meetings" / meeting_id / "speakers")) == 4


def test_speaker_after_finish(client: TestClient, meeting_id: str) -> None:
    finish(client, meeting_id)
    r = add_speaker(client, meeting_id)
    assert r.status_code == 409
    assert r.json()["detail"]["code"] == "meeting_not_recording"


def test_speaker_bad_extension(client: TestClient, meeting_id: str) -> None:
    assert add_speaker(client, meeting_id, filename="ref.txt").status_code == 422


# ---- size limits (MAX_UPLOAD_MB=1 in the fixture) -----------------------------------------


def test_content_length_rejected_before_body(client: TestClient, meeting_id: str) -> None:
    r = client.post(
        f"/meetings/{meeting_id}/segments",
        content=b"tiny",
        headers={"Content-Length": str(50 * 1024 * 1024), "Content-Type": "multipart/form-data"},
    )
    assert r.status_code == 413


def test_chunked_upload_over_limit(client: TestClient, meeting_id: str, data_dir: Path) -> None:
    boundary = "bnd"
    head = (
        f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="a.m4a"\r\n\r\n'
    ).encode()

    def body() -> Iterator[bytes]:
        yield head
        for _ in range(4):
            yield b"x" * (1024 * 1024)
        yield f"\r\n--{boundary}--\r\n".encode()

    r = client.post(
        f"/meetings/{meeting_id}/segments",
        content=body(),
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
    )
    assert r.status_code == 413
    assert files_in(data_dir / "meetings" / meeting_id / "segments") == []


def test_per_file_limit(client: TestClient, meeting_id: str, data_dir: Path) -> None:
    r = upload(client, meeting_id, data=b"x" * (1024 * 1024 + 1))
    assert r.status_code == 413
    assert files_in(data_dir / "meetings" / meeting_id / "segments") == []
