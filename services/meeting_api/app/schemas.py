from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field

from app.models import MeetingStatus, SegmentStatus


class MeetingCreate(BaseModel):
    title: str | None = None


class FinishRequest(BaseModel):
    segment_count: int = Field(ge=1)
    duration_sec: float | None = Field(default=None, ge=0, allow_inf_nan=False)


class SpeakerOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    raw_label: str | None
    display_name: str
    reference_clip_path: str | None


class SegmentOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    meeting_id: str
    index: int
    file_path: str
    start_offset_sec: float
    duration_sec: float | None
    status: SegmentStatus
    retry_count: int
    created_at: datetime
    updated_at: datetime


class MeetingOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    title: str | None
    created_at: datetime
    duration_sec: float | None
    status: MeetingStatus
    error: str | None
    failed_step: str | None
    expected_segments: int | None


class MeetingDetail(MeetingOut):
    segments_total: int
    segments_received: int
    segments_done: int
    segments_failed: int
    cost_usd: float
    speakers: list[SpeakerOut]
