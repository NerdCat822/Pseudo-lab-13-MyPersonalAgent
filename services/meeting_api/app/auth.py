import secrets
from typing import Annotated

from fastapi import Depends
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.config import Settings, get_settings
from app.errors import UNAUTHORIZED_MESSAGE, api_error

_bearer = HTTPBearer(auto_error=False)


def token_is_valid(token: str | None, expected: str) -> bool:
    return token is not None and secrets.compare_digest(token.encode(), expected.encode())


def require_token(
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(_bearer)],
    settings: Annotated[Settings, Depends(get_settings)],
) -> None:
    given = credentials.credentials if credentials else None
    if not token_is_valid(given, settings.meeting_api_token):
        raise api_error(
            401, "unauthorized", UNAUTHORIZED_MESSAGE, headers={"WWW-Authenticate": "Bearer"}
        )
