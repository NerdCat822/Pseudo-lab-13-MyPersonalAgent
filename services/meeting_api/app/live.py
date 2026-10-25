"""Live captions: relay the app's PCM stream to OpenAI Realtime transcription.

The app opens ``WS /meetings/{id}/live`` and sends 24 kHz mono PCM16 as binary frames. The
server decides where speech turns end (``gpt-live-transcribe`` has no server VAD), forwards
only speech to OpenAI, stores finished caption lines, and pushes JSON events back:

    {"type": "status",  "state": "ready" | "reconnecting"}
    {"type": "partial", "id": ..., "at_sec": ..., "text": ...}   # grows while speaking
    {"type": "final",   "id": ..., "at_sec": ..., "end_sec": ..., "text": ...}
    {"type": "drop",    "id": ...}                                # turn produced no text
    {"type": "summary", "id": ..., "start_sec": ..., "end_sec": ..., "bullets": [...]}
    {"type": "error",   "code": ..., "message": ...}
    {"type": "closed"}                                            # after a client {"type":"stop"}

Captions are best effort: the uploaded recording segments remain the source of truth.
"""

import array
import asyncio
import base64
import collections
import contextlib
import json
import logging
import math
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Any, Protocol

from sqlalchemy.orm import Session, sessionmaker

from app.config import Settings
from app.models import LiveCaption, LiveSummary, UsageLog
from app.pipeline import summary_cost, transcribe_cost
from app.transcribe import Transcriber

log = logging.getLogger(__name__)

SAMPLE_RATE = 24000
BYTES_PER_SEC = SAMPLE_RATE * 2
FINISH_WAIT_SEC = 4.0
SUMMARY_TIMEOUT_SEC = 45.0


class UpstreamClosed(Exception):
    pass


class Upstream(Protocol):
    async def send(self, event: dict[str, Any]) -> None: ...

    async def recv(self) -> dict[str, Any]: ...  # raises UpstreamClosed

    async def close(self) -> None: ...


UpstreamFactory = Callable[[Settings], Awaitable[Upstream]]


def session_update(settings: Settings) -> dict[str, Any]:
    transcription: dict[str, Any] = {"model": settings.live_transcribe_model}
    languages = settings.live_language_list
    if settings.live_transcribe_model.startswith("gpt-live"):
        if languages:
            transcription["languages"] = languages
        if settings.live_delay:
            transcription["delay"] = settings.live_delay
    elif languages:
        transcription["language"] = languages[0]
    return {
        "type": "session.update",
        "session": {
            "type": "transcription",
            "audio": {
                "input": {
                    "format": {"type": "audio/pcm", "rate": SAMPLE_RATE},
                    "transcription": transcription,
                    "turn_detection": None,  # we commit turns ourselves
                }
            },
        },
    }


class OpenAIUpstream:
    def __init__(self, ws: Any) -> None:
        self.ws = ws

    @classmethod
    async def connect(cls, settings: Settings) -> "OpenAIUpstream":
        import websockets

        ws = await websockets.connect(
            settings.openai_realtime_url,
            additional_headers={"Authorization": f"Bearer {settings.openai_api_key}"},
            max_size=None,
            open_timeout=15,
        )
        upstream = cls(ws)
        await upstream.send(session_update(settings))
        return upstream

    async def send(self, event: dict[str, Any]) -> None:
        import websockets

        try:
            await self.ws.send(json.dumps(event))
        except websockets.ConnectionClosed as exc:
            raise UpstreamClosed(str(exc)) from exc

    async def recv(self) -> dict[str, Any]:
        import websockets

        try:
            return json.loads(await self.ws.recv())
        except websockets.ConnectionClosed as exc:
            raise UpstreamClosed(str(exc)) from exc

    async def close(self) -> None:
        with contextlib.suppress(Exception):
            await self.ws.close()


# ---- endpointing ----------------------------------------------------------------------------


def frame_db(pcm: bytes) -> float:
    samples = array.array("h")
    samples.frombytes(pcm[: len(pcm) - len(pcm) % 2])
    if not samples:
        return -120.0
    rms = math.sqrt(sum(s * s for s in samples) / len(samples))
    return 20 * math.log10(max(rms, 1.0) / 32768.0)


class EnergyVad:
    """Energy endpointing with an adaptive threshold, pre-roll and speech-only forwarding.

    ``feed`` returns ordered actions: ``("speech_start", ms)``, ``("send", pcm)``,
    ``("commit", ms)`` and ``("cancel", ms)`` (a blip shorter than ``min_speech_ms`` ended; its
    audio was already sent and simply joins the next turn). Positions are milliseconds of audio
    fed so far.
    """

    FRAME_MS = 50

    def __init__(
        self,
        sample_rate: int = SAMPLE_RATE,
        silence_ms: int = 800,
        min_speech_ms: int = 400,
        max_turn_ms: int = 15_000,
        preroll_ms: int = 300,
        floor_db: float = -55.0,
        ceil_db: float = -28.0,
        margin_db: float = 10.0,
    ) -> None:
        self.frame_bytes = sample_rate * 2 * self.FRAME_MS // 1000
        self.silence_ms = silence_ms
        self.min_speech_ms = min_speech_ms
        self.max_turn_ms = max_turn_ms
        self.floor_db, self.ceil_db, self.margin_db = floor_db, ceil_db, margin_db
        self._buf = b""
        self._levels: collections.deque[float] = collections.deque(maxlen=100)  # ~5 s
        self._preroll: collections.deque[bytes] = collections.deque(
            maxlen=max(1, preroll_ms // self.FRAME_MS)
        )
        self.speaking = False
        self._speech_ms = 0
        self._silence_ms = 0
        self._turn_ms = 0
        self.position_ms = 0

    def threshold(self) -> float:
        if len(self._levels) < 10:
            return -45.0
        noise = sorted(self._levels)[len(self._levels) // 7]  # ~15th percentile = pauses
        return min(max(noise + self.margin_db, self.floor_db), self.ceil_db)

    def feed(self, pcm: bytes) -> list[tuple[str, Any]]:
        actions: list[tuple[str, Any]] = []
        self._buf += pcm
        fb = self.frame_bytes
        while len(self._buf) >= fb:
            frame, self._buf = self._buf[:fb], self._buf[fb:]
            level = frame_db(frame)
            voiced = level > self.threshold()
            self._levels.append(level)
            if not self.speaking:
                if voiced:
                    self.speaking = True
                    self._speech_ms = self.FRAME_MS
                    self._silence_ms = 0
                    self._turn_ms = self.FRAME_MS
                    actions.append(("speech_start", self.position_ms))
                    actions.extend(("send", f) for f in self._preroll)
                    self._preroll.clear()
                    actions.append(("send", frame))
                else:
                    self._preroll.append(frame)
            else:
                actions.append(("send", frame))
                self._turn_ms += self.FRAME_MS
                if voiced:
                    self._speech_ms += self.FRAME_MS
                    self._silence_ms = 0
                else:
                    self._silence_ms += self.FRAME_MS
                end_ms = self.position_ms + self.FRAME_MS
                if self._silence_ms >= self.silence_ms:
                    self.speaking = False
                    if self._speech_ms >= self.min_speech_ms:
                        actions.append(("commit", end_ms))
                    else:
                        actions.append(("cancel", end_ms))
                elif self._turn_ms >= self.max_turn_ms:
                    # Long monologue: cut here and continue as a new turn.
                    actions.append(("commit", end_ms))
                    actions.append(("speech_start", end_ms))
                    self._turn_ms = 0
                    self._speech_ms = 0
            self.position_ms += self.FRAME_MS
        return actions

    def flush(self) -> list[tuple[str, Any]]:
        """End of stream: commit the open turn if it had enough speech."""
        if self.speaking and self._speech_ms >= self.min_speech_ms:
            self.speaking = False
            return [("commit", self.position_ms)]
        self.speaking = False
        return []


# ---- relay ----------------------------------------------------------------------------------


@dataclass
class _Item:
    at_sec: float
    end_sec: float | None = None
    text: str = ""
    done: bool = False


class LiveRelay:
    def __init__(
        self,
        *,
        meeting_id: str,
        offset_sec: float,
        settings: Settings,
        session_factory: sessionmaker[Session],
        upstream_factory: UpstreamFactory,
        summarizer: Transcriber | None,
        send_client: Callable[[dict[str, Any]], Awaitable[None]],
    ) -> None:
        self.meeting_id = meeting_id
        self.offset = max(0.0, offset_sec)
        self.settings = settings
        self.session_factory = session_factory
        self.upstream_factory = upstream_factory
        self.summarizer = summarizer
        self._send_client = send_client
        self.vad = EnergyVad()
        self.upstream: Upstream | None = None
        self._gen = 0
        self._reconnect_lock = asyncio.Lock()
        self._send_lock = asyncio.Lock()
        self.items: dict[str, _Item] = {}
        self._commits: collections.deque[tuple[float, float]] = collections.deque()
        self._turn_start: float | None = None
        self.sent_bytes = 0
        self.closed = False
        self._window: list[tuple[float, float, str]] = []
        self._window_chars = 0
        self._summary_task: asyncio.Task[None] | None = None

    # -- helpers --
    def _sec(self, ms: int) -> float:
        return round(self.offset + ms / 1000.0, 3)

    async def send_client(self, event: dict[str, Any]) -> None:
        async with self._send_lock:
            with contextlib.suppress(Exception):
                await self._send_client(event)

    async def _connect(self) -> None:
        last: Exception | None = None
        for attempt in range(3):
            try:
                self.upstream = await self.upstream_factory(self.settings)
                self._gen += 1
                return
            except Exception as exc:  # noqa: BLE001
                last = exc
                log.warning("live upstream connect failed (%d): %s", attempt + 1, exc)
                await asyncio.sleep(0.5 * (attempt + 1))
        raise RuntimeError(f"upstream unavailable: {last}")

    async def _reconnect(self, gen: int) -> None:
        async with self._reconnect_lock:
            if gen != self._gen or self.closed:
                return  # someone else already reconnected
            await self.send_client({"type": "status", "state": "reconnecting"})
            old = self.upstream
            self.upstream = None
            if old is not None:
                await old.close()
            # Whatever the old session had not finished is kept as partial text.
            for item_id, item in list(self.items.items()):
                if not item.done:
                    await self._finish_item(item_id, item, item.text)
            self._commits.clear()
            await self._connect()
            await self.send_client({"type": "status", "state": "ready"})

    async def _send_up(self, event: dict[str, Any]) -> None:
        upstream, gen = self.upstream, self._gen
        if upstream is None:
            return
        try:
            await upstream.send(event)
        except UpstreamClosed:
            await self._reconnect(gen)

    def _item(self, item_id: str) -> _Item:
        item = self.items.get(item_id)
        if item is None:
            provisional = (
                self._turn_start
                if self._turn_start is not None
                else self._sec(self.vad.position_ms)
            )
            item = _Item(at_sec=provisional)
            self.items[item_id] = item
        return item

    # -- audio in --
    async def on_audio(self, pcm: bytes) -> None:
        await self._apply(self.vad.feed(pcm))

    async def _apply(self, actions: list[tuple[str, Any]]) -> None:
        pending = bytearray()

        async def flush_audio() -> None:
            if pending:
                self.sent_bytes += len(pending)
                payload = base64.b64encode(bytes(pending)).decode("ascii")
                pending.clear()
                await self._send_up({"type": "input_audio_buffer.append", "audio": payload})

        for kind, value in actions:
            if kind == "send":
                pending.extend(value)
                continue
            await flush_audio()
            if kind == "speech_start":
                if self._turn_start is None:
                    self._turn_start = self._sec(value)
            elif kind == "commit":
                start = self._turn_start if self._turn_start is not None else self._sec(value)
                self._commits.append((start, self._sec(value)))
                self._turn_start = None
                await self._send_up({"type": "input_audio_buffer.commit"})
            elif kind == "cancel":
                self._turn_start = None
        await flush_audio()

    # -- events out --
    async def on_event(self, event: dict[str, Any]) -> None:
        kind = event.get("type", "")
        if kind == "input_audio_buffer.committed":
            item = self._item(event.get("item_id", ""))
            if self._commits:
                item.at_sec, item.end_sec = self._commits.popleft()
        elif kind == "conversation.item.input_audio_transcription.delta":
            item_id = event.get("item_id", "")
            item = self._item(item_id)
            item.text += event.get("delta", "")
            await self.send_client(
                {"type": "partial", "id": item_id, "at_sec": item.at_sec, "text": item.text.strip()}
            )
        elif kind == "conversation.item.input_audio_transcription.completed":
            item_id = event.get("item_id", "")
            item = self._item(item_id)
            await self._finish_item(item_id, item, event.get("transcript") or item.text)
        elif kind == "error":
            err = event.get("error") or {}
            code = err.get("code") or "upstream_error"
            if code == "input_audio_buffer_commit_empty":
                if self._commits:
                    self._commits.popleft()
                return
            log.warning("live upstream error: %s", err)
            await self.send_client(
                {"type": "error", "code": code, "message": err.get("message", "")}
            )

    async def _finish_item(self, item_id: str, item: _Item, text: str) -> None:
        if item.done:
            return
        item.done = True
        text = (text or "").strip()
        if not text:
            await self.send_client({"type": "drop", "id": item_id})
            return
        item.text = text
        with self.session_factory() as db:
            db.add(
                LiveCaption(
                    meeting_id=self.meeting_id, at_sec=item.at_sec, end_sec=item.end_sec, text=text
                )
            )
            db.commit()
        await self.send_client(
            {
                "type": "final",
                "id": item_id,
                "at_sec": item.at_sec,
                "end_sec": item.end_sec,
                "text": text,
            }
        )
        self._window.append((item.at_sec, item.end_sec or item.at_sec, text))
        self._window_chars += len(text)
        self._maybe_summarize()

    # -- live summary --
    def _maybe_summarize(self, force: bool = False) -> None:
        if not self._window or self.summarizer is None:
            return
        if self._summary_task is not None and not self._summary_task.done():
            return
        span = self._window[-1][1] - self._window[0][0]
        ready = (
            self._window_chars >= self.settings.live_summary_min_chars
            and span >= self.settings.live_summary_min_sec
        )
        if not (ready or (force and self._window_chars >= 40)):
            return
        window, self._window, self._window_chars = self._window, [], 0
        self._summary_task = asyncio.create_task(self._summarize(window))

    async def _summarize(self, window: list[tuple[float, float, str]]) -> None:
        start, end = window[0][0], window[-1][1]
        text = "\n".join(t for _, _, t in window)
        try:
            result = await asyncio.wait_for(
                asyncio.to_thread(self.summarizer.live_summarize, text, start, end),
                timeout=SUMMARY_TIMEOUT_SEC,
            )
        except Exception as exc:  # noqa: BLE001
            log.warning("live summary failed: %s", exc)
            return
        if not result.bullets:
            return
        with self.session_factory() as db:
            row = LiveSummary(
                meeting_id=self.meeting_id,
                start_sec=start,
                end_sec=end,
                text="\n".join(result.bullets),
            )
            db.add(row)
            db.add(
                UsageLog(
                    meeting_id=self.meeting_id,
                    model=result.model,
                    tokens_in=result.tokens_in,
                    tokens_out=result.tokens_out,
                    cost_usd=summary_cost(result.model, result.tokens_in, result.tokens_out),
                )
            )
            db.commit()
            row_id = row.id
        await self.send_client(
            {
                "type": "summary",
                "id": row_id,
                "start_sec": start,
                "end_sec": end,
                "bullets": result.bullets,
            }
        )

    # -- lifecycle --
    async def _upstream_loop(self) -> None:
        while not self.closed:
            upstream, gen = self.upstream, self._gen
            if upstream is None:
                await asyncio.sleep(0.05)
                continue
            try:
                event = await upstream.recv()
            except UpstreamClosed:
                if self.closed:
                    return
                try:
                    await self._reconnect(gen)
                except Exception as exc:  # noqa: BLE001
                    await self.send_client(
                        {"type": "error", "code": "upstream_unavailable", "message": str(exc)}
                    )
                    return
                continue
            await self.on_event(event)

    async def run(self, receive: Callable[[], Awaitable[dict[str, Any]]]) -> bool:
        """Relay until the client disconnects or sends {"type": "stop"}.

        Returns True when the client asked to stop (it is still connected and waits for
        ``closed``), False when it disconnected.
        """
        await self._connect()
        await self.send_client({"type": "status", "state": "ready"})
        reader = asyncio.create_task(self._upstream_loop())
        stopped = False
        try:
            while True:
                message = await receive()
                if message.get("type") == "websocket.disconnect":
                    break
                data = message.get("bytes")
                if data:
                    await self.on_audio(data)
                    continue
                text = message.get("text")
                if text:
                    with contextlib.suppress(ValueError):
                        if json.loads(text).get("type") == "stop":
                            stopped = True
                            break
        finally:
            await self._finish(reader)
        return stopped

    async def _finish(self, reader: asyncio.Task[None]) -> None:
        await self._apply(self.vad.flush())
        loop = asyncio.get_running_loop()
        deadline = loop.time() + FINISH_WAIT_SEC
        while loop.time() < deadline and (
            self._commits or any(not i.done for i in self.items.values())
        ):
            await asyncio.sleep(0.05)
        self.closed = True
        reader.cancel()
        with contextlib.suppress(asyncio.CancelledError, Exception):
            await reader
        if self.upstream is not None:
            await self.upstream.close()
        for item_id, item in list(self.items.items()):
            if not item.done:
                await self._finish_item(item_id, item, item.text)
        if self._summary_task is not None:
            with contextlib.suppress(Exception):
                await self._summary_task
        self._summary_task = None
        self._maybe_summarize(force=True)
        if self._summary_task is not None:
            with contextlib.suppress(Exception):
                await self._summary_task
        live_sec = self.sent_bytes / BYTES_PER_SEC
        if live_sec > 0:
            with self.session_factory() as db:
                model = self.settings.live_transcribe_model
                db.add(
                    UsageLog(
                        meeting_id=self.meeting_id,
                        model=model,
                        audio_sec=live_sec,
                        cost_usd=transcribe_cost(model, live_sec),
                    )
                )
                db.commit()
