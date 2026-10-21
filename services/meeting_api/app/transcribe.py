"""OpenAI wrappers. ``Transcriber`` is the seam the worker and the tests use."""

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Protocol

SUMMARY_PROMPT_VERSION = "v1"

SUMMARY_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "summary": {"type": "string", "description": "3-5 sentences, same language as the meeting"},
        "decisions": {"type": "array", "items": {"type": "string"}},
        "action_items": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "what": {"type": "string"},
                    "who": {"type": "string", "description": "speaker name or empty string"},
                    "due": {"type": "string", "description": "as spoken, or empty string"},
                },
                "required": ["what", "who", "due"],
                "additionalProperties": False,
            },
        },
        "topics": {"type": "array", "items": {"type": "string"}},
        "open_questions": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["summary", "decisions", "action_items", "topics", "open_questions"],
    "additionalProperties": False,
}

SUMMARY_SYSTEM_PROMPT = (
    "You summarize meeting transcripts. The transcript has one utterance per line as "
    "'[mm:ss] Speaker: text'. Write the summary in the language the participants spoke "
    "(Korean transcripts get a Korean summary). Keep speaker names exactly as given. "
    "Only report decisions and action items that were actually stated; leave lists empty "
    "rather than inventing items."
)


@dataclass
class DiarizedSegment:
    speaker: str
    start: float
    end: float
    text: str


@dataclass
class TranscriptResult:
    segments: list[DiarizedSegment] = field(default_factory=list)
    audio_sec: float = 0.0
    request_id: str | None = None


@dataclass
class SummaryResult:
    data: dict[str, Any]
    model: str
    tokens_in: int | None = None
    tokens_out: int | None = None


class Transcriber(Protocol):
    def transcribe(
        self, path: Path, known_names: list[str], known_references: list[str]
    ) -> TranscriptResult: ...

    def summarize(self, transcript: str, title: str | None) -> SummaryResult: ...


class OpenAITranscriber:
    def __init__(self, api_key: str, transcribe_model: str, summary_model: str) -> None:
        from openai import OpenAI

        self.client = OpenAI(api_key=api_key)
        self.transcribe_model = transcribe_model
        self.summary_model = summary_model

    def transcribe(
        self, path: Path, known_names: list[str], known_references: list[str]
    ) -> TranscriptResult:
        extra: dict[str, Any] = {}
        if known_names:
            extra["known_speaker_names"] = known_names
            extra["known_speaker_references"] = known_references
        with path.open("rb") as audio_file:
            raw = self.client.audio.transcriptions.with_raw_response.create(
                model=self.transcribe_model,
                file=audio_file,
                response_format="diarized_json",
                chunking_strategy="auto",
                **extra,
            )
        result = raw.parse()
        segments = [
            DiarizedSegment(
                speaker=(getattr(seg, "speaker", None) or "?").strip(),
                start=float(seg.start),
                end=float(seg.end),
                text=(seg.text or "").strip(),
            )
            for seg in (getattr(result, "segments", None) or [])
            if (seg.text or "").strip()
        ]
        duration = getattr(result, "duration", None)
        audio_sec = float(duration) if duration else (segments[-1].end if segments else 0.0)
        return TranscriptResult(
            segments=segments, audio_sec=audio_sec, request_id=raw.headers.get("x-request-id")
        )

    def summarize(self, transcript: str, title: str | None) -> SummaryResult:
        user = f"Meeting title: {title or '(untitled)'}\n\nTranscript:\n{transcript}"
        response = self.client.responses.create(
            model=self.summary_model,
            input=[
                {"role": "system", "content": SUMMARY_SYSTEM_PROMPT},
                {"role": "user", "content": user},
            ],
            text={
                "format": {
                    "type": "json_schema",
                    "name": "meeting_summary",
                    "schema": SUMMARY_SCHEMA,
                    "strict": True,
                }
            },
        )
        data = json.loads(response.output_text)
        usage = response.usage
        return SummaryResult(
            data=data,
            model=self.summary_model,
            tokens_in=usage.input_tokens if usage else None,
            tokens_out=usage.output_tokens if usage else None,
        )
