"""Segment transcription, meeting finalization and note context. Called one step at a time."""

import json
import logging
import re
from collections import defaultdict
from pathlib import Path

from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from app import audio
from app.config import Settings
from app.models import (
    LiveCaption,
    Meeting,
    MeetingStatus,
    Segment,
    SegmentStatus,
    Speaker,
    Summary,
    UsageLog,
    Utterance,
)
from app.transcribe import (
    DEFAULT_TEMPLATE,
    SUMMARY_PROMPT_VERSION,
    TEMPLATES,
    Transcriber,
)

log = logging.getLogger(__name__)

# USD, from the OpenAI pricing page (2026-10). Unknown models fall back to the diarize price.
TRANSCRIBE_USD_PER_MIN = {
    "gpt-4o-transcribe-diarize": 0.006,
    "gpt-4o-transcribe": 0.006,
    "gpt-4o-mini-transcribe": 0.003,
    "gpt-transcribe": 0.0045,
    "gpt-live-transcribe": 0.017,
}
TEXT_USD_PER_MTOKEN = {  # (input, output)
    "gpt-5-mini": (0.25, 2.0),
    "gpt-5-nano": (0.05, 0.40),
}
WEB_SEARCH_USD_PER_CALL = 0.01
MAX_KNOWN_SPEAKERS = 4  # OpenAI accepts at most four reference clips per request

NO_SPEECH_SUMMARY = {
    "title": "",
    "one_line": "녹음에서 발화를 찾지 못했습니다.",
    "category": "기타",
    "topics": [],
    "sections": [],
    "summary": "녹음에서 발화를 찾지 못했습니다.",
    "key_points": [],
    "decisions": [],
    "action_items": [],
    "open_questions": [],
    "key_terms": [],
    "suggestions": [],
}


def transcribe_cost(model: str, audio_sec: float) -> float:
    return TRANSCRIBE_USD_PER_MIN.get(model, 0.006) * audio_sec / 60.0


def summary_cost(model: str, tokens_in: int | None, tokens_out: int | None) -> float:
    price_in, price_out = TEXT_USD_PER_MTOKEN.get(model, (0.25, 2.0))
    return ((tokens_in or 0) * price_in + (tokens_out or 0) * price_out) / 1_000_000


def work_dir(settings: Settings, meeting_id: str) -> Path:
    return Path(settings.data_dir) / "meetings" / meeting_id / "work"


def default_speaker_name(n: int) -> str:
    return f"참석자 {n}"


class SpeakerResolver:
    """Maps diarization labels to ``Speaker`` rows for one meeting.

    Speakers with a reference clip (registered by the user, or extracted automatically from an
    earlier chunk) are "known": their display name is sent as ``known_speaker_names`` and the
    model answers with that name, so they are matched by name. Labels such as A/B are only
    unique within one request; an unknown label maps to an unreferenced speaker with the same
    label (best effort) or becomes a new "참석자 N".
    """

    def __init__(self, db: Session, meeting_id: str) -> None:
        self.db = db
        self.meeting_id = meeting_id
        self.refresh()

    def refresh(self) -> None:
        self.by_name: dict[str, Speaker] = {}
        self.by_label: dict[str, Speaker] = {}
        speakers = self.db.scalars(
            select(Speaker).where(Speaker.meeting_id == self.meeting_id)
        ).all()
        self.count = len(speakers)
        for speaker in speakers:
            if speaker.reference_clip_path:
                self.by_name[speaker.display_name] = speaker
            elif speaker.raw_label is not None:
                self.by_label[speaker.raw_label] = speaker

    def resolve(self, label: str) -> Speaker:
        if label in self.by_name:
            return self.by_name[label]
        if label not in self.by_label:
            self.count += 1
            speaker = Speaker(
                meeting_id=self.meeting_id,
                raw_label=label,
                display_name=default_speaker_name(self.count),
            )
            self.db.add(speaker)
            self.db.flush()
            self.by_label[label] = speaker
        return self.by_label[label]


def speaker_references(
    db: Session, settings: Settings, meeting_id: str
) -> tuple[list[str], list[str]]:
    names: list[str] = []
    refs: list[str] = []
    known = db.scalars(
        select(Speaker)
        .where(Speaker.meeting_id == meeting_id, Speaker.reference_clip_path.is_not(None))
        .order_by(Speaker.display_name)
    ).all()
    for speaker in known[:MAX_KNOWN_SPEAKERS]:
        wav = work_dir(settings, meeting_id) / f"ref-{speaker.id}.wav"
        names.append(speaker.display_name)
        refs.append(audio.reference_data_url(Path(speaker.reference_clip_path), wav))
    return names, refs


def extract_auto_references(
    db: Session,
    settings: Settings,
    meeting_id: str,
    chunk_path: Path,
    spans: list[tuple[Speaker, float, float]],
    slots: int,
) -> int:
    """Give speakers without a reference clip one, cut from their longest span in this chunk.

    ``spans`` are (speaker, start, end) in chunk-relative seconds. Speakers who talked the most
    get the free slots first. Returns how many references were created.
    """
    if slots <= 0:
        return 0
    talk: dict[str, float] = defaultdict(float)
    longest: dict[str, tuple[float, float]] = {}
    by_id: dict[str, Speaker] = {}
    for speaker, start, end in spans:
        if speaker.reference_clip_path:
            continue
        by_id[speaker.id] = speaker
        talk[speaker.id] += max(0.0, end - start)
        best = longest.get(speaker.id)
        if best is None or (end - start) > (best[1] - best[0]):
            longest[speaker.id] = (start, end)
    created = 0
    for speaker_id in sorted(talk, key=talk.__getitem__, reverse=True):
        if created >= slots:
            break
        start, end = longest[speaker_id]
        dst = work_dir(settings, meeting_id) / f"ref-auto-{speaker_id}.wav"
        if audio.cut_reference(chunk_path, start, end, dst):
            by_id[speaker_id].reference_clip_path = str(dst)
            created += 1
    if created:
        db.flush()
        log.info("meeting %s: %d automatic speaker reference(s)", meeting_id, created)
    return created


def process_segment(
    db: Session, settings: Settings, transcriber: Transcriber, segment: Segment
) -> None:
    """received -> normalizing -> transcribing -> done, or back to received / failed."""
    meeting_id = segment.meeting_id
    segment.status = SegmentStatus.normalizing
    segment.error = None
    db.commit()
    try:
        normalized = work_dir(settings, meeting_id) / f"{segment.id}.mp3"
        duration = audio.normalize(Path(segment.file_path), normalized)
        chunks = audio.split_for_upload(
            normalized, duration, max_sec=settings.transcribe_chunk_sec or None
        )
        names, refs = speaker_references(db, settings, meeting_id)

        segment.status = SegmentStatus.transcribing
        db.commit()

        resolver = SpeakerResolver(db, meeting_id)
        utterances: list[Utterance] = []
        audio_sec = 0.0
        request_id: str | None = None
        for chunk_path, chunk_offset in chunks:
            result = transcriber.transcribe(chunk_path, names, refs)
            request_id = result.request_id or request_id
            audio_sec += result.audio_sec
            base = segment.start_offset_sec + chunk_offset
            spans: list[tuple[Speaker, float, float]] = []
            for item in result.segments:
                speaker = resolver.resolve(item.speaker)
                spans.append((speaker, item.start, item.end))
                utterances.append(
                    Utterance(
                        meeting_id=meeting_id,
                        speaker_id=speaker.id,
                        start_sec=base + item.start,
                        end_sec=base + item.end,
                        text=item.text,
                        segment_id=segment.id,
                    )
                )
            if settings.auto_speaker_refs and extract_auto_references(
                db, settings, meeting_id, chunk_path, spans, MAX_KNOWN_SPEAKERS - len(names)
            ):
                names, refs = speaker_references(db, settings, meeting_id)
                resolver.refresh()

        db.execute(delete(Utterance).where(Utterance.segment_id == segment.id))
        db.add_all(utterances)
        billed_sec = audio_sec or duration
        db.add(
            UsageLog(
                meeting_id=meeting_id,
                model=settings.transcribe_model,
                audio_sec=billed_sec,
                cost_usd=transcribe_cost(settings.transcribe_model, billed_sec),
            )
        )
        if segment.duration_sec is None:
            segment.duration_sec = duration
        segment.openai_request_id = request_id
        segment.status = SegmentStatus.done
        db.commit()
        log.info("segment %s done: %d utterances", segment.id, len(utterances))
    except Exception as exc:  # noqa: BLE001 - any failure is recorded on the segment
        db.rollback()
        segment.retry_count += 1
        segment.error = f"{type(exc).__name__}: {exc}"[:2000]
        exhausted = segment.retry_count >= settings.segment_max_retries
        segment.status = SegmentStatus.failed if exhausted else SegmentStatus.received
        db.commit()
        log.warning("segment %s attempt %d failed: %s", segment.id, segment.retry_count, exc)


def format_time(sec: float) -> str:
    total = int(sec)
    return f"{total // 60:02d}:{total % 60:02d}"


def _utterance_rows(db: Session, meeting_id: str) -> list[tuple[Utterance, str | None]]:
    return [
        (u, name)
        for u, name in db.execute(
            select(Utterance, Speaker.display_name)
            .outerjoin(Speaker, Speaker.id == Utterance.speaker_id)
            .where(Utterance.meeting_id == meeting_id)
            .order_by(Utterance.start_sec, Utterance.id)
        ).all()
    ]


def _trailing_live_captions(
    db: Session, meeting_id: str, after_sec: float | None
) -> list[LiveCaption]:
    stmt = select(LiveCaption).where(LiveCaption.meeting_id == meeting_id)
    if after_sec is not None:
        stmt = stmt.where(LiveCaption.at_sec >= after_sec)
    return list(db.scalars(stmt.order_by(LiveCaption.at_sec, LiveCaption.id)))


def transcript_text(db: Session, meeting_id: str, *, include_live: bool = False) -> str:
    """'[mm:ss] Speaker: text' lines. With ``include_live``, live captions recorded after the last
    diarized utterance are appended (all of them when nothing is diarized yet)."""
    rows = _utterance_rows(db, meeting_id)
    lines = [f"[{format_time(u.start_sec)}] {name or '?'}: {u.text}" for u, name in rows]
    if include_live:
        after = max((u.end_sec for u, _ in rows), default=None)
        lines += [
            f"[{format_time(c.at_sec)}] (실시간): {c.text}"
            for c in _trailing_live_captions(db, meeting_id, after)
        ]
    return "\n".join(lines)


_SPACE = re.compile(r"\s+")


def _squash(text: str) -> str:
    return _SPACE.sub("", text.lower())


def keyword_counts(texts: list[str], words: list[str]) -> list[dict[str, int | str]]:
    """How often each tag/term appears in the transcript ('반복되는 핵심 단어').

    Matching ignores case and spacing ('베타테스트' counts '베타 테스트'); for a tag like
    '검색(FTS5)' the part before the parenthesis is used when the whole tag never occurs.
    """
    corpus = _squash("\n".join(texts))
    seen: set[str] = set()
    counts: list[dict[str, int | str]] = []
    for word in words:
        label = word.strip()
        key = _squash(label)
        if not key or key in seen:
            continue
        seen.add(key)
        n = corpus.count(key)
        if not n and "(" in label:
            base = _squash(label.split("(", 1)[0])
            n = corpus.count(base) if base else 0
        if n:
            counts.append({"word": label, "count": n})
    counts.sort(key=lambda c: -int(c["count"]))
    return counts


def finalize_meeting(
    db: Session, settings: Settings, transcriber: Transcriber, meeting: Meeting
) -> None:
    """processing -> merging -> summarizing -> done (or failed with the step recorded)."""
    step = MeetingStatus.merging
    template = meeting.template if meeting.template in TEMPLATES else DEFAULT_TEMPLATE
    try:
        meeting.status = MeetingStatus.merging
        db.commit()
        rows = _utterance_rows(db, meeting.id)
        if rows:
            text = transcript_text(db, meeting.id)
            plain = [u.text for u, _ in rows]
        else:  # nothing diarized: fall back to live captions, if the recording had them
            captions = _trailing_live_captions(db, meeting.id, None)
            text = "\n".join(f"[{format_time(c.at_sec)}] (실시간): {c.text}" for c in captions)
            plain = [c.text for c in captions]
        if meeting.duration_sec is None and rows:
            meeting.duration_sec = max(u.end_sec for u, _ in rows)

        step = MeetingStatus.summarizing
        meeting.status = MeetingStatus.summarizing
        db.commit()
        if text.strip():
            result = transcriber.summarize(text, meeting.title, template)
            db.add(
                UsageLog(
                    meeting_id=meeting.id,
                    model=result.model,
                    tokens_in=result.tokens_in,
                    tokens_out=result.tokens_out,
                    cost_usd=summary_cost(result.model, result.tokens_in, result.tokens_out),
                )
            )
            data, model = dict(result.data), result.model
        else:
            data, model = dict(NO_SPEECH_SUMMARY), "none"
        terms = [t.get("term", "") for t in data.get("key_terms") or [] if isinstance(t, dict)]
        data["template"] = template
        data["keyword_counts"] = keyword_counts(plain, list(data.get("topics") or []) + terms)
        generated_title = str(data.get("title") or "").strip()
        if not meeting.title and generated_title:
            meeting.title = generated_title[:255]
        db.merge(
            Summary(
                meeting_id=meeting.id,
                json=json.dumps(data, ensure_ascii=False),
                model=model,
                prompt_version=SUMMARY_PROMPT_VERSION,
                template=template,
            )
        )
        meeting.status = MeetingStatus.done
        meeting.error = None
        meeting.failed_step = None
        db.commit()
        log.info("meeting %s done (%s)", meeting.id, template)
    except Exception as exc:  # noqa: BLE001
        db.rollback()
        meeting.status = MeetingStatus.failed
        meeting.failed_step = step
        meeting.error = f"{type(exc).__name__}: {exc}"[:2000]
        db.commit()
        log.warning("meeting %s failed at %s: %s", meeting.id, step, exc)


# ---- note context for "AI에게 질문하기" ----------------------------------------------------

CONTEXT_MAX_CHARS = 120_000
_CITE = re.compile(r"\[(\d{1,3}):(\d{2})(?::(\d{2}))?\]")


def note_context(db: Session, meeting: Meeting) -> str:
    parts = [
        f"제목: {meeting.title or '(제목 없음)'}",
        f"템플릿: {TEMPLATES.get(meeting.template, TEMPLATES[DEFAULT_TEMPLATE])['label']}",
        f"상태: {meeting.status}",
    ]
    if meeting.duration_sec:
        parts.append(f"길이: {format_time(meeting.duration_sec)}")
    summary = db.get(Summary, meeting.id)
    if summary is not None:
        try:
            data = json.loads(summary.json)
        except ValueError:
            data = {}
        if data.get("one_line"):
            parts.append(f"한 줄 요약: {data['one_line']}")
        points = data.get("key_points") or []
        if points:
            parts.append("주요 내용:\n" + "\n".join(f"- {p}" for p in points))
    text = transcript_text(db, meeting.id, include_live=True)
    if len(text) > CONTEXT_MAX_CHARS:  # keep the start and the most recent part
        head = text[: CONTEXT_MAX_CHARS // 6]
        tail = text[-(CONTEXT_MAX_CHARS - len(head)) :]
        text = f"{head}\n…(중략)…\n{tail}"
    parts.append("받아쓰기:\n" + (text or "(아직 없음)"))
    return "\n\n".join(parts)


def parse_citations(content: str) -> list[float]:
    seen: list[float] = []
    for m in _CITE.finditer(content):
        a, b, c = m.groups()
        sec = int(a) * 3600 + int(b) * 60 + int(c) if c is not None else int(a) * 60 + int(b)
        if sec not in seen:
            seen.append(float(sec))
    return seen


def citation_sources(db: Session, meeting_id: str, content: str, limit: int = 8) -> list[dict]:
    """Resolve [mm:ss] citations in an answer to the utterance (or live caption) they point at.

    The transcript shows whole seconds, so an utterance whose start truncates to the cited
    second is an exact match; otherwise the closest earlier line within a minute is used.
    """
    lines: list[tuple[float, str, str, int]] = [
        (u.start_sec, name or "?", u.text, 0) for u, name in _utterance_rows(db, meeting_id)
    ]
    lines += [
        (c.at_sec, "실시간 자막", c.text, 1) for c in _trailing_live_captions(db, meeting_id, None)
    ]
    sources: list[dict] = []
    for sec in parse_citations(content)[:limit]:
        exact = [x for x in lines if int(x[0]) == int(sec)]
        if exact:
            best = min(exact, key=lambda x: (x[3], x[0]))  # diarized lines before captions
        else:
            earlier = [x for x in lines if x[0] <= sec and sec - x[0] <= 60]
            if not earlier:
                continue
            best = max(earlier, key=lambda x: (x[0], -x[3]))
        sources.append(
            {"kind": "transcript", "at_sec": best[0], "speaker": best[1], "text": best[2][:200]}
        )
    return sources
