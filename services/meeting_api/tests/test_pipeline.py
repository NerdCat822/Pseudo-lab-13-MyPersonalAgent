"""Worker + pipeline tests with a fake transcriber. ffmpeg must be on PATH."""

from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app import audio
from app.config import get_settings
from app.models import MeetingStatus, SegmentStatus
from app.transcribe import DiarizedSegment, TranscriptResult
from app.worker import reset_stale, run_once
from tests.fakes import FakeTranscriber, drain, make_wav, upload_wav


@pytest.fixture
def wav(tmp_path: Path) -> Path:
    return make_wav(tmp_path / "in.wav")


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
    assert {u["speaker_name"] for u in transcript["utterances"]} == {"참석자 1", "참석자 2"}
    assert len(detail["speakers"]) == 2

    summary = client.get(f"/meetings/{meeting_id}/summary").json()
    assert summary["summary"] == "짧은 인사"
    assert summary["action_items"][0]["who"] == "B"
    assert "[10:00] 참석자 1: 안녕하세요" in t.summaries[0]


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
    assert sorted(s["display_name"] for s in speakers) == ["민수", "참석자 2"]


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
        def summarize(self, transcript, title, template="meeting"):
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


# ---- v2 summary fields, previews, audio, bookmarks, resummarize ---------------------------


def test_generated_title_fills_untitled_meeting(client: TestClient, wav: Path) -> None:
    mid = client.post("/meetings").json()["id"]  # no title
    t = FakeTranscriber()
    upload_wav(client, mid, wav, 0)
    client.post(f"/meetings/{mid}/finish", json={"segment_count": 1})
    drain(client, t)
    detail = client.get(f"/meetings/{mid}").json()
    assert detail["title"] == "인사 나눔"
    assert detail["one_line"] == "두 사람이 인사를 나눴다."
    assert detail["category"] == "개인"
    assert detail["keywords"] == ["인사", "반갑습니다"]
    assert detail["segments"][0]["index"] == 0
    summary = client.get(f"/meetings/{mid}/summary").json()
    assert summary["key_points"] == ["안녕하세요", "반갑습니다"]
    assert summary["prompt_version"] == "v3"


def test_explicit_title_is_kept(client: TestClient, meeting_id: str, wav: Path) -> None:
    upload_wav(client, meeting_id, wav, 0)
    client.post(f"/meetings/{meeting_id}/finish", json={"segment_count": 1})
    drain(client, FakeTranscriber())
    assert client.get(f"/meetings/{meeting_id}").json()["title"] == "Weekly sync"


def test_list_preview_and_category_filter(client: TestClient, meeting_id: str, wav: Path) -> None:
    other = client.post("/meetings", json={"title": "No summary yet"}).json()["id"]
    upload_wav(client, meeting_id, wav, 0)
    client.post(f"/meetings/{meeting_id}/finish", json={"segment_count": 1})
    drain(client, FakeTranscriber())
    items = {m["id"]: m for m in client.get("/meetings").json()}
    assert items[meeting_id]["one_line"] == "두 사람이 인사를 나눴다."
    assert items[other]["one_line"] is None and items[other]["keywords"] == []
    filtered = client.get("/meetings", params={"category": "개인"}).json()
    assert [m["id"] for m in filtered] == [meeting_id]


def test_v1_summary_rows_still_parse(client: TestClient, meeting_id: str) -> None:
    import json

    from app.models import Summary

    with client.app.state.session_factory() as db:
        db.add(
            Summary(
                meeting_id=meeting_id,
                json=json.dumps(
                    {
                        "summary": "old",
                        "decisions": [],
                        "action_items": [],
                        "topics": ["a"],
                        "open_questions": [],
                    }
                ),
                model="fake",
                prompt_version="v1",
            )
        )
        db.commit()
    body = client.get(f"/meetings/{meeting_id}/summary").json()
    assert body["summary"] == "old"
    assert body["title"] == "" and body["key_points"] == [] and body["category"] is None
    assert client.get("/meetings").json()[0]["one_line"] is None


def test_segment_audio_streams_with_range(client: TestClient, meeting_id: str, wav: Path) -> None:
    upload_wav(client, meeting_id, wav, 0)
    seg = client.get(f"/meetings/{meeting_id}").json()["segments"][0]
    url = f"/meetings/{meeting_id}/segments/{seg['id']}/audio"

    # Before the pipeline ran: original upload (wav) is served.
    r = client.get(url)
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("audio/wav")
    assert r.headers.get("accept-ranges") == "bytes"

    # After normalization the mono MP3 is preferred, and Range requests work.
    run_once(client.app.state.session_factory, get_settings(), FakeTranscriber())
    r = client.get(url)
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("audio/mpeg")
    partial = client.get(url, headers={"Range": "bytes=0-99"})
    assert partial.status_code == 206
    assert len(partial.content) == 100

    assert client.get(f"/meetings/{meeting_id}/segments/{meeting_id}/audio").status_code == 404


def test_bookmarks_create_list_delete(client: TestClient, meeting_id: str) -> None:
    r = client.post(f"/meetings/{meeting_id}/bookmarks", json={"at_sec": 12.5, "note": "중요"})
    assert r.status_code == 201
    bid = r.json()["id"]
    r2 = client.post(f"/meetings/{meeting_id}/bookmarks", json={"at_sec": 3})
    assert r2.status_code == 201
    marks = client.get(f"/meetings/{meeting_id}").json()["bookmarks"]
    assert [m["at_sec"] for m in marks] == [3.0, 12.5]
    assert client.delete(f"/meetings/{meeting_id}/bookmarks/{bid}").status_code == 204
    assert len(client.get(f"/meetings/{meeting_id}").json()["bookmarks"]) == 1
    assert client.delete(f"/meetings/{meeting_id}/bookmarks/{bid}").status_code == 404
    bad = client.post(f"/meetings/{meeting_id}/bookmarks", json={"at_sec": -1})
    assert bad.status_code == 422


def test_resummarize_reruns_summary_only(client: TestClient, meeting_id: str, wav: Path) -> None:
    t = FakeTranscriber()
    upload_wav(client, meeting_id, wav, 0)
    assert client.post(f"/meetings/{meeting_id}/resummarize").status_code == 409  # still recording
    client.post(f"/meetings/{meeting_id}/finish", json={"segment_count": 1})
    drain(client, t)
    assert len(t.calls) == 1 and len(t.summaries) == 1

    r = client.post(f"/meetings/{meeting_id}/resummarize")
    assert r.status_code == 200
    assert r.json()["status"] == "processing"
    assert r.json()["has_summary"] is False
    drain(client, t)
    assert len(t.calls) == 1, "segments must not be transcribed again"
    assert len(t.summaries) == 2
    assert client.get(f"/meetings/{meeting_id}").json()["status"] == "done"


# ---- templates, auto speaker references, long-file chunks, edits, audio, folders -------------


def test_template_drives_summary_and_can_be_switched(client: TestClient, wav: Path) -> None:
    mid = client.post("/meetings", json={"title": "강의", "template": "lecture"}).json()["id"]
    t = FakeTranscriber()
    upload_wav(client, mid, wav, 0)
    client.post(f"/meetings/{mid}/finish", json={"segment_count": 1})
    drain(client, t)
    assert t.templates == ["lecture"]
    summary = client.get(f"/meetings/{mid}/summary").json()
    assert summary["template"] == "lecture"
    assert summary["sections"][0]["heading"] == "인사"
    assert summary["key_terms"][0]["term"] == "인사"
    # "반복되는 핵심 단어": counted in the transcript, not taken from the model
    counts = {c["word"]: c["count"] for c in summary["keyword_counts"]}
    assert counts == {"반갑습니다": 1}

    r = client.post(f"/meetings/{mid}/resummarize", json={"template": "keypoints"})
    assert r.status_code == 200 and r.json()["template"] == "keypoints"
    drain(client, t)
    assert t.templates == ["lecture", "keypoints"]
    assert len(t.calls) == 1, "switching templates must not re-transcribe"
    assert client.get(f"/meetings/{mid}/summary").json()["template"] == "keypoints"

    bad = client.post(f"/meetings/{mid}/resummarize", json={"template": "nope"})
    assert bad.status_code == 422 and bad.json()["detail"]["code"] == "unknown_template"
    assert client.post("/meetings", json={"template": "nope"}).status_code == 422


def test_templates_endpoint_lists_labels(client: TestClient) -> None:
    r = client.get("/templates")
    assert r.status_code == 200
    assert {t["key"]: t["label"] for t in r.json()} == {
        "meeting": "회의록",
        "keypoints": "요점 정리",
        "lecture": "강의 노트",
        "thoughts": "생각 노트",
    }


def _two_voices(path: Path, known: list[str]) -> list[DiarizedSegment]:
    """First request: labels A/B. Later requests: the known names when references were sent."""
    a, b = (known + ["A", "B"])[:2] if known else ("A", "B")
    return [
        DiarizedSegment(speaker=a, start=0.0, end=2.6, text="첫 번째 사람의 긴 발화입니다"),
        DiarizedSegment(speaker=b, start=2.7, end=5.4, text="두 번째 사람도 길게 말합니다"),
    ]


def test_auto_references_keep_speakers_across_segments(client: TestClient, tmp_path: Path) -> None:
    long_wav = make_wav(tmp_path / "long.wav", seconds=6.0)
    mid = client.post("/meetings").json()["id"]
    t = FakeTranscriber(segments=_two_voices)
    upload_wav(client, mid, long_wav, 0)
    upload_wav(client, mid, long_wav, 1)
    client.post(f"/meetings/{mid}/finish", json={"segment_count": 2})
    drain(client, t)

    assert t.calls[0][1] == []  # nothing known yet
    names, refs = t.calls[1][1], t.calls[1][2]
    assert names == ["참석자 1", "참석자 2"]
    assert all(r.startswith("data:audio/wav;base64,") for r in refs)
    speakers = client.get(f"/meetings/{mid}").json()["speakers"]
    assert sorted(s["display_name"] for s in speakers) == ["참석자 1", "참석자 2"]
    assert all(s["reference_clip_path"] for s in speakers)
    utts = client.get(f"/meetings/{mid}/transcript").json()["utterances"]
    assert [u["speaker_name"] for u in utts] == ["참석자 1", "참석자 2"] * 2


def test_auto_references_skip_short_utterances(client: TestClient, wav: Path) -> None:
    t = FakeTranscriber()  # utterances are 0.4 s: too short for a 2 s reference
    mid = client.post("/meetings").json()["id"]
    upload_wav(client, mid, wav, 0)
    upload_wav(client, mid, wav, 1)
    client.post(f"/meetings/{mid}/finish", json={"segment_count": 2})
    drain(client, t)
    assert t.calls[1][1] == []
    speakers = client.get(f"/meetings/{mid}").json()["speakers"]
    assert not any(s["reference_clip_path"] for s in speakers)


def test_long_upload_is_chunked_by_duration(
    client: TestClient, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("TRANSCRIBE_CHUNK_SEC", "2")
    monkeypatch.setenv("AUTO_SPEAKER_REFS", "false")
    get_settings.cache_clear()
    long_wav = make_wav(tmp_path / "long.wav", seconds=5.0)
    mid = client.post("/meetings").json()["id"]
    t = FakeTranscriber()
    upload_wav(client, mid, long_wav, 0, offset=0.0)
    client.post(f"/meetings/{mid}/finish", json={"segment_count": 1})
    drain(client, t)
    assert len(t.calls) >= 3
    starts = [
        u["start_sec"] for u in client.get(f"/meetings/{mid}/transcript").json()["utterances"]
    ]
    assert starts[0] == 0.0 and max(starts) >= 3.5  # later chunks keep their offsets
    assert client.get(f"/meetings/{mid}").json()["status"] == "done"


def test_keyword_counts_helper() -> None:
    from app.pipeline import keyword_counts

    counts = keyword_counts(
        ["FTS5 검색은 FTS5로", "검색 속도", "베타 테스트를 마치고"],
        ["FTS5", "검색", "없는말", "fts5", "베타테스트", "속도(성능)"],
    )
    assert counts == [
        {"word": "FTS5", "count": 2},
        {"word": "검색", "count": 2},
        {"word": "베타테스트", "count": 1},
        {"word": "속도(성능)", "count": 1},
    ]


def test_patch_meeting_title_and_folder(client: TestClient, meeting_id: str) -> None:
    r = client.patch(f"/meetings/{meeting_id}", json={"title": "  새 제목  ", "folder": "프로젝트"})
    assert r.status_code == 200
    assert r.json()["title"] == "새 제목" and r.json()["folder"] == "프로젝트"
    other = client.post("/meetings", json={"title": "다른 노트", "folder": "프로젝트"}).json()["id"]
    client.post("/meetings", json={"title": "폴더 없음"})
    assert client.get("/folders").json() == [{"name": "프로젝트", "count": 2}]
    in_folder = client.get("/meetings", params={"folder": "프로젝트"}).json()
    assert {m["id"] for m in in_folder} == {meeting_id, other}
    # only sent fields change; folder=null clears it
    r = client.patch(f"/meetings/{meeting_id}", json={"folder": None})
    assert r.json()["folder"] is None and r.json()["title"] == "새 제목"


def test_edit_utterance_and_summary(client: TestClient, meeting_id: str, wav: Path) -> None:
    upload_wav(client, meeting_id, wav, 0)
    client.post(f"/meetings/{meeting_id}/finish", json={"segment_count": 1})
    drain(client, FakeTranscriber())
    utt = client.get(f"/meetings/{meeting_id}/transcript").json()["utterances"][0]
    r = client.patch(
        f"/meetings/{meeting_id}/utterances/{utt['id']}", json={"text": "안녕하십니까"}
    )
    assert r.status_code == 200 and r.json()["text"] == "안녕하십니까"
    assert (
        client.patch(f"/meetings/{meeting_id}/utterances/999999", json={"text": "x"}).status_code
        == 404
    )

    r = client.put(
        f"/meetings/{meeting_id}/summary",
        json={"one_line": "고친 한 줄", "decisions": ["다음 주 금요일 마감"], "title": "고친 제목"},
    )
    assert r.status_code == 200
    body = r.json()
    assert body["one_line"] == "고친 한 줄" and body["decisions"] == ["다음 주 금요일 마감"]
    assert body["edited"] is True and body["summary"] == "짧은 인사"  # untouched field kept
    assert client.get(f"/meetings/{meeting_id}").json()["title"] == "고친 제목"


def test_meeting_audio_concatenates_segments(
    client: TestClient, meeting_id: str, wav: Path
) -> None:
    assert client.get(f"/meetings/{meeting_id}/audio").status_code == 409  # nothing yet
    upload_wav(client, meeting_id, wav, 0)
    upload_wav(client, meeting_id, wav, 1)
    client.post(f"/meetings/{meeting_id}/finish", json={"segment_count": 2})
    drain(client, FakeTranscriber())
    r = client.get(f"/meetings/{meeting_id}/audio")
    assert r.status_code == 200 and r.headers["content-type"] == "audio/mpeg"
    one = client.get(
        f"/meetings/{meeting_id}/segments/"
        f"{client.get(f'/meetings/{meeting_id}').json()['segments'][0]['id']}/audio"
    )
    assert len(r.content) > len(one.content) * 1.5  # two segments joined
    again = client.get(f"/meetings/{meeting_id}/audio")
    assert again.content == r.content  # cached


def test_extra_upload_extensions_are_accepted(
    client: TestClient, meeting_id: str, wav: Path
) -> None:
    r = client.post(
        f"/meetings/{meeting_id}/segments",
        data={"index": 0, "start_offset_sec": 0},
        files={"file": ("memo.flac", wav.read_bytes(), "audio/flac")},
    )
    assert r.status_code == 202


def test_delete_meeting_removes_rows_and_files(
    client: TestClient, meeting_id: str, wav: Path, data_dir: Path
) -> None:
    upload_wav(client, meeting_id, wav, 0)
    client.post(f"/meetings/{meeting_id}/bookmarks", json={"at_sec": 1})
    client.post(f"/meetings/{meeting_id}/finish", json={"segment_count": 1})
    drain(client, FakeTranscriber())
    assert (data_dir / "meetings" / meeting_id).exists()
    assert client.delete(f"/meetings/{meeting_id}").status_code == 204
    assert client.get(f"/meetings/{meeting_id}").status_code == 404
    assert not (data_dir / "meetings" / meeting_id).exists()
    assert client.delete(f"/meetings/{meeting_id}").status_code == 404


def test_delete_refused_while_processing(client: TestClient, meeting_id: str, wav: Path) -> None:
    from app.models import Meeting

    with client.app.state.session_factory() as db:
        db.get(Meeting, meeting_id).status = MeetingStatus.summarizing
        db.commit()
    r = client.delete(f"/meetings/{meeting_id}")
    assert r.status_code == 409 and r.json()["detail"]["code"] == "meeting_busy"
