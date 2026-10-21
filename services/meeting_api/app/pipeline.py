"""Segment transcription and meeting finalization. Called by the worker, one step at a time."""

import json
import logging
from pathlib import Path

from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from app import audio
from app.config import Settings
from app.models import (
    Meeting,
    MeetingStatus,
    Segment,
    SegmentStatus,
    Speaker,
    Summary,
    UsageLog,
    Utterance,
)
from app.transcribe import SUMMARY_PROMPT_VERSION, Transcriber

log = logging.getLogger(__name__)

# USD, from the OpenAI pricing page (2026-10). Unknown models fall back to the diarize price.
TRANSCRIBE_USD_PER_MIN = {
    "gpt-4o-transcribe-diarize": 0.006,
    "gpt-4o-transcribe": 0.006,
    "gpt-4o-mini-transcribe": 0.003,
    "gpt-transcribe": 0.0045,
}
TEXT_USD_PER_MTOKEN = {  # (input, output)
    "gpt-5-mini": (0.25, 2.0),
    "gpt-5-nano": (0.05, 0.40),
}
NO_SPEECH_SUMMARY = {
    "summary": "녹음에서 발화를 찾지 못했습니다.",
    "decisions": [],
    "action_items": [],
    "topics": [],
    "open_questions": [],
}


def transcribe_cost(model: str, audio_sec: float) -> float:
    return TRANSCRIBE_USD_PER_MIN.get(model, 0.006) * audio_sec / 60.0


def summary_cost(model: str, tokens_in: int | None, tokens_out: int | None) -> float:
    price_in, price_out = TEXT_USD_PER_MTOKEN.get(model, (0.25, 2.0))
    return ((tokens_in or 0) * price_in + (tokens_out or 0) * price_out) / 1_000_000


def _work_dir(settings: Settings, meeting_id: str) -> Path:
    return Path(settings.data_dir) / "meetings" / meeting_id / "work"


class _SpeakerResolver:
    """Maps diarization labels to ``Speaker`` rows for one meeting.

    Registered speakers (reference clip, ``raw_label`` None) are matched by display name, which
    is what the model returns when ``known_speaker_names`` is used. Any other label (A, B, ...)
    gets its own row, created on first sight.
    """

    def __init__(self, db: Session, meeting_id: str) -> None:
        self.db = db
        self.meeting_id = meeting_id
        self.by_name: dict[str, Speaker] = {}
        self.by_label: dict[str, Speaker] = {}
        for speaker in db.scalars(select(Speaker).where(Speaker.meeting_id == meeting_id)):
            if speaker.raw_label is None:
                self.by_name[speaker.display_name] = speaker
            else:
                self.by_label[speaker.raw_label] = speaker

    def resolve(self, label: str) -> Speaker:
        if label in self.by_name:
            return self.by_name[label]
        if label not in self.by_label:
            speaker = Speaker(meeting_id=self.meeting_id, raw_label=label, display_name=label)
            self.db.add(speaker)
            self.db.flush()
            self.by_label[label] = speaker
        return self.by_label[label]


def speaker_references(
    db: Session, settings: Settings, meeting_id: str
) -> tuple[list[str], list[str]]:
    names: list[str] = []
    refs: list[str] = []
    registered = db.scalars(
        select(Speaker)
        .where(Speaker.meeting_id == meeting_id, Speaker.reference_clip_path.is_not(None))
        .order_by(Speaker.display_name)
    )
    for speaker in registered:
        wav = _work_dir(settings, meeting_id) / f"ref-{speaker.id}.wav"
        names.append(speaker.display_name)
        refs.append(audio.reference_data_url(Path(speaker.reference_clip_path), wav))
    return names, refs


def process_segment(
    db: Session, settings: Settings, transcriber: Transcriber, segment: Segment
) -> None:
    """received -> normalizing -> transcribing -> done, or back to received / failed."""
    meeting_id = segment.meeting_id
    segment.status = SegmentStatus.normalizing
    segment.error = None
    db.commit()
    try:
        normalized = _work_dir(settings, meeting_id) / f"{segment.id}.mp3"
        duration = audio.normalize(Path(segment.file_path), normalized)
        chunks = audio.split_for_upload(normalized, duration)
        names, refs = speaker_references(db, settings, meeting_id)

        segment.status = SegmentStatus.transcribing
        db.commit()

        resolver = _SpeakerResolver(db, meeting_id)
        utterances: list[Utterance] = []
        audio_sec = 0.0
        request_id: str | None = None
        for chunk_path, chunk_offset in chunks:
            result = transcriber.transcribe(chunk_path, names, refs)
            request_id = result.request_id or request_id
            audio_sec += result.audio_sec
            base = segment.start_offset_sec + chunk_offset
            for item in result.segments:
                speaker = resolver.resolve(item.speaker)
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


def _format_time(sec: float) -> str:
    total = int(sec)
    return f"{total // 60:02d}:{total % 60:02d}"


def transcript_text(db: Session, meeting_id: str) -> str:
    rows = db.execute(
        select(Utterance, Speaker.display_name)
        .outerjoin(Speaker, Speaker.id == Utterance.speaker_id)
        .where(Utterance.meeting_id == meeting_id)
        .order_by(Utterance.start_sec, Utterance.id)
    ).all()
    return "\n".join(f"[{_format_time(u.start_sec)}] {name or '?'}: {u.text}" for u, name in rows)


def finalize_meeting(
    db: Session, settings: Settings, transcriber: Transcriber, meeting: Meeting
) -> None:
    """processing -> merging -> summarizing -> done (or failed with the step recorded)."""
    step = MeetingStatus.merging
    try:
        meeting.status = MeetingStatus.merging
        db.commit()
        text = transcript_text(db, meeting.id)
        if meeting.duration_sec is None:
            last_end = db.scalar(
                select(Utterance.end_sec)
                .where(Utterance.meeting_id == meeting.id)
                .order_by(Utterance.end_sec.desc())
                .limit(1)
            )
            meeting.duration_sec = last_end

        step = MeetingStatus.summarizing
        meeting.status = MeetingStatus.summarizing
        db.commit()
        if text.strip():
            result = transcriber.summarize(text, meeting.title)
            db.add(
                UsageLog(
                    meeting_id=meeting.id,
                    model=result.model,
                    tokens_in=result.tokens_in,
                    tokens_out=result.tokens_out,
                    cost_usd=summary_cost(result.model, result.tokens_in, result.tokens_out),
                )
            )
            data, model = result.data, result.model
        else:
            data, model = NO_SPEECH_SUMMARY, "none"
        db.merge(
            Summary(
                meeting_id=meeting.id,
                json=json.dumps(data, ensure_ascii=False),
                model=model,
                prompt_version=SUMMARY_PROMPT_VERSION,
            )
        )
        meeting.status = MeetingStatus.done
        meeting.error = None
        meeting.failed_step = None
        db.commit()
        log.info("meeting %s done", meeting.id)
    except Exception as exc:  # noqa: BLE001
        db.rollback()
        meeting.status = MeetingStatus.failed
        meeting.failed_step = step
        meeting.error = f"{type(exc).__name__}: {exc}"[:2000]
        db.commit()
        log.warning("meeting %s failed at %s: %s", meeting.id, step, exc)
