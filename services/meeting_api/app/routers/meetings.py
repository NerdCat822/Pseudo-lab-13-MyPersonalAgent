import json
import os
import shutil
import uuid
from pathlib import Path
from typing import Annotated

import aiofiles
from fastapi import APIRouter, Depends, File, Form, Query, Request, Response, UploadFile, status
from fastapi.responses import FileResponse
from sqlalchemy import delete, func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app import audio
from app.auth import require_token
from app.config import Settings, get_settings
from app.db import get_db
from app.errors import api_error
from app.models import (
    Bookmark,
    ChatMessage,
    LiveCaption,
    LiveSummary,
    Meeting,
    MeetingStatus,
    Segment,
    SegmentStatus,
    Speaker,
    Summary,
    UsageLog,
    Utterance,
    new_id,
)
from app.pipeline import (
    WEB_SEARCH_USD_PER_CALL,
    citation_sources,
    note_context,
    summary_cost,
    work_dir,
)
from app.schemas import (
    BookmarkCreate,
    BookmarkOut,
    ChatMessageOut,
    ChatRequest,
    ChatSource,
    FinishRequest,
    FolderOut,
    LiveCaptionOut,
    LiveSummaryOut,
    LiveSummaryPatch,
    MeetingCreate,
    MeetingDetail,
    MeetingOut,
    MeetingPatch,
    ResummarizeRequest,
    SegmentBrief,
    SegmentOut,
    SpeakerOut,
    SpeakerPatch,
    SummaryEdit,
    SummaryOut,
    TemplateOut,
    TranscriptOut,
    UtteranceOut,
    UtterancePatch,
)
from app.transcribe import DEFAULT_TEMPLATE, TEMPLATES

router = APIRouter(prefix="/meetings", dependencies=[Depends(require_token)])
meta_router = APIRouter(dependencies=[Depends(require_token)])

ALLOWED_EXTENSIONS = {
    "m4a", "mp4", "mp3", "wav", "webm", "mpeg", "mpga",
    "aac", "flac", "ogg", "oga", "opus", "3gp", "amr", "caf",
}  # fmt: skip
CHAT_HISTORY_TURNS = 10
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


def _check_template(template: str | None) -> str:
    key = template or DEFAULT_TEMPLATE
    if key not in TEMPLATES:
        raise api_error(422, "unknown_template", f"Unknown template; allowed: {sorted(TEMPLATES)}")
    return key


def _clean_folder(folder: str | None) -> str | None:
    folder = (folder or "").strip()
    return folder or None


def _summary_data(summary: Summary) -> dict:
    try:
        data = json.loads(summary.json)
    except ValueError:
        data = {}
    data.setdefault("template", summary.template or DEFAULT_TEMPLATE)
    return data


def _summary_out(meeting: Meeting, summary: Summary) -> SummaryOut:
    return SummaryOut(
        meeting_id=meeting.id,
        model=summary.model,
        prompt_version=summary.prompt_version,
        created_at=summary.created_at,
        **_summary_data(summary),
    )


def _preview_fields(summary: Summary | None) -> dict:
    """one_line / category / keywords for list cards, taken from the stored summary JSON."""
    if summary is None:
        return {}
    try:
        data = json.loads(summary.json)
    except ValueError:
        return {}
    keywords = [str(k) for k in (data.get("topics") or [])][:6]
    return {
        "one_line": data.get("one_line") or None,
        "category": data.get("category") or None,
        "keywords": keywords,
    }


def _meeting_out(meeting: Meeting, summary: Summary | None) -> MeetingOut:
    base = MeetingOut.model_validate(meeting).model_dump()
    base.update(_preview_fields(summary))
    return MeetingOut(**base)


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
    summary = db.get(Summary, meeting.id)
    segments = db.scalars(
        select(Segment).where(Segment.meeting_id == meeting.id).order_by(Segment.index)
    ).all()
    bookmarks = db.scalars(
        select(Bookmark).where(Bookmark.meeting_id == meeting.id).order_by(Bookmark.at_sec)
    ).all()
    live_summaries = db.scalars(
        select(LiveSummary)
        .where(LiveSummary.meeting_id == meeting.id)
        .order_by(LiveSummary.start_sec, LiveSummary.id)
    ).all()
    live_caption_count = db.scalar(select(func.count()).where(LiveCaption.meeting_id == meeting.id))
    chat_count = db.scalar(select(func.count()).where(ChatMessage.meeting_id == meeting.id))
    return MeetingDetail(
        **_meeting_out(meeting, summary).model_dump(),
        segments_total=sum(counts.values()),
        segments_received=counts.get(SegmentStatus.received, 0),
        segments_processing=counts.get(SegmentStatus.normalizing, 0)
        + counts.get(SegmentStatus.transcribing, 0),
        segments_done=counts.get(SegmentStatus.done, 0),
        segments_failed=counts.get(SegmentStatus.failed, 0),
        cost_usd=float(cost),
        has_summary=summary is not None,
        speakers=[SpeakerOut.model_validate(s) for s in speakers],
        segments=[SegmentBrief.model_validate(s) for s in segments],
        bookmarks=[BookmarkOut.model_validate(b) for b in bookmarks],
        live_summaries=[LiveSummaryOut.model_validate(x) for x in live_summaries],
        live_caption_count=int(live_caption_count or 0),
        chat_count=int(chat_count or 0),
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
    payload = payload or MeetingCreate()
    meeting = Meeting(
        title=(payload.title or "").strip() or None,
        template=_check_template(payload.template),
        folder=_clean_folder(payload.folder),
    )
    db.add(meeting)
    db.commit()
    return _detail(db, meeting)


@router.get("", response_model=list[MeetingOut])
def list_meetings(
    db: DbSession,
    q: str | None = None,
    category: str | None = None,
    folder: str | None = None,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
    offset: Annotated[int, Query(ge=0)] = 0,
) -> list[MeetingOut]:
    stmt = select(Meeting).order_by(Meeting.created_at.desc(), Meeting.id)
    if q:
        stmt = stmt.where(Meeting.title.icontains(q, autoescape=True))
    if folder:
        stmt = stmt.where(Meeting.folder == folder)
    meetings = list(db.scalars(stmt.limit(limit).offset(offset)))
    summaries = {
        s.meeting_id: s
        for s in db.scalars(select(Summary).where(Summary.meeting_id.in_([m.id for m in meetings])))
    }
    items = [_meeting_out(m, summaries.get(m.id)) for m in meetings]
    if category:
        items = [i for i in items if i.category == category]
    return items


@router.get("/{meeting_id}", response_model=MeetingDetail)
def get_meeting(meeting_id: uuid.UUID, db: DbSession) -> MeetingDetail:
    return _detail(db, _get_meeting(db, meeting_id))


@router.patch("/{meeting_id}", response_model=MeetingDetail)
def patch_meeting(meeting_id: uuid.UUID, payload: MeetingPatch, db: DbSession) -> MeetingDetail:
    """Rename a note or move it to a folder. Only fields present in the body change."""
    meeting = _get_meeting(db, meeting_id)
    sent = payload.model_fields_set
    if "title" in sent:
        meeting.title = (payload.title or "").strip() or None
    if "folder" in sent:
        meeting.folder = _clean_folder(payload.folder)
    db.commit()
    return _detail(db, meeting)


@router.delete("/{meeting_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_meeting(meeting_id: uuid.UUID, db: DbSession, settings: AppSettings) -> Response:
    """Delete a note with its transcript, summaries, chat and audio files.

    Refused while the worker is touching it (merging/summarizing or a segment in flight).
    """
    meeting = _get_meeting(db, meeting_id)
    busy_segment = db.scalar(
        select(func.count()).where(
            Segment.meeting_id == meeting.id,
            Segment.status.in_([SegmentStatus.normalizing, SegmentStatus.transcribing]),
        )
    )
    if meeting.status in (MeetingStatus.merging, MeetingStatus.summarizing) or busy_segment:
        raise api_error(409, "meeting_busy", "The note is being processed; try again shortly")
    mid = meeting.id
    for model in (ChatMessage, LiveSummary, LiveCaption, Utterance, Bookmark, UsageLog):
        db.execute(delete(model).where(model.meeting_id == mid))
    db.execute(delete(Speaker).where(Speaker.meeting_id == mid))
    db.execute(delete(Segment).where(Segment.meeting_id == mid))
    db.execute(delete(Summary).where(Summary.meeting_id == mid))
    db.delete(meeting)
    db.commit()
    shutil.rmtree(Path(settings.data_dir) / "meetings" / mid, ignore_errors=True)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


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


@router.get("/{meeting_id}/transcript", response_model=TranscriptOut)
def get_transcript(meeting_id: uuid.UUID, db: DbSession) -> TranscriptOut:
    """Utterances so far, in time order. Available while the meeting is still processing."""
    meeting = _get_meeting(db, meeting_id)
    rows = db.execute(
        select(Utterance, Speaker.display_name)
        .outerjoin(Speaker, Speaker.id == Utterance.speaker_id)
        .where(Utterance.meeting_id == meeting.id)
        .order_by(Utterance.start_sec, Utterance.id)
    ).all()
    return TranscriptOut(
        meeting_id=meeting.id,
        status=meeting.status,
        utterances=[
            UtteranceOut(
                id=u.id,
                speaker_id=u.speaker_id,
                speaker_name=name or "?",
                start_sec=u.start_sec,
                end_sec=u.end_sec,
                text=u.text,
                segment_id=u.segment_id,
            )
            for u, name in rows
        ],
    )


@router.get("/{meeting_id}/summary", response_model=SummaryOut)
def get_summary(meeting_id: uuid.UUID, db: DbSession) -> SummaryOut:
    meeting = _get_meeting(db, meeting_id)
    summary = db.get(Summary, meeting.id)
    if summary is None:
        raise api_error(
            404, "summary_not_ready", f"No summary yet; meeting status is {meeting.status}"
        )
    return _summary_out(meeting, summary)


@router.put("/{meeting_id}/summary", response_model=SummaryOut)
def edit_summary(meeting_id: uuid.UUID, payload: SummaryEdit, db: DbSession) -> SummaryOut:
    """Save hand edits to the generated note (템플릿 직접 수정)."""
    meeting = _get_meeting(db, meeting_id)
    summary = db.get(Summary, meeting.id)
    if summary is None:
        raise api_error(
            404, "summary_not_ready", f"No summary yet; meeting status is {meeting.status}"
        )
    data = _summary_data(summary)
    data.update(payload.model_dump(exclude_unset=True, mode="json"))
    data["edited"] = True
    summary.json = json.dumps(data, ensure_ascii=False)
    if "title" in payload.model_fields_set and payload.title:
        meeting.title = payload.title.strip()[:255]
    db.commit()
    return _summary_out(meeting, summary)


@router.patch("/{meeting_id}/speakers/{speaker_id}", response_model=SpeakerOut)
def rename_speaker(
    meeting_id: uuid.UUID, speaker_id: uuid.UUID, payload: SpeakerPatch, db: DbSession
) -> Speaker:
    meeting = _get_meeting(db, meeting_id)
    speaker = db.get(Speaker, str(speaker_id))
    if speaker is None or speaker.meeting_id != meeting.id:
        raise api_error(status.HTTP_404_NOT_FOUND, "not_found", "Speaker not found")
    speaker.display_name = payload.display_name
    db.commit()
    return speaker


@router.post("/{meeting_id}/retry", response_model=MeetingDetail)
def retry_meeting(meeting_id: uuid.UUID, db: DbSession) -> MeetingDetail:
    """Re-queue failed segments and put a failed meeting back into processing."""
    meeting = _get_meeting(db, meeting_id)
    if meeting.status != MeetingStatus.failed:
        raise api_error(409, "meeting_not_failed", f"Meeting is {meeting.status}, not failed")
    for segment in db.scalars(
        select(Segment).where(
            Segment.meeting_id == meeting.id, Segment.status == SegmentStatus.failed
        )
    ):
        segment.status = SegmentStatus.received
        segment.retry_count = 0
        segment.error = None
    meeting.status = (
        MeetingStatus.processing if meeting.expected_segments else MeetingStatus.recording
    )
    meeting.error = None
    meeting.failed_step = None
    db.commit()
    return _detail(db, meeting)


@router.get("/{meeting_id}/segments/{segment_id}/audio")
def segment_audio(meeting_id: uuid.UUID, segment_id: uuid.UUID, db: DbSession) -> FileResponse:
    """Stream one segment's audio for playback (Range requests supported).

    Prefers the normalized mono MP3 the pipeline produced; falls back to the original upload.
    """
    meeting = _get_meeting(db, meeting_id)
    segment = db.get(Segment, str(segment_id))
    if segment is None or segment.meeting_id != meeting.id:
        raise api_error(status.HTTP_404_NOT_FOUND, "not_found", "Segment not found")
    normalized = Path(segment.file_path).parent.parent / "work" / f"{segment.id}.mp3"
    if normalized.exists():
        return FileResponse(
            normalized, media_type="audio/mpeg", filename=f"{segment.index:03d}.mp3"
        )
    original = Path(segment.file_path)
    if not original.exists():
        raise api_error(status.HTTP_404_NOT_FOUND, "audio_missing", "Audio file is gone")
    media = "audio/wav" if original.suffix.lower() == ".wav" else "audio/mp4"
    return FileResponse(original, media_type=media, filename=original.name)


@router.post(
    "/{meeting_id}/bookmarks", status_code=status.HTTP_201_CREATED, response_model=BookmarkOut
)
def add_bookmark(meeting_id: uuid.UUID, payload: BookmarkCreate, db: DbSession) -> Bookmark:
    """'중요 표시' during or after recording: a timestamp plus an optional note."""
    meeting = _get_meeting(db, meeting_id)
    bookmark = Bookmark(meeting_id=meeting.id, at_sec=payload.at_sec, note=payload.note)
    db.add(bookmark)
    db.commit()
    return bookmark


@router.delete("/{meeting_id}/bookmarks/{bookmark_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_bookmark(meeting_id: uuid.UUID, bookmark_id: int, db: DbSession) -> Response:
    meeting = _get_meeting(db, meeting_id)
    bookmark = db.get(Bookmark, bookmark_id)
    if bookmark is None or bookmark.meeting_id != meeting.id:
        raise api_error(status.HTTP_404_NOT_FOUND, "not_found", "Bookmark not found")
    db.delete(bookmark)
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/{meeting_id}/resummarize", response_model=MeetingDetail)
def resummarize_meeting(
    meeting_id: uuid.UUID, db: DbSession, payload: ResummarizeRequest | None = None
) -> MeetingDetail:
    """Re-run merge + summary, optionally with another template (worker picks it up).

    Transcription is not repeated, so switching templates costs one summary call.
    """
    meeting = _get_meeting(db, meeting_id)
    template = _check_template(payload.template if payload else meeting.template)
    if meeting.status not in (MeetingStatus.done, MeetingStatus.failed):
        raise api_error(409, "meeting_busy", f"Meeting is {meeting.status}; wait until it finishes")
    if meeting.expected_segments is None:
        raise api_error(409, "meeting_not_finished", "finish has not been called for this meeting")
    summary = db.get(Summary, meeting.id)
    if summary is not None:
        db.delete(summary)
    meeting.template = template
    meeting.status = MeetingStatus.processing
    meeting.error = None
    meeting.failed_step = None
    db.commit()
    return _detail(db, meeting)


@router.patch("/{meeting_id}/utterances/{utterance_id}", response_model=UtteranceOut)
def edit_utterance(
    meeting_id: uuid.UUID, utterance_id: int, payload: UtterancePatch, db: DbSession
) -> UtteranceOut:
    """Fix a transcription mistake (받아쓰기 수정)."""
    meeting = _get_meeting(db, meeting_id)
    utterance = db.get(Utterance, utterance_id)
    if utterance is None or utterance.meeting_id != meeting.id:
        raise api_error(status.HTTP_404_NOT_FOUND, "not_found", "Utterance not found")
    utterance.text = payload.text.strip()
    db.commit()
    speaker = db.get(Speaker, utterance.speaker_id) if utterance.speaker_id else None
    return UtteranceOut(
        id=utterance.id,
        speaker_id=utterance.speaker_id,
        speaker_name=speaker.display_name if speaker else "?",
        start_sec=utterance.start_sec,
        end_sec=utterance.end_sec,
        text=utterance.text,
        segment_id=utterance.segment_id,
    )


@router.get("/{meeting_id}/audio")
def meeting_audio(meeting_id: uuid.UUID, db: DbSession, settings: AppSettings) -> FileResponse:
    """The whole recording as one MP3 (녹음 파일 저장·공유), built from normalized segments."""
    meeting = _get_meeting(db, meeting_id)
    segments = db.scalars(
        select(Segment).where(Segment.meeting_id == meeting.id).order_by(Segment.index)
    ).all()
    wd = work_dir(settings, meeting.id)
    parts = [wd / f"{s.id}.mp3" for s in segments]
    if not parts or not all(p.exists() for p in parts):
        raise api_error(409, "audio_not_ready", "Segments are not normalized yet")
    signature = ",".join(f"{p.name}:{p.stat().st_size}" for p in parts)
    full, sig_file = wd / "full.mp3", wd / "full.sig"
    if not (full.exists() and sig_file.exists() and sig_file.read_text() == signature):
        if len(parts) == 1:
            full.write_bytes(parts[0].read_bytes())
        else:
            audio.concat_mp3(parts, full)
        sig_file.write_text(signature)
    name = (meeting.title or "recording").replace("/", "_")[:80]
    return FileResponse(full, media_type="audio/mpeg", filename=f"{name}.mp3")


@router.get("/{meeting_id}/live-captions", response_model=list[LiveCaptionOut])
def list_live_captions(meeting_id: uuid.UUID, db: DbSession) -> list[LiveCaption]:
    meeting = _get_meeting(db, meeting_id)
    return list(
        db.scalars(
            select(LiveCaption)
            .where(LiveCaption.meeting_id == meeting.id)
            .order_by(LiveCaption.at_sec, LiveCaption.id)
        )
    )


@router.patch("/{meeting_id}/live-summaries/{summary_id}", response_model=LiveSummaryOut)
def edit_live_summary(
    meeting_id: uuid.UUID, summary_id: int, payload: LiveSummaryPatch, db: DbSession
) -> LiveSummary:
    """Edit a 실시간 요약 entry (one bullet per line)."""
    meeting = _get_meeting(db, meeting_id)
    row = db.get(LiveSummary, summary_id)
    if row is None or row.meeting_id != meeting.id:
        raise api_error(status.HTTP_404_NOT_FOUND, "not_found", "Live summary not found")
    row.text = payload.text.strip()
    db.commit()
    return row


def _chat_out(message: ChatMessage) -> ChatMessageOut:
    try:
        sources = json.loads(message.sources_json) if message.sources_json else []
    except ValueError:
        sources = []
    return ChatMessageOut(
        id=message.id,
        role=message.role,
        content=message.content,
        web_search=bool(message.web_search),
        sources=[ChatSource(**s) for s in sources],
        created_at=message.created_at,
    )


@router.get("/{meeting_id}/chat", response_model=list[ChatMessageOut])
def list_chat(meeting_id: uuid.UUID, db: DbSession) -> list[ChatMessageOut]:
    meeting = _get_meeting(db, meeting_id)
    rows = db.scalars(
        select(ChatMessage).where(ChatMessage.meeting_id == meeting.id).order_by(ChatMessage.id)
    ).all()
    return [_chat_out(m) for m in rows]


@router.post("/{meeting_id}/chat", response_model=ChatMessageOut)
def ask_note(
    meeting_id: uuid.UUID, payload: ChatRequest, request: Request, db: DbSession
) -> ChatMessageOut:
    """AI에게 질문하기: answer from the note's transcript (also while recording), with
    [mm:ss] citations resolved to utterances; optional web search for unfamiliar terms."""
    meeting = _get_meeting(db, meeting_id)
    transcriber = getattr(request.app.state, "transcriber", None)
    if transcriber is None:
        raise api_error(503, "ai_unavailable", "OPENAI_API_KEY is not configured on the server")
    history_rows = db.scalars(
        select(ChatMessage)
        .where(ChatMessage.meeting_id == meeting.id)
        .order_by(ChatMessage.id.desc())
        .limit(CHAT_HISTORY_TURNS * 2)
    ).all()
    history = [(m.role, m.content) for m in reversed(history_rows)]
    context = note_context(db, meeting)
    question = payload.question.strip()
    user_msg = ChatMessage(
        meeting_id=meeting.id, role="user", content=question, web_search=payload.web_search
    )
    db.add(user_msg)
    db.commit()
    try:
        result = transcriber.ask(context, history, question, payload.web_search)
    except Exception as exc:  # noqa: BLE001
        db.delete(user_msg)
        db.commit()
        raise api_error(502, "ai_failed", f"{type(exc).__name__}: {exc}"[:300]) from exc
    sources = citation_sources(db, meeting.id, result.content)
    sources += [
        {"kind": "web", "title": w.get("title"), "url": w.get("url")} for w in result.web_sources
    ]
    answer = ChatMessage(
        meeting_id=meeting.id,
        role="assistant",
        content=result.content,
        sources_json=json.dumps(sources, ensure_ascii=False),
        web_search=payload.web_search,
    )
    db.add(answer)
    cost = summary_cost(result.model, result.tokens_in, result.tokens_out)
    if payload.web_search:
        cost += WEB_SEARCH_USD_PER_CALL
    db.add(
        UsageLog(
            meeting_id=meeting.id,
            model=result.model + ("+web_search" if payload.web_search else ""),
            tokens_in=result.tokens_in,
            tokens_out=result.tokens_out,
            cost_usd=cost,
        )
    )
    db.commit()
    return _chat_out(answer)


@router.delete("/{meeting_id}/chat", status_code=status.HTTP_204_NO_CONTENT)
def clear_chat(meeting_id: uuid.UUID, db: DbSession) -> Response:
    meeting = _get_meeting(db, meeting_id)
    db.execute(delete(ChatMessage).where(ChatMessage.meeting_id == meeting.id))
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@meta_router.get("/folders", response_model=list[FolderOut])
def list_folders(db: DbSession) -> list[FolderOut]:
    rows = db.execute(
        select(Meeting.folder, func.count())
        .where(Meeting.folder.is_not(None))
        .group_by(Meeting.folder)
        .order_by(Meeting.folder)
    ).all()
    return [FolderOut(name=name, count=count) for name, count in rows]


@meta_router.get("/templates", response_model=list[TemplateOut])
def list_templates() -> list[TemplateOut]:
    return [TemplateOut(key=k, label=v["label"]) for k, v in TEMPLATES.items()]
