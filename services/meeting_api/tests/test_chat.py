"""AI에게 질문하기: context, citations, web sources, history, failures."""

from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.models import LiveCaption
from tests.fakes import FakeTranscriber, drain, make_wav, upload_wav


@pytest.fixture
def wav(tmp_path: Path) -> Path:
    return make_wav(tmp_path / "in.wav")


@pytest.fixture
def ai(client: TestClient) -> FakeTranscriber:
    fake = FakeTranscriber()
    client.app.state.transcriber = fake
    return fake


def test_chat_requires_ai(client: TestClient, meeting_id: str) -> None:
    r = client.post(f"/meetings/{meeting_id}/chat", json={"question": "뭐였지?"})
    assert r.status_code == 503 and r.json()["detail"]["code"] == "ai_unavailable"


def test_chat_answers_with_resolved_citations(
    client: TestClient, meeting_id: str, wav: Path, ai: FakeTranscriber
) -> None:
    upload_wav(client, meeting_id, wav, 0)
    client.post(f"/meetings/{meeting_id}/finish", json={"segment_count": 1})
    drain(client, ai)

    r = client.post(f"/meetings/{meeting_id}/chat", json={"question": "무슨 얘기를 했어?"})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["role"] == "assistant" and "[00:00]" in body["content"]
    transcript_sources = [s for s in body["sources"] if s["kind"] == "transcript"]
    assert transcript_sources == [
        {
            "kind": "transcript",
            "at_sec": 0.0,
            "speaker": "참석자 1",
            "text": "안녕하세요",
            "title": None,
            "url": None,
        }
    ]
    context, history, question, web = ai.asks[0]
    assert (
        "[00:00] 참석자 1: 안녕하세요" in context
        and "한 줄 요약: 두 사람이 인사를 나눴다." in context
    )
    assert history == [] and question == "무슨 얘기를 했어?" and web is False

    # second question carries the first exchange as history; web sources come back
    r2 = client.post(
        f"/meetings/{meeting_id}/chat", json={"question": "웹에서 찾아줘", "web_search": True}
    )
    web_sources = [s for s in r2.json()["sources"] if s["kind"] == "web"]
    assert web_sources[0]["url"] == "https://example.com/a"
    _, history2, _, web2 = ai.asks[1]
    assert [role for role, _ in history2] == ["user", "assistant"] and web2 is True

    listed = client.get(f"/meetings/{meeting_id}/chat").json()
    assert [m["role"] for m in listed] == ["user", "assistant", "user", "assistant"]
    assert client.get(f"/meetings/{meeting_id}").json()["chat_count"] == 4
    assert client.get(f"/meetings/{meeting_id}").json()["cost_usd"] > 0.01  # web search fee

    assert client.delete(f"/meetings/{meeting_id}/chat").status_code == 204
    assert client.get(f"/meetings/{meeting_id}/chat").json() == []


def test_chat_during_recording_uses_live_captions(
    client: TestClient, meeting_id: str, ai: FakeTranscriber
) -> None:
    with client.app.state.session_factory() as db:
        db.add(LiveCaption(meeting_id=meeting_id, at_sec=75.0, text="출시는 금요일로 하죠"))
        db.commit()
    ai.answer = "금요일로 정했습니다 [01:15]."
    r = client.post(f"/meetings/{meeting_id}/chat", json={"question": "출시일은?"})
    assert r.status_code == 200
    assert "[01:15] (실시간): 출시는 금요일로 하죠" in ai.asks[0][0]
    src = r.json()["sources"][0]
    assert src["speaker"] == "실시간 자막" and src["at_sec"] == 75.0


def test_chat_failure_does_not_leave_a_dangling_question(
    client: TestClient, meeting_id: str, ai: FakeTranscriber
) -> None:
    ai.ask_error = RuntimeError("rate limited")
    r = client.post(f"/meetings/{meeting_id}/chat", json={"question": "질문"})
    assert r.status_code == 502 and r.json()["detail"]["code"] == "ai_failed"
    assert client.get(f"/meetings/{meeting_id}/chat").json() == []


def test_parse_citations() -> None:
    from app.pipeline import parse_citations

    assert parse_citations("a [00:05] b [12:34] c [1:02:03] d [00:05]") == [5.0, 754.0, 3723.0]
