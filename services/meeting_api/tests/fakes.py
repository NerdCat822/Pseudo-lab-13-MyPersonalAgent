"""Shared test doubles: a scriptable fake OpenAI wrapper and audio helpers."""

import math
import struct
import wave
from collections.abc import Callable
from pathlib import Path

from fastapi.testclient import TestClient

from app.config import get_settings
from app.transcribe import (
    AskResult,
    DiarizedSegment,
    LiveSummaryResult,
    SummaryResult,
    TranscriptResult,
)
from app.worker import run_once


def make_wav(path: Path, seconds: float = 1.0, freq: float = 440.0, rate: int = 16000) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        frames = b"".join(
            struct.pack("<h", int(12000 * math.sin(2 * math.pi * freq * i / rate)))
            for i in range(int(rate * seconds))
        )
        w.writeframes(frames)
    return path


def fake_summary_data(**overrides) -> dict:
    data = {
        "title": "인사 나눔",
        "one_line": "두 사람이 인사를 나눴다.",
        "category": "개인",
        "topics": ["인사", "반갑습니다"],
        "sections": [{"heading": "인사", "bullets": ["안녕하세요", "반갑습니다"]}],
        "summary": "짧은 인사",
        "key_points": ["안녕하세요", "반갑습니다"],
        "decisions": [],
        "action_items": [{"what": "후속 미팅", "who": "B", "due": ""}],
        "open_questions": [],
        "key_terms": [{"term": "인사", "explanation": "만나서 하는 말"}],
        "suggestions": [],
    }
    data.update(overrides)
    return data


SegmentsFn = Callable[[Path, list[str]], list[DiarizedSegment]]


class FakeTranscriber:
    def __init__(self, fail_times: int = 0, segments: SegmentsFn | None = None) -> None:
        self.calls: list[tuple[Path, list[str], list[str]]] = []
        self.summaries: list[str] = []
        self.templates: list[str] = []
        self.asks: list[tuple[str, list[tuple[str, str]], str, bool]] = []
        self.live: list[tuple[str, float, float]] = []
        self.fail_times = fail_times
        self.segments_fn = segments
        self.answer = "두 사람이 인사를 나눴습니다 [00:00]. 이어서 반갑다고 했습니다 [00:00]."
        self.ask_error: Exception | None = None

    def transcribe(self, path: Path, known_names, known_references) -> TranscriptResult:
        self.calls.append((path, list(known_names), list(known_references)))
        if self.fail_times > 0:
            self.fail_times -= 1
            raise RuntimeError("boom")
        if self.segments_fn is not None:
            segments = self.segments_fn(path, list(known_names))
        else:
            speaker = known_names[0] if known_names else "A"
            segments = [
                DiarizedSegment(speaker=speaker, start=0.0, end=0.4, text="안녕하세요"),
                DiarizedSegment(speaker="B", start=0.5, end=0.9, text="네 반갑습니다"),
            ]
        return TranscriptResult(segments=segments, audio_sec=1.0, request_id="req-1")

    def summarize(self, transcript: str, title: str | None, template: str = "meeting"):
        self.summaries.append(transcript)
        self.templates.append(template)
        return SummaryResult(data=fake_summary_data(), model="fake", tokens_in=10, tokens_out=5)

    def ask(self, context, history, question, web_search) -> AskResult:
        self.asks.append((context, list(history), question, web_search))
        if self.ask_error is not None:
            raise self.ask_error
        return AskResult(
            content=self.answer,
            model="fake",
            web_sources=[{"title": "예시", "url": "https://example.com/a"}] if web_search else [],
            tokens_in=100,
            tokens_out=20,
        )

    def live_summarize(self, text: str, start_sec: float, end_sec: float):
        self.live.append((text, start_sec, end_sec))
        return LiveSummaryResult(bullets=["인사를 나눔"], model="fake", tokens_in=10, tokens_out=5)


def upload_wav(client: TestClient, mid: str, wav: Path, index: int, offset: float | None = None):
    r = client.post(
        f"/meetings/{mid}/segments",
        data={"index": index, "start_offset_sec": index * 600.0 if offset is None else offset},
        files={"file": (f"{index}.wav", wav.read_bytes(), "audio/wav")},
    )
    assert r.status_code == 202, r.text
    return r.json()


def drain(client: TestClient, transcriber, max_steps: int = 30) -> int:
    factory = client.app.state.session_factory
    steps = 0
    while run_once(factory, get_settings(), transcriber):
        steps += 1
        assert steps < max_steps, "worker did not converge"
    return steps
