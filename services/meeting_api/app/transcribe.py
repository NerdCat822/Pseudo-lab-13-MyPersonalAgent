"""OpenAI wrappers. ``Transcriber`` is the seam the worker, the routes and the tests use."""

import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Protocol

SUMMARY_PROMPT_VERSION = "v3"
SUMMARY_CATEGORIES = ["업무", "개인", "상담", "학습", "기타"]

# Note templates (에이닷 노트-style). Key = API value, label = UI name, guide = model instructions.
TEMPLATES: dict[str, dict[str, str]] = {
    "meeting": {
        "label": "회의록",
        "guide": (
            "Template 회의록: a record of a multi-speaker meeting. Skip greetings and small "
            "talk. sections: one per agenda item discussed, heading = the agenda item, bullets "
            "= concise paraphrased points (never verbatim quotes), one line each, prefixed with "
            "a speaker name only when who said it matters. summary: 3-6 sentences. key_points: "
            "the 3-6 most important outcomes. Fill decisions, action_items (who = speaker name "
            "or '', due as spoken or '') and open_questions from what was actually said. "
            "key_terms and suggestions stay empty."
        ),
    },
    "keypoints": {
        "label": "요점 정리",
        "guide": (
            "Template 요점 정리: a topic-by-topic digest regardless of who spoke; skip greetings. "
            "sections: one per topic in the order it came up, heading = topic, bullets = 2-5 "
            "concise paraphrased facts. "
            "key_points: the 3-8 takeaways a reader must remember. summary: 2-4 sentences. "
            "key_terms: up to 6 important, repeated terms with a one-line explanation taken from "
            "context. decisions and action_items only when explicitly stated. suggestions empty."
        ),
    },
    "lecture": {
        "label": "강의 노트",
        "guide": (
            "Template 강의 노트: study notes of a talk or lecture centred on the main speaker. "
            "sections: the lecture outline in order, heading = section title, bullets = "
            "explanations, examples and formulas as taught. key_terms: up to 10 concepts with the "
            "definition given in the lecture. key_points: what to review. open_questions: "
            "audience questions or review questions the lecture raises. action_items: assignments "
            "or homework only. decisions and suggestions empty."
        ),
    },
    "thoughts": {
        "label": "생각 노트",
        "guide": (
            "Template 생각 노트: the recorder's own ideas and plans, often one person thinking "
            "aloud. sections: ideas grouped by theme, heading = theme, bullets = the ideas as "
            "stated. key_points: the core ideas. decisions: conclusions the speaker reached. "
            "action_items: things the speaker wants to do. suggestions: 2-5 concrete "
            "suggestions from you, the assistant, that build on the ideas; phrase them as "
            "suggestions, never as something that was said. key_terms empty unless a term "
            "needs explaining."
        ),
    },
}
DEFAULT_TEMPLATE = "meeting"

_STR_LIST = {"type": "array", "items": {"type": "string"}}

SUMMARY_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "title": {"type": "string", "description": "Short note heading, at most 30 characters"},
        "one_line": {"type": "string", "description": "One sentence capturing the whole note"},
        "category": {
            "type": "string",
            "enum": SUMMARY_CATEGORIES,
            "description": (
                "업무=work, 개인=personal, 상담=consultation/customer, "
                "학습=lecture/study, 기타=other"
            ),
        },
        "topics": {**_STR_LIST, "description": "3-6 representative tags, 1-3 words each"},
        "sections": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {"heading": {"type": "string"}, "bullets": _STR_LIST},
                "required": ["heading", "bullets"],
                "additionalProperties": False,
            },
        },
        "summary": {"type": "string"},
        "key_points": _STR_LIST,
        "decisions": _STR_LIST,
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
        "open_questions": _STR_LIST,
        "key_terms": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {"term": {"type": "string"}, "explanation": {"type": "string"}},
                "required": ["term", "explanation"],
                "additionalProperties": False,
            },
        },
        "suggestions": _STR_LIST,
    },
    "required": [
        "title",
        "one_line",
        "category",
        "topics",
        "sections",
        "summary",
        "key_points",
        "decisions",
        "action_items",
        "open_questions",
        "key_terms",
        "suggestions",
    ],
    "additionalProperties": False,
}

SUMMARY_SYSTEM_PROMPT = (
    "You turn a recording transcript into a structured note. The transcript has one utterance "
    "per line as '[mm:ss] Speaker: text'; lines marked '(실시간)' are live captions without a "
    "speaker. Write every field in the language the participants spoke (Korean transcripts get "
    "Korean output). Keep speaker names exactly as given. Never invent facts, decisions, owners "
    "or dates; leave a list empty when the transcript does not support it. Speech recognition "
    "errors are possible: fix obvious ones silently. title: a short natural heading. one_line: "
    "one sentence a reader can scan in a list. topics: a few representative tags. category: "
    "the closest one. Fields the chosen template does not use must be empty ('' or [])."
)

CHAT_SYSTEM_PROMPT = (
    "You answer questions about the user's recorded note (a meeting, lecture or memo). Base "
    "the answer on the note below. After each statement taken from the transcript, cite the "
    "time of the supporting utterance in square brackets exactly as it appears in the "
    "transcript, e.g. [12:34]. If the note does not contain the answer, say so plainly instead "
    "of guessing. Answer in the language of the question, concisely; short markdown lists are "
    "fine."
)
CHAT_WEB_SUFFIX = (
    " Web search is enabled: for terms, facts or background that the note does not explain, "
    "search the web and say which parts come from the web."
)

LIVE_SUMMARY_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {"bullets": _STR_LIST},
    "required": ["bullets"],
    "additionalProperties": False,
}
LIVE_SUMMARY_PROMPT = (
    "You write the running summary shown during a live recording. Summarize this window of "
    "live captions in 1-3 short bullets (under 60 characters each) about what was discussed or "
    "decided, in the captions' language. Captions may contain recognition errors; infer the "
    "intended words when obvious. No preamble, no speaker guesses."
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


@dataclass
class AskResult:
    content: str
    model: str
    web_sources: list[dict[str, str]] = field(default_factory=list)  # {title, url}
    tokens_in: int | None = None
    tokens_out: int | None = None


@dataclass
class LiveSummaryResult:
    bullets: list[str]
    model: str
    tokens_in: int | None = None
    tokens_out: int | None = None


class Transcriber(Protocol):
    def transcribe(
        self, path: Path, known_names: list[str], known_references: list[str]
    ) -> TranscriptResult: ...

    def summarize(
        self, transcript: str, title: str | None, template: str = DEFAULT_TEMPLATE
    ) -> SummaryResult: ...

    def ask(
        self, context: str, history: list[tuple[str, str]], question: str, web_search: bool
    ) -> AskResult: ...

    def live_summarize(self, text: str, start_sec: float, end_sec: float) -> LiveSummaryResult: ...


def _clock(sec: float) -> str:
    total = int(sec)
    return f"{total // 60:02d}:{total % 60:02d}"


_UTM = re.compile(r"[?&]utm_source=openai$")


def _clean_url(url: str) -> str:
    return _UTM.sub("", url)


class OpenAITranscriber:
    def __init__(
        self,
        api_key: str,
        transcribe_model: str,
        summary_model: str,
        chat_model: str | None = None,
    ) -> None:
        from openai import OpenAI

        self.client = OpenAI(api_key=api_key)
        self.transcribe_model = transcribe_model
        self.summary_model = summary_model
        self.chat_model = chat_model or summary_model

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

    def summarize(
        self, transcript: str, title: str | None, template: str = DEFAULT_TEMPLATE
    ) -> SummaryResult:
        spec = TEMPLATES.get(template, TEMPLATES[DEFAULT_TEMPLATE])
        user = (
            f"Template: {spec['label']}\nNote title: {title or '(untitled)'}\n\n"
            f"Transcript:\n{transcript}"
        )
        response = self.client.responses.create(
            model=self.summary_model,
            input=[
                {"role": "system", "content": f"{SUMMARY_SYSTEM_PROMPT}\n\n{spec['guide']}"},
                {"role": "user", "content": user},
            ],
            text={
                "format": {
                    "type": "json_schema",
                    "name": "note_summary",
                    "schema": SUMMARY_SCHEMA,
                    "strict": True,
                }
            },
        )
        usage = response.usage
        return SummaryResult(
            data=json.loads(response.output_text),
            model=self.summary_model,
            tokens_in=usage.input_tokens if usage else None,
            tokens_out=usage.output_tokens if usage else None,
        )

    def ask(
        self, context: str, history: list[tuple[str, str]], question: str, web_search: bool
    ) -> AskResult:
        system = CHAT_SYSTEM_PROMPT + (CHAT_WEB_SUFFIX if web_search else "")
        # The note goes first and stays identical between questions, so OpenAI's automatic
        # prompt caching can reuse it.
        messages: list[dict[str, str]] = [
            {"role": "developer", "content": f"{system}\n\n# 노트\n{context}"}
        ]
        messages += [{"role": role, "content": content} for role, content in history]
        messages.append({"role": "user", "content": question})
        kwargs: dict[str, Any] = {}
        if web_search:
            kwargs["tools"] = [{"type": "web_search"}]
        response = self.client.responses.create(model=self.chat_model, input=messages, **kwargs)
        sources: list[dict[str, str]] = []
        seen: set[str] = set()
        for item in response.output:
            if getattr(item, "type", None) != "message":
                continue
            for part in getattr(item, "content", None) or []:
                for ann in getattr(part, "annotations", None) or []:
                    if getattr(ann, "type", None) != "url_citation":
                        continue
                    url = _clean_url(getattr(ann, "url", "") or "")
                    if url and url not in seen:
                        seen.add(url)
                        sources.append({"title": getattr(ann, "title", "") or url, "url": url})
        usage = response.usage
        return AskResult(
            content=response.output_text.strip(),
            model=self.chat_model,
            web_sources=sources,
            tokens_in=usage.input_tokens if usage else None,
            tokens_out=usage.output_tokens if usage else None,
        )

    def live_summarize(self, text: str, start_sec: float, end_sec: float) -> LiveSummaryResult:
        response = self.client.responses.create(
            model=self.summary_model,
            input=[
                {"role": "system", "content": LIVE_SUMMARY_PROMPT},
                {
                    "role": "user",
                    "content": f"Window {_clock(start_sec)}-{_clock(end_sec)}:\n{text}",
                },
            ],
            text={
                "format": {
                    "type": "json_schema",
                    "name": "live_summary",
                    "schema": LIVE_SUMMARY_SCHEMA,
                    "strict": True,
                }
            },
        )
        usage = response.usage
        bullets = [b.strip() for b in json.loads(response.output_text).get("bullets", [])]
        return LiveSummaryResult(
            bullets=[b for b in bullets if b][:3],
            model=self.summary_model,
            tokens_in=usage.input_tokens if usage else None,
            tokens_out=usage.output_tokens if usage else None,
        )
