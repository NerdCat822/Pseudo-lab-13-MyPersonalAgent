from fastapi import HTTPException

UNAUTHORIZED_MESSAGE = "Invalid or missing bearer token"


def error_detail(code: str, message: str) -> dict[str, str]:
    return {"code": code, "message": message}


def api_error(
    status_code: int, code: str, message: str, headers: dict[str, str] | None = None
) -> HTTPException:
    return HTTPException(status_code, detail=error_detail(code, message), headers=headers)
