import os
import uuid
from pathlib import Path
from typing import Annotated

import aiofiles
from fastapi import APIRouter, Depends, File, Form, Query, Response, UploadFile, status
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.auth import require_token
from app.config import Settings, get_settings
from app.db import get_db
from app.errors import api_error
from app.models import (
    Meeting,
    MeetingStatus,
    Segment,
    SegmentStatus,
    Speaker,
    UsageLog,
    new_id,
)
from app.schemas import (
    FinishRequest,
    MeetingCreate,
    MeetingDetail,
    MeetingOut,
    SegmentOut,
    SpeakerOut,
)

router = APIRouter(prefix="/meetings", dependencies=[Depends(require_token)])

ALLOWED_EXTENSIONS = {"m4a", "mp4", "mp3", "wav", "webm", "mpeg", "mpga"}
ACCEPTING_SEGMENTS = {MeetingStatus.recording, MeetingStatus.processing}
MAX_SPEAKERS = 4
CHUNK_SIZE = 1024 * 1024

DbSession = Annotated[Session, Depends(get_db)]
AppSettings = Annotated[Settings, Depends(get_settings)]


def _get_meeting(db: Session, meeting_id: uuid.UUID) -> Meeting:
    meeting = db.get(Meeting, str(meeting_id))
    if meeting is None:
        raise api_error(status.HTTP_404_NOT_FOUND, "not_found", "Meeting not found")
    return meeting


def _extension(upload: UploadFile) -> str:
    ext = Path(upload.filename or "").suffix.lstrip(".").lower()
    if ext not in ALLOWED_EXTENSIONS:
        raise api_error(
            422,
            "unsupported_extension",
            f"Unsupported file extension; allowed: {sorted(ALLOWED_EXTENSIONS)}",
        )
    return ext


async def _save_upload(upload: UploadFile, dest: Path, max_bytes: int) -> None:
    """Stream an upload to a request-unique temp file, then move it to ``dest``.

    ``dest`` must be unique to this request. No partial file remains on failure.
    """
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_name(dest.name + ".part")
    written = 0
    try:
        async with aiofiles.open(tmp, "wb") as out:
            while chunk := await upload.read(CHUNK_SIZE):
                written += len(chunk)
                if written > max_bytes:
                    raise api_error(
                        413,
                        "file_too_large",
                        f"File exceeds {max_bytes // (1024 * 1024)} MB limit",
                    )
                await out.write(chunk)
        os.replace(tmp, dest)
    finally:
        tmp.unlink(missing_ok=True)


def _detail(db: Session, meeting: Meeting) -> MeetingDetail:
    counts = dict(
        db.execute(
            select(Segment.status, func.count())
            .where(Segment.meeting_id == meeting.id)
            .group_by(Segment.status)
        ).all()
    )
    speakers = db.scalars(select(Speaker).where(Speaker.meeting_id == meeting.id)).all()
    cost = db.scalar(
        select(func.coalesce(func.sum(UsageLog.cost_usd), 0.0)).where(
            UsageLog.meeting_id == meeting.id
        )
    )
    return MeetingDetail(
        **MeetingOut.model_validate(meeting).model_dump(),
        segments_total=sum(counts.values()),
        segments_received=counts.get(SegmentStatus.received, 0),
        segments_done=counts.get(SegmentStatus.done, 0),
        segments_failed=counts.get(SegmentStatus.failed, 0),
        cost_usd=float(cost),
        speakers=[SpeakerOut.model_validate(s) for s in speakers],
    )


def _check_segment_target(meeting: Meeting, index: int) -> None:
    if meeting.status not in ACCEPTING_SEGMENTS:
        raise api_error(409, "meeting_closed", f"Meeting is {meeting.status}; no more segments")
    if meeting.expected_segments is not None and index >= meeting.expected_segments:
        raise api_error(
            409,
            "index_out_of_range",
            f"Index {index} is outside the expected {meeting.expected_segments} segments",
        )


def _existing_segment(db: Session, meeting_id: str, index: int) -> Segment | None:
    return db.scalar(
        select(Segment).where(Segment.meeting_id == meeting_id, Segment.index == index)
    )


@router.post("", status_code=status.HTTP_201_CREATED, response_model=MeetingDetail)
def create_meeting(db: DbSession, payload: MeetingCreate | None = None) -> MeetingDetail:
    meeting = Meeting(title=payload.title if payload else None)
    db.add(meeting)
    db.commit()
    return _detail(db, meeting)


@router.get("", response_model=list[MeetingOut])
def list_meetings(
    db: DbSession,
    q: str | None = None,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
    offset: Annotated[int, Query(ge=0)] = 0,
) -> list[Meeting]:
    stmt = select(Meeting).order_by(Meeting.created_at.desc(), Meeting.id)
    if q:
        stmt = stmt.where(Meeting.title.icontains(q, autoescape=True))
    return list(db.scalars(stmt.limit(limit).offset(offset)))


@router.get("/{meeting_id}", response_model=MeetingDetail)
def get_meeting(meeting_id: uuid.UUID, db: DbSession) -> MeetingDetail:
    return _detail(db, _get_meeting(db, meeting_id))


@router.post(
    "/{meeting_id}/segments",
    status_code=status.HTTP_202_ACCEPTED,
    response_model=SegmentOut,
)
async def upload_segment(
    meeting_id: uuid.UUID,
    response: Response,
    db: DbSession,
    settings: AppSettings,
    index: Annotated[int, Form(ge=0, le=9999)],
    start_offset_sec: Annotated[float, Form(ge=0, allow_inf_nan=False)],
    file: Annotated[UploadFile, File()],
    duration_sec: Annotated[float | None, Form(ge=0, allow_inf_nan=False)] = None,
) -> Segment:
    """Accept a segment while the meeting is recording or processing.

    Returns 202 for a new segment and 200 with the existing record when the index was already
    uploaded (idempotent retry).
    """
    mid = str(meeting_id)
    meeting = _get_meeting(db, meeting_id)
    _check_segment_target(meeting, index)
    ext = _extension(file)
    existing = _existing_segment(db, mid, index)
    if existing:
        response.status_code = status.HTTP_200_OK
        return existing

    segment_id = new_id()
    dest = settings.data_dir / "meetings" / mid / "segments" / f"{segment_id}.{ext}"
    try:
        await _save_upload(file, dest, settings.max_upload_bytes)
        db.refresh(meeting)
        _check_segment_target(meeting, index)
        segment = Segment(
            id=segment_id,
            meeting_id=mid,
            index=index,
            file_path=str(dest),
            start_offset_sec=start_offset_sec,
            duration_sec=duration_sec,
            status=SegmentStatus.received,
        )
        db.add(segment)
        db.commit()
    except IntegrityError:
        db.rollback()
        dest.unlink(missing_ok=True)
        existing = _existing_segment(db, mid, index)
        if existing is None:
            raise
        response.status_code = status.HTTP_200_OK
        return existing
    except BaseException:
        db.rollback()
        dest.unlink(missing_ok=True)
        raise
    return segment


@router.post(
    "/{meeting_id}/speakers",
    status_code=status.HTTP_201_CREATED,
    response_model=SpeakerOut,
)
async def upload_speaker(
    meeting_id: uuid.UUID,
    db: DbSession,
    settings: AppSettings,
    display_name: Annotated[str, Form(min_length=1, max_length=255)],
    file: Annotated[UploadFile, File()],
) -> Speaker:
    mid = str(meeting_id)
    meeting = _get_meeting(db, meeting_id)
    if meeting.status != MeetingStatus.recording:
        raise api_error(409, "meeting_not_recording", "Meeting is not recording")
    ext = _extension(file)
    speaker_id = new_id()
    dest = settings.data_dir / "meetings" / mid / "speakers" / f"{speaker_id}.{ext}"
    limit_error = api_error(409, "speaker_limit", f"At most {MAX_SPEAKERS} speakers")
    try:
        await _save_upload(file, dest, settings.max_upload_bytes)
        db.refresh(meeting)
        if meeting.status != MeetingStatus.recording:
            raise api_error(409, "meeting_not_recording", "Meeting is not recording")
        speaker = Speaker(
            id=speaker_id,
            meeting_id=mid,
            raw_label=None,
            display_name=display_name,
            reference_clip_path=str(dest),
        )
        db.add(speaker)
        db.flush()
        count = db.scalar(select(func.count()).where(Speaker.meeting_id == mid))
        if count > MAX_SPEAKERS:
            raise limit_error
        db.commit()
    except BaseException:
        db.rollback()
        dest.unlink(missing_ok=True)
        raise
    return speaker


@router.post("/{meeting_id}/finish", response_model=MeetingDetail)
def finish_meeting(meeting_id: uuid.UUID, payload: FinishRequest, db: DbSession) -> MeetingDetail:
    """Mark recording as ended and move the meeting to ``processing``.

    ``segment_count`` is the total number of segments the app will deliver (indexes
    0..count-1); late segments are still accepted while processing. The W2 worker picks up
    ``processing`` meetings and advances them to ``merging`` once the done segments equal
    ``expected_segments``.
    """
    meeting = _get_meeting(db, meeting_id)
    if meeting.status != MeetingStatus.recording:
        raise api_error(409, "meeting_not_recording", "Meeting is not recording")
    max_index = db.scalar(select(func.max(Segment.index)).where(Segment.meeting_id == meeting.id))
    if max_index is not None and payload.segment_count <= max_index:
        raise api_error(
            409,
            "segment_count_too_small",
            f"segment_count must be greater than the highest uploaded index ({max_index})",
        )
    meeting.status = MeetingStatus.processing
    meeting.expected_segments = payload.segment_count
    if payload.duration_sec is not None:
        meeting.duration_sec = payload.duration_sec
    db.commit()
    return _detail(db, meeting)
