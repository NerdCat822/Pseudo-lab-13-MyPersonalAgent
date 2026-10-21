"""Single in-process worker: one segment or one finalization per ``run_once``."""

import asyncio
import logging

from sqlalchemy import func, select, update
from sqlalchemy.orm import Session, sessionmaker

from app.config import Settings
from app.models import Meeting, MeetingStatus, Segment, SegmentStatus
from app.pipeline import finalize_meeting, process_segment
from app.transcribe import Transcriber

log = logging.getLogger(__name__)

ACTIVE_MEETINGS = (MeetingStatus.recording, MeetingStatus.processing)


def reset_stale(session_factory: sessionmaker[Session]) -> None:
    """After a restart, put in-flight work back on the queue."""
    with session_factory() as db:
        db.execute(
            update(Segment)
            .where(Segment.status.in_([SegmentStatus.normalizing, SegmentStatus.transcribing]))
            .values(status=SegmentStatus.received)
        )
        db.execute(
            update(Meeting)
            .where(Meeting.status.in_([MeetingStatus.merging, MeetingStatus.summarizing]))
            .values(status=MeetingStatus.processing)
        )
        db.commit()


def _segment_counts(db: Session, meeting_id: str) -> dict[SegmentStatus, int]:
    rows = db.execute(
        select(Segment.status, func.count())
        .where(Segment.meeting_id == meeting_id)
        .group_by(Segment.status)
    ).all()
    return {SegmentStatus(status): count for status, count in rows}


def run_once(
    session_factory: sessionmaker[Session], settings: Settings, transcriber: Transcriber
) -> bool:
    """Do one unit of work. Returns False when there was nothing to do."""
    with session_factory() as db:
        segment = db.scalar(
            select(Segment)
            .join(Meeting, Meeting.id == Segment.meeting_id)
            .where(Segment.status == SegmentStatus.received, Meeting.status.in_(ACTIVE_MEETINGS))
            .order_by(Segment.created_at, Segment.index)
            .limit(1)
        )
        if segment is not None:
            process_segment(db, settings, transcriber, segment)
            return True

        for meeting in db.scalars(
            select(Meeting).where(Meeting.status == MeetingStatus.processing)
        ).all():
            counts = _segment_counts(db, meeting.id)
            pending = (
                counts.get(SegmentStatus.received, 0)
                + counts.get(SegmentStatus.normalizing, 0)
                + counts.get(SegmentStatus.transcribing, 0)
            )
            if pending:
                continue
            if counts.get(SegmentStatus.failed, 0):
                meeting.status = MeetingStatus.failed
                meeting.failed_step = "transcribing"
                meeting.error = f"{counts[SegmentStatus.failed]} segment(s) failed; POST /retry"
                db.commit()
                return True
            if (
                meeting.expected_segments is not None
                and counts.get(SegmentStatus.done, 0) >= meeting.expected_segments
            ):
                finalize_meeting(db, settings, transcriber, meeting)
                return True
    return False


async def worker_loop(
    session_factory: sessionmaker[Session],
    settings: Settings,
    transcriber: Transcriber,
    stop: asyncio.Event,
) -> None:
    log.info(
        "worker started (transcribe=%s, summary=%s)",
        settings.transcribe_model,
        settings.summary_model,
    )
    while not stop.is_set():
        try:
            did_work = await asyncio.to_thread(run_once, session_factory, settings, transcriber)
        except Exception:  # noqa: BLE001 - keep the loop alive
            log.exception("worker iteration crashed")
            did_work = False
        if did_work:
            continue
        try:
            await asyncio.wait_for(stop.wait(), timeout=settings.worker_poll_sec)
        except TimeoutError:
            pass
    log.info("worker stopped")
