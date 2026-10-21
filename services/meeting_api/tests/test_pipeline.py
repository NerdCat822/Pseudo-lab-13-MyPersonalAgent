"""Worker + pipeline tests with a fake transcriber. ffmpeg must be on PATH."""

import math
import struct
import wave
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app import audio
from app.config import get_settings
from app.models import MeetingStatus, SegmentStatus
from app.transcribe import DiarizedSegment, SummaryResult, TranscriptResult
from app.worker import reset_stale, run_once


def make_wav(path: Path, seconds: float = 1.0, freq: float = 440.0) -> Path:
    rate = 16000
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        frames = b"".join(
            struct.pack("<h", int(12000 * math.sin(2 * math.pi * freq * i / rate)))
            for i in range(int(rate * seconds))
        )
        w.writeframes(frames)
    return path


class FakeTranscriber:
    def __init__(self, fail_times: int = 0) -> None:
        self.calls: list[tuple[Path, list[str], list[str]]] = []
        self.summaries: list[str] = []
        self.fail_times = fail_times

    def transcribe(self, path: Path, known_names, known_references) -> TranscriptResult:
        self.calls.append((path, list(known_names), list(known_references)))
        if self.fail_times > 0:
            self.fail_times -= 1
            raise RuntimeError("boom")
        speaker = known_names[0] if known_names else "A"
        return TranscriptResult(
            segments=[
                DiarizedSegment(speaker=speaker, start=0.0, end=0.4, text="안녕하세요"),
                DiarizedSegment(speaker="B", start=0.5, end=0.9, text="네 반갑습니다"),
            ],
            audio_sec=1.0,
            request_id="req-1",
        )

    def summarize(self, transcript: str, title: str | None) -> SummaryResult:
        self.summaries.append(transcript)
        return SummaryResult(
            data={
                "summary": "짧은 인사",
                "decisions": [],
                "action_items": [{"what": "후속 미팅", "who": "B", "due": ""}],
                "topics": ["인사"],
                "open_questions": [],
            },
            model="fake",
            tokens_in=10,
            tokens_out=5,
        )


@pytest.fixture
def wav(tmp_path: Path) -> Path:
    return make_wav(tmp_path / "in.wav")


def upload_wav(client: TestClient, mid: str, wav: Path, index: int) -> None:
    r = client.post(
        f"/meetings/{mid}/segments",
        data={"index": index, "start_offset_sec": index * 600.0},
        files={"file": (f"{index}.wav", wav.read_bytes(), "audio/wav")},
    )
    assert r.status_code == 202, r.text


def drain(client: TestClient, transcriber: FakeTranscriber, max_steps: int = 20) -> int:
    factory = client.app.state.session_factory
    steps = 0
    while run_once(factory, get_settings(), transcriber):
        steps += 1
        assert steps < max_steps, "worker did not converge"
    return steps


# ---- audio helpers ------------------------------------------------------------------------


def test_normalize_and_probe(tmp_path: Path, wav: Path) -> None:
    out = tmp_path / "out" / "n.mp3"
    duration = audio.normalize(wav, out)
    assert out.exists()
    assert 0.9 < duration < 1.3
    assert audio.split_for_upload(out, duration) == [(out, 0.0)]


def test_split_for_upload_chunks_by_size(tmp_path: Path) -> None:
    wav = make_wav(tmp_path / "long.wav", seconds=4.0)
    mp3 = tmp_path / "long.mp3"
    duration = audio.normalize(wav, mp3)
    chunks = audio.split_for_upload(mp3, duration, max_bytes=mp3.stat().st_size // 2)
    assert len(chunks) >= 2
    assert chunks[0][1] == 0.0
    offsets = [offset for _, offset in chunks]
    assert offsets == sorted(set(offsets))


def test_reference_data_url(tmp_path: Path, wav: Path) -> None:
    url = audio.reference_data_url(wav, tmp_path / "ref.wav")
    assert url.startswith("data:audio/wav;base64,")


# ---- pipeline through the worker ---------------------------------------------------------


def test_segment_to_summary_end_to_end(client: TestClient, meeting_id: str, wav: Path) -> None:
    t = FakeTranscriber()
    upload_wav(client, meeting_id, wav, 0)
    upload_wav(client, meeting_id, wav, 1)

    # Segments are transcribed while the meeting is still recording.
    assert run_once(client.app.state.session_factory, get_settings(), t)
    detail = client.get(f"/meetings/{meeting_id}").json()
    assert detail["status"] == "recording"
    assert detail["segments_done"] == 1

    assert (
        client.post(f"/meetings/{meeting_id}/finish", json={"segment_count": 2}).status_code == 200
    )
    drain(client, t)

    detail = client.get(f"/meetings/{meeting_id}").json()
    assert detail["status"] == MeetingStatus.done
    assert detail["segments_done"] == 2
    assert detail["has_summary"] is True
    assert detail["cost_usd"] > 0

    transcript = client.get(f"/meetings/{meeting_id}/transcript").json()
    starts = [u["start_sec"] for u in transcript["utterances"]]
    assert starts == sorted(starts)
    assert starts[2] == pytest.approx(600.0)  # second segment offset applied
    assert {u["speaker_name"] for u in transcript["utterances"]} == {"A", "B"}
    assert len(detail["speakers"]) == 2

    summary = client.get(f"/meetings/{meeting_id}/summary").json()
    assert summary["summary"] == "짧은 인사"
    assert summary["action_items"][0]["who"] == "B"
    assert "[10:00] A: 안녕하세요" in t.summaries[0]


def test_registered_speaker_reference_is_sent_and_matched(
    client: TestClient, meeting_id: str, wav: Path
) -> None:
    r = client.post(
        f"/meetings/{meeting_id}/speakers",
        data={"display_name": "민수"},
        files={"file": ("ref.wav", wav.read_bytes(), "audio/wav")},
    )
    assert r.status_code == 201
    upload_wav(client, meeting_id, wav, 0)
    t = FakeTranscriber()
    run_once(client.app.state.session_factory, get_settings(), t)

    _, names, refs = t.calls[0]
    assert names == ["민수"]
    assert refs[0].startswith("data:audio/wav;base64,")
    transcript = client.get(f"/meetings/{meeting_id}/transcript").json()
    assert transcript["utterances"][0]["speaker_name"] == "민수"
    speakers = client.get(f"/meetings/{meeting_id}").json()["speakers"]
    assert sorted(s["display_name"] for s in speakers) == ["B", "민수"]


def test_no_speech_skips_summary_model(client: TestClient, meeting_id: str, wav: Path) -> None:
    class Silent(FakeTranscriber):
        def transcribe(self, path, known_names, known_references):
            return TranscriptResult(segments=[], audio_sec=1.0)

    t = Silent()
    upload_wav(client, meeting_id, wav, 0)
    client.post(f"/meetings/{meeting_id}/finish", json={"segment_count": 1})
    drain(client, t)
    assert t.summaries == []
    summary = client.get(f"/meetings/{meeting_id}/summary").json()
    assert summary["model"] == "none"
    assert client.get(f"/meetings/{meeting_id}").json()["status"] == "done"


def test_retries_then_fails_then_retry_endpoint(
    client: TestClient, meeting_id: str, wav: Path
) -> None:
    t = FakeTranscriber(fail_times=3)
    upload_wav(client, meeting_id, wav, 0)
    client.post(f"/meetings/{meeting_id}/finish", json={"segment_count": 1})
    drain(client, t)

    detail = client.get(f"/meetings/{meeting_id}").json()
    assert detail["status"] == "failed"
    assert detail["failed_step"] == "transcribing"
    assert detail["segments_failed"] == 1
    assert client.get(f"/meetings/{meeting_id}/summary").status_code == 404

    r = client.post(f"/meetings/{meeting_id}/retry")
    assert r.status_code == 200
    assert r.json()["status"] == "processing"
    assert r.json()["segments_received"] == 1
    drain(client, t)  # fake no longer fails
    assert client.get(f"/meetings/{meeting_id}").json()["status"] == "done"


def test_retry_rejected_unless_failed(client: TestClient, meeting_id: str) -> None:
    r = client.post(f"/meetings/{meeting_id}/retry")
    assert r.status_code == 409
    assert r.json()["detail"]["code"] == "meeting_not_failed"


def test_summary_failure_marks_meeting_failed(
    client: TestClient, meeting_id: str, wav: Path
) -> None:
    class BadSummary(FakeTranscriber):
        def summarize(self, transcript, title):
            raise RuntimeError("quota")

    t = BadSummary()
    upload_wav(client, meeting_id, wav, 0)
    client.post(f"/meetings/{meeting_id}/finish", json={"segment_count": 1})
    drain(client, t)
    detail = client.get(f"/meetings/{meeting_id}").json()
    assert detail["status"] == "failed"
    assert detail["failed_step"] == "summarizing"
    assert "quota" in detail["error"]


def test_rename_speaker(client: TestClient, meeting_id: str, wav: Path) -> None:
    upload_wav(client, meeting_id, wav, 0)
    run_once(client.app.state.session_factory, get_settings(), FakeTranscriber())
    speaker = client.get(f"/meetings/{meeting_id}").json()["speakers"][0]
    r = client.patch(
        f"/meetings/{meeting_id}/speakers/{speaker['id']}", json={"display_name": "지은"}
    )
    assert r.status_code == 200
    assert r.json()["display_name"] == "지은"
    names = {
        u["speaker_name"]
        for u in client.get(f"/meetings/{meeting_id}/transcript").json()["utterances"]
    }
    assert "지은" in names
    bad = client.patch(f"/meetings/{meeting_id}/speakers/{meeting_id}", json={"display_name": "x"})
    assert bad.status_code == 404


def test_reset_stale_requeues_in_flight_work(
    client: TestClient, meeting_id: str, wav: Path
) -> None:
    from app.models import Meeting, Segment

    upload_wav(client, meeting_id, wav, 0)
    factory = client.app.state.session_factory
    with factory() as db:
        seg = db.query(Segment).one()
        seg.status = SegmentStatus.transcribing
        db.get(Meeting, meeting_id).status = MeetingStatus.summarizing
        db.commit()
    reset_stale(factory)
    detail = client.get(f"/meetings/{meeting_id}").json()
    assert detail["status"] == "processing"
    assert detail["segments_received"] == 1
