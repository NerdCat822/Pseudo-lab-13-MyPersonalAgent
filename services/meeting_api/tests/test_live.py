"""Live captions relay: endpointing, the WebSocket protocol, storage and live summaries."""

import asyncio
import json
import math
import struct

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from app.live import EnergyVad, UpstreamClosed, frame_db, session_update
from app.models import LiveCaption, LiveSummary, MeetingStatus, UsageLog
from tests.conftest import TOKEN
from tests.fakes import FakeTranscriber

RATE = 24000


def tone(seconds: float, amp: int = 9000) -> bytes:
    n = int(RATE * seconds)
    return b"".join(
        struct.pack("<h", int(amp * math.sin(2 * math.pi * 220 * i / RATE))) for i in range(n)
    )


def silence(seconds: float) -> bytes:
    return b"\x00\x00" * int(RATE * seconds)


def kinds(actions):
    return [k for k, _ in actions if k != "send"]


def test_frame_db_levels() -> None:
    assert frame_db(silence(0.05)) == pytest.approx(-90.3, abs=0.5)
    assert -15 < frame_db(tone(0.05)) < -10


def test_vad_commits_after_pause_and_skips_silence() -> None:
    vad = EnergyVad()
    actions = vad.feed(silence(1.0) + tone(1.0) + silence(1.2) + tone(0.6) + silence(1.0))
    assert kinds(actions) == ["speech_start", "commit", "speech_start", "commit"]
    starts = [v for k, v in actions if k == "speech_start"]
    assert starts[0] == pytest.approx(1000, abs=60)
    sent = sum(len(v) for k, v in actions if k == "send")
    # forwarded: 0.3 s pre-roll + 1.0 s speech + 0.8 s hangover, twice (0.6 s speech the 2nd
    # time); the leading 0.7 s, 0.1 s of the gap and the last 0.2 s of silence are skipped
    assert sent == int(RATE * 2 * (0.3 + 1.0 + 0.8 + 0.3 + 0.6 + 0.8))


def test_vad_short_blip_is_not_committed_and_long_turn_is_cut() -> None:
    vad = EnergyVad()
    assert kinds(vad.feed(silence(0.5) + tone(0.15) + silence(1.0))) == ["speech_start", "cancel"]
    vad2 = EnergyVad(max_turn_ms=2000)
    assert kinds(vad2.feed(tone(4.5))) == [
        "speech_start", "commit", "speech_start", "commit", "speech_start",
    ]  # fmt: skip
    assert kinds(vad2.flush()) == ["commit"]


def test_session_update_shape(client: TestClient) -> None:
    from app.config import get_settings

    event = session_update(get_settings())
    inp = event["session"]["audio"]["input"]
    assert event["session"]["type"] == "transcription"
    assert inp["format"] == {"type": "audio/pcm", "rate": 24000}
    assert inp["transcription"]["model"] == "gpt-live-transcribe"
    assert inp["transcription"]["languages"] == ["ko"] and "language" not in inp["transcription"]
    assert inp["turn_detection"] is None


class FakeUpstream:
    """Echoes a transcript for every commit, like gpt-live-transcribe would."""

    instances: list["FakeUpstream"] = []

    def __init__(self, texts: list[str]) -> None:
        self.events: asyncio.Queue = asyncio.Queue()
        self.sent: list[dict] = []
        self.texts = texts
        self.n = 0
        self.closed = False
        FakeUpstream.instances.append(self)

    async def send(self, event: dict) -> None:
        if self.closed:
            raise UpstreamClosed("closed")
        self.sent.append(event)
        if event["type"] == "input_audio_buffer.commit":
            item = f"item_{len(FakeUpstream.instances)}_{self.n}"
            text = self.texts[self.n % len(self.texts)]
            self.n += 1
            await self.events.put(
                {
                    "type": "conversation.item.input_audio_transcription.delta",
                    "item_id": item,
                    "delta": text[:2],
                }
            )
            await self.events.put({"type": "input_audio_buffer.committed", "item_id": item})
            await self.events.put(
                {
                    "type": "conversation.item.input_audio_transcription.completed",
                    "item_id": item,
                    "transcript": text,
                }
            )

    async def recv(self) -> dict:
        event = await self.events.get()
        if event is None:
            raise UpstreamClosed("closed")
        return event

    async def close(self) -> None:
        self.closed = True
        await self.events.put(None)


@pytest.fixture
def live(client: TestClient, monkeypatch: pytest.MonkeyPatch):
    from app.config import get_settings

    monkeypatch.setenv("LIVE_SUMMARY_MIN_CHARS", "20")
    monkeypatch.setenv("LIVE_SUMMARY_MIN_SEC", "1")
    get_settings.cache_clear()
    FakeUpstream.instances = []
    texts = ["출시는 다음 주 금요일입니다", "저는 업로드 대기열을 맡겠습니다"]

    async def factory(settings):
        return FakeUpstream(texts)

    fake_ai = FakeTranscriber()
    client.app.state.live_upstream_factory = factory
    client.app.state.transcriber = fake_ai
    return fake_ai


def ws_headers() -> dict[str, str]:
    return {"Authorization": f"Bearer {TOKEN}"}


def collect_until_closed(ws) -> list[dict]:
    events = []
    while True:
        event = ws.receive_json()
        events.append(event)
        if event["type"] == "closed":
            return events


def test_live_relay_end_to_end(client: TestClient, meeting_id: str, live: FakeTranscriber) -> None:
    with client.websocket_connect(
        f"/meetings/{meeting_id}/live?offset=30", headers=ws_headers()
    ) as ws:
        assert ws.receive_json() == {"type": "status", "state": "ready"}
        audio = silence(0.5) + tone(1.0) + silence(1.0) + tone(1.0) + silence(1.0)
        for i in range(0, len(audio), 4800):
            ws.send_bytes(audio[i : i + 4800])
        ws.send_text(json.dumps({"type": "stop"}))
        events = collect_until_closed(ws)

    finals = [e for e in events if e["type"] == "final"]
    assert [f["text"] for f in finals] == [
        "출시는 다음 주 금요일입니다",
        "저는 업로드 대기열을 맡겠습니다",
    ]
    assert finals[0]["at_sec"] == pytest.approx(30.5, abs=0.1)  # offset + speech start
    assert finals[1]["at_sec"] == pytest.approx(32.5, abs=0.1)
    assert any(e["type"] == "partial" for e in events)
    summaries = [e for e in events if e["type"] == "summary"]
    assert summaries and summaries[0]["bullets"] == ["인사를 나눔"]

    upstream = FakeUpstream.instances[0]
    appended = sum(
        len(e["audio"]) for e in upstream.sent if e["type"] == "input_audio_buffer.append"
    )
    assert appended > 0 and upstream.closed
    with client.app.state.session_factory() as db:
        assert [c.text for c in db.query(LiveCaption).order_by(LiveCaption.at_sec)] == [
            f["text"] for f in finals
        ]
        assert db.query(LiveSummary).count() == len(summaries)
        assert db.query(UsageLog).filter(UsageLog.model == "gpt-live-transcribe").count() == 1
    detail = client.get(f"/meetings/{meeting_id}").json()
    assert detail["live_caption_count"] == 2
    assert detail["live_summaries"][0]["text"] == "인사를 나눔"
    listed = client.get(f"/meetings/{meeting_id}/live-captions").json()
    assert [c["text"] for c in listed] == [f["text"] for f in finals]
    sid = detail["live_summaries"][0]["id"]
    r = client.patch(f"/meetings/{meeting_id}/live-summaries/{sid}", json={"text": "고친 요약"})
    assert r.status_code == 200 and r.json()["text"] == "고친 요약"


def test_live_reconnects_when_upstream_drops(client: TestClient, meeting_id: str, live) -> None:
    with client.websocket_connect(f"/meetings/{meeting_id}/live", headers=ws_headers()) as ws:
        assert ws.receive_json()["state"] == "ready"
        first = silence(0.3) + tone(1.0) + silence(1.0)
        for i in range(0, len(first), 4800):
            ws.send_bytes(first[i : i + 4800])
        assert ws.receive_json()["type"] in {"partial", "final"}
        # the OpenAI side goes away; the relay reconnects on the next send
        FakeUpstream.instances[0].closed = True
        second = tone(1.0) + silence(1.0)
        for i in range(0, len(second), 4800):
            ws.send_bytes(second[i : i + 4800])
        ws.send_text(json.dumps({"type": "stop"}))
        events = collect_until_closed(ws)
    assert any(e == {"type": "status", "state": "reconnecting"} for e in events)
    assert len(FakeUpstream.instances) >= 2


def test_live_rejects_bad_token(client: TestClient, meeting_id: str, live) -> None:
    with pytest.raises(WebSocketDisconnect) as exc:
        with client.websocket_connect(
            f"/meetings/{meeting_id}/live", headers={"Authorization": "Bearer nope"}
        ) as ws:
            ws.receive_json()
    assert exc.value.code == 4401


def test_live_rejects_meeting_that_is_not_recording(
    client: TestClient, meeting_id: str, live
) -> None:
    with client.app.state.session_factory() as db:
        from app.models import Meeting

        db.get(Meeting, meeting_id).status = MeetingStatus.done
        db.commit()
    with client.websocket_connect(f"/meetings/{meeting_id}/live", headers=ws_headers()) as ws:
        event = ws.receive_json()
        assert event["code"] == "meeting_not_recording"
        with pytest.raises(WebSocketDisconnect) as exc:
            ws.receive_json()
    assert exc.value.code == 4409


def test_live_unavailable_without_openai(client: TestClient, meeting_id: str) -> None:
    with client.websocket_connect(f"/meetings/{meeting_id}/live", headers=ws_headers()) as ws:
        assert ws.receive_json()["code"] == "ai_unavailable"
