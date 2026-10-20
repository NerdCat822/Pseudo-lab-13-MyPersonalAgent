from collections.abc import Callable

from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from app.auth import token_is_valid
from app.config import Settings
from app.errors import UNAUTHORIZED_MESSAGE, error_detail

SLACK_BYTES = 1024 * 1024
OPEN_PATHS = {"/health"}


class _BodyTooLarge(Exception):
    pass


class BodyGuardMiddleware:
    """Pure ASGI guard that authenticates and caps request size before any body is parsed.

    It must wrap the whole application (including Starlette's error middleware) so that it
    can replace the 500 produced by the abort with a clean 413.
    """

    def __init__(self, app: ASGIApp, get_settings: Callable[[], Settings]) -> None:
        self.app = app
        self.get_settings = get_settings

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http" or scope["path"] in OPEN_PATHS:
            await self.app(scope, receive, send)
            return

        settings = self.get_settings()
        headers = {k.lower(): v for k, v in scope["headers"]}
        auth = headers.get(b"authorization", b"").decode("latin-1")
        scheme, _, token = auth.partition(" ")
        if scheme.lower() != "bearer" or not token_is_valid(token, settings.meeting_api_token):
            response = JSONResponse(
                {"detail": error_detail("unauthorized", UNAUTHORIZED_MESSAGE)},
                status_code=401,
                headers={"WWW-Authenticate": "Bearer"},
            )
            await response(scope, receive, send)
            return

        limit = settings.max_upload_bytes + SLACK_BYTES
        too_large = JSONResponse(
            {
                "detail": error_detail(
                    "request_too_large", f"Request exceeds {settings.max_upload_mb} MB limit"
                )
            },
            status_code=413,
        )
        declared = headers.get(b"content-length")
        if declared is not None and declared.isdigit() and int(declared) > limit:
            await too_large(scope, receive, send)
            return

        total = 0
        exceeded = False
        started = False

        async def wrapped_receive() -> Message:
            nonlocal total, exceeded
            message = await receive()
            if message["type"] == "http.request":
                total += len(message.get("body", b""))
                if total > limit:
                    exceeded = True
                    raise _BodyTooLarge
            return message

        async def wrapped_send(message: Message) -> None:
            nonlocal started
            if exceeded:
                return
            if message["type"] == "http.response.start":
                started = True
            await send(message)

        try:
            await self.app(scope, wrapped_receive, wrapped_send)
        except Exception:
            if not exceeded:
                raise
        if exceeded and not started:
            await too_large(scope, receive, send)
