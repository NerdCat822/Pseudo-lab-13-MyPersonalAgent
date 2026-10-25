import enum
import uuid
from datetime import UTC, datetime

from sqlalchemy import (
    Boolean,
    DateTime,
    Float,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    TypeDecorator,
    UniqueConstraint,
)
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base


def new_id() -> str:
    return str(uuid.uuid4())


def utcnow() -> datetime:
    return datetime.now(UTC)


class UTCDateTime(TypeDecorator):
    """Stores UTC; always returns timezone-aware values (SQLite drops tzinfo)."""

    impl = DateTime(timezone=True)
    cache_ok = True

    def process_bind_param(self, value: datetime | None, dialect) -> datetime | None:
        if value is None:
            return None
        if value.tzinfo is None:
            value = value.replace(tzinfo=UTC)
        return value.astimezone(UTC)

    def process_result_value(self, value: datetime | None, dialect) -> datetime | None:
        if value is None:
            return None
        return value.replace(tzinfo=UTC) if value.tzinfo is None else value.astimezone(UTC)


class MeetingStatus(enum.StrEnum):
    recording = "recording"
    processing = "processing"
    merging = "merging"
    summarizing = "summarizing"
    done = "done"
    failed = "failed"


class SegmentStatus(enum.StrEnum):
    received = "received"
    normalizing = "normalizing"
    transcribing = "transcribing"
    done = "done"
    failed = "failed"


class Meeting(Base):
    __tablename__ = "meetings"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    title: Mapped[str | None] = mapped_column(String(255))
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow, index=True)
    duration_sec: Mapped[float | None] = mapped_column(Float)
    status: Mapped[MeetingStatus] = mapped_column(
        String(16), default=MeetingStatus.recording, index=True
    )
    error: Mapped[str | None] = mapped_column(Text)
    failed_step: Mapped[str | None] = mapped_column(String(32))
    expected_segments: Mapped[int | None] = mapped_column(Integer)
    # Note template that drives the summary: meeting | keypoints | lecture | thoughts.
    template: Mapped[str] = mapped_column(String(16), default="meeting")
    folder: Mapped[str | None] = mapped_column(String(64), index=True)


class Segment(Base):
    __tablename__ = "segments"
    __table_args__ = (
        UniqueConstraint("meeting_id", "index", name="uq_segment_meeting_index"),
        Index("ix_segments_status_meeting", "status", "meeting_id"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    meeting_id: Mapped[str] = mapped_column(ForeignKey("meetings.id"), index=True)
    index: Mapped[int] = mapped_column(Integer)
    file_path: Mapped[str] = mapped_column(String(512))
    start_offset_sec: Mapped[float] = mapped_column(Float)
    duration_sec: Mapped[float | None] = mapped_column(Float)
    status: Mapped[SegmentStatus] = mapped_column(String(16), default=SegmentStatus.received)
    retry_count: Mapped[int] = mapped_column(Integer, default=0)
    openai_request_id: Mapped[str | None] = mapped_column(String(128))
    error: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)
    updated_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow, onupdate=utcnow)


class Speaker(Base):
    __tablename__ = "speakers"
    __table_args__ = (UniqueConstraint("meeting_id", "raw_label", name="uq_speaker_meeting_label"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    meeting_id: Mapped[str] = mapped_column(ForeignKey("meetings.id"), index=True)
    raw_label: Mapped[str | None] = mapped_column(String(16))
    display_name: Mapped[str] = mapped_column(String(255))
    reference_clip_path: Mapped[str | None] = mapped_column(String(512))


class Utterance(Base):
    __tablename__ = "utterances"
    __table_args__ = (Index("ix_utterances_meeting_start", "meeting_id", "start_sec"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    meeting_id: Mapped[str] = mapped_column(ForeignKey("meetings.id"), index=True)
    speaker_id: Mapped[str | None] = mapped_column(ForeignKey("speakers.id"))
    start_sec: Mapped[float] = mapped_column(Float)
    end_sec: Mapped[float] = mapped_column(Float)
    text: Mapped[str] = mapped_column(Text)
    segment_id: Mapped[str | None] = mapped_column(ForeignKey("segments.id"))


class Summary(Base):
    __tablename__ = "summaries"

    meeting_id: Mapped[str] = mapped_column(ForeignKey("meetings.id"), primary_key=True)
    json: Mapped[str] = mapped_column(Text)
    model: Mapped[str] = mapped_column(String(64))
    prompt_version: Mapped[str] = mapped_column(String(32))
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)
    template: Mapped[str | None] = mapped_column(String(16))


class Bookmark(Base):
    __tablename__ = "bookmarks"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    meeting_id: Mapped[str] = mapped_column(ForeignKey("meetings.id"), index=True)
    at_sec: Mapped[float] = mapped_column(Float)
    note: Mapped[str | None] = mapped_column(Text)


class UsageLog(Base):
    __tablename__ = "usage_log"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    meeting_id: Mapped[str] = mapped_column(ForeignKey("meetings.id"), index=True)
    model: Mapped[str] = mapped_column(String(64))
    audio_sec: Mapped[float | None] = mapped_column(Float)
    tokens_in: Mapped[int | None] = mapped_column(Integer)
    tokens_out: Mapped[int | None] = mapped_column(Integer)
    cost_usd: Mapped[float | None] = mapped_column(Float)
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)


class LiveCaption(Base):
    """A finished live-caption line (gpt-live-transcribe, no speaker) captured while recording."""

    __tablename__ = "live_captions"
    __table_args__ = (Index("ix_live_captions_meeting_at", "meeting_id", "at_sec"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    meeting_id: Mapped[str] = mapped_column(ForeignKey("meetings.id"), index=True)
    at_sec: Mapped[float] = mapped_column(Float)
    end_sec: Mapped[float | None] = mapped_column(Float)
    text: Mapped[str] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)


class LiveSummary(Base):
    """'실시간 요약': a short summary of one time window of live captions."""

    __tablename__ = "live_summaries"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    meeting_id: Mapped[str] = mapped_column(ForeignKey("meetings.id"), index=True)
    start_sec: Mapped[float] = mapped_column(Float)
    end_sec: Mapped[float] = mapped_column(Float)
    text: Mapped[str] = mapped_column(Text)  # one bullet per line
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)


class ChatMessage(Base):
    """'AI에게 질문하기' history for one note."""

    __tablename__ = "chat_messages"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    meeting_id: Mapped[str] = mapped_column(ForeignKey("meetings.id"), index=True)
    role: Mapped[str] = mapped_column(String(16))  # user | assistant
    content: Mapped[str] = mapped_column(Text)
    sources_json: Mapped[str | None] = mapped_column(Text)
    web_search: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)
