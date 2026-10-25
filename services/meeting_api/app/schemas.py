from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field

from app.models import MeetingStatus, SegmentStatus


class MeetingCreate(BaseModel):
    title: str | None = Field(default=None, max_length=255)
    template: str | None = None
    folder: str | None = Field(default=None, max_length=64)


class MeetingPatch(BaseModel):
    """Only the fields that are sent are changed; send folder=null to clear it."""

    title: str | None = Field(default=None, max_length=255)
    folder: str | None = Field(default=None, max_length=64)


class ResummarizeRequest(BaseModel):
    template: str | None = None


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
    template: str = "meeting"
    folder: str | None = None
    # Preview fields filled from the summary when one exists (list cards).
    one_line: str | None = None
    category: str | None = None
    keywords: list[str] = Field(default_factory=list)


class SegmentBrief(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    index: int
    start_offset_sec: float
    duration_sec: float | None
    status: SegmentStatus


class BookmarkCreate(BaseModel):
    at_sec: float = Field(ge=0, allow_inf_nan=False)
    note: str | None = Field(default=None, max_length=500)


class BookmarkOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    at_sec: float
    note: str | None


class LiveSummaryOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    start_sec: float
    end_sec: float
    text: str


class LiveSummaryPatch(BaseModel):
    text: str = Field(min_length=1, max_length=2000)


class LiveCaptionOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    at_sec: float
    end_sec: float | None
    text: str


class MeetingDetail(MeetingOut):
    segments_total: int
    segments_received: int
    segments_processing: int
    segments_done: int
    segments_failed: int
    cost_usd: float
    has_summary: bool
    speakers: list[SpeakerOut]
    segments: list[SegmentBrief] = Field(default_factory=list)
    bookmarks: list[BookmarkOut] = Field(default_factory=list)
    live_summaries: list[LiveSummaryOut] = Field(default_factory=list)
    live_caption_count: int = 0
    chat_count: int = 0


class SpeakerPatch(BaseModel):
    display_name: str = Field(min_length=1, max_length=255)


class UtterancePatch(BaseModel):
    text: str = Field(min_length=1, max_length=5000)


class UtteranceOut(BaseModel):
    id: int
    speaker_id: str | None
    speaker_name: str
    start_sec: float
    end_sec: float
    text: str
    segment_id: str | None


class TranscriptOut(BaseModel):
    meeting_id: str
    status: MeetingStatus
    utterances: list[UtteranceOut]


class ActionItem(BaseModel):
    what: str
    who: str = ""
    due: str = ""


class Section(BaseModel):
    heading: str
    bullets: list[str] = Field(default_factory=list)


class KeyTerm(BaseModel):
    term: str
    explanation: str = ""


class KeywordCount(BaseModel):
    word: str
    count: int


class SummaryEdit(BaseModel):
    """Hand edits to a generated note. Fields that are sent replace the stored ones."""

    title: str | None = Field(default=None, max_length=255)
    one_line: str | None = None
    summary: str | None = None
    sections: list[Section] | None = None
    key_points: list[str] | None = None
    decisions: list[str] | None = None
    action_items: list[ActionItem] | None = None
    open_questions: list[str] | None = None
    key_terms: list[KeyTerm] | None = None
    suggestions: list[str] | None = None
    topics: list[str] | None = None


class SummaryOut(BaseModel):
    """v3 note. v1/v2 rows (fewer fields) still parse via defaults."""

    model_config = ConfigDict(extra="ignore")

    meeting_id: str
    model: str
    prompt_version: str
    created_at: datetime
    template: str = "meeting"
    title: str = ""
    one_line: str = ""
    category: str | None = None
    topics: list[str] = Field(default_factory=list)
    sections: list[Section] = Field(default_factory=list)
    summary: str = ""
    key_points: list[str] = Field(default_factory=list)
    decisions: list[str] = Field(default_factory=list)
    action_items: list[ActionItem] = Field(default_factory=list)
    open_questions: list[str] = Field(default_factory=list)
    key_terms: list[KeyTerm] = Field(default_factory=list)
    suggestions: list[str] = Field(default_factory=list)
    keyword_counts: list[KeywordCount] = Field(default_factory=list)
    edited: bool = False


class ChatRequest(BaseModel):
    question: str = Field(min_length=1, max_length=2000)
    web_search: bool = False


class ChatSource(BaseModel):
    kind: str  # transcript | web
    at_sec: float | None = None
    speaker: str | None = None
    text: str | None = None
    title: str | None = None
    url: str | None = None


class ChatMessageOut(BaseModel):
    id: int
    role: str
    content: str
    web_search: bool
    sources: list[ChatSource] = Field(default_factory=list)
    created_at: datetime


class FolderOut(BaseModel):
    name: str
    count: int


class TemplateOut(BaseModel):
    key: str
    label: str
