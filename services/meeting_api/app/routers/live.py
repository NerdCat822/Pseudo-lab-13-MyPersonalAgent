"""WS /meetings/{id}/live — live captions relay (see app/live.py for the protocol)."""

import logging
import uuid

from fastapi import APIRouter, WebSocket

from app.auth import token_is_valid
from app.config import get_settings
from app.live import LiveRelay
from app.models import Meeting, MeetingStatus

log = logging.getLogger(__name__)
router = APIRouter()


async def _reject(ws: WebSocket, code: int, error: str, message: str) -> None:
    await ws.accept()
    await ws.send_json({"type": "error", "code": error, "message": message})
    await ws.close(code=code)


@router.websocket("/meetings/{meeting_id}/live")
async def live_captions(websocket: WebSocket, meeting_id: str) -> None:
    settings = get_settings()
    # The HTTP auth middleware does not cover WebSocket scopes; check the bearer token here.
    # Only the Authorization header is accepted (a query token would end up in access logs).
    scheme, _, token = websocket.headers.get("authorization", "").partition(" ")
    if scheme.lower() != "bearer" or not token_is_valid(token, settings.meeting_api_token):
        await websocket.close(code=4401)
        return
    try:
        mid = str(uuid.UUID(meeting_id))
    except ValueError:
        await _reject(websocket, 4404, "not_found", "Meeting not found")
        return
    state = websocket.app.state
    with state.session_factory() as db:
        meeting = db.get(Meeting, mid)
        meeting_status = meeting.status if meeting else None
    if meeting_status is None:
        await _reject(websocket, 4404, "not_found", "Meeting not found")
        return
    if meeting_status != MeetingStatus.recording:
        await _reject(websocket, 4409, "meeting_not_recording", "Meeting is not recording")
        return
    upstream_factory = getattr(state, "live_upstream_factory", None)
    if upstream_factory is None:
        await _reject(websocket, 4503, "ai_unavailable", "Live captions are not configured")
        return
    try:
        offset = max(0.0, float(websocket.query_params.get("offset") or 0))
    except ValueError:
        offset = 0.0

    await websocket.accept()
    relay = LiveRelay(
        meeting_id=mid,
        offset_sec=offset,
        settings=settings,
        session_factory=state.session_factory,
        upstream_factory=upstream_factory,
        summarizer=getattr(state, "transcriber", None),
        send_client=websocket.send_json,
    )
    try:
        stopped = await relay.run(websocket.receive)
    except Exception as exc:  # noqa: BLE001
        log.warning("live relay for %s ended with error: %s", mid, exc)
        await relay.send_client(
            {"type": "error", "code": "upstream_unavailable", "message": str(exc)[:300]}
        )
        stopped = True
    if stopped:
        await relay.send_client({"type": "closed"})
        try:
            await websocket.close()
        except RuntimeError:
            pass
