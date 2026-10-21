import asyncio
import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI

from app import __version__
from app.config import get_settings
from app.db import create_tables, make_engine, make_session_factory
from app.middleware import BodyGuardMiddleware
from app.routers import health, meetings
from app.transcribe import OpenAITranscriber
from app.worker import reset_stale, worker_loop

log = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    settings = get_settings()
    settings.data_dir.mkdir(parents=True, exist_ok=True)
    engine = make_engine(settings.database_url)
    create_tables(engine)
    app.state.session_factory = make_session_factory(engine)

    stop = asyncio.Event()
    task: asyncio.Task[None] | None = None
    if settings.worker_enabled:
        if settings.openai_api_key:
            reset_stale(app.state.session_factory)
            transcriber = OpenAITranscriber(
                settings.openai_api_key, settings.transcribe_model, settings.summary_model
            )
            task = asyncio.create_task(
                worker_loop(app.state.session_factory, settings, transcriber, stop)
            )
        else:
            log.warning("OPENAI_API_KEY is empty: worker disabled, segments stay 'received'")
    try:
        yield
    finally:
        stop.set()
        if task is not None:
            await task
        engine.dispose()


def create_app() -> FastAPI:
    settings = get_settings()
    app = FastAPI(
        title="Meeting API",
        version=__version__,
        lifespan=lifespan,
        docs_url="/docs" if settings.enable_docs else None,
        redoc_url="/redoc" if settings.enable_docs else None,
        openapi_url="/openapi.json" if settings.enable_docs else None,
    )
    app.include_router(health.router)
    app.include_router(meetings.router)

    # Wrap the complete stack so the guard sits outside Starlette's error middleware.
    build_stack = app.build_middleware_stack
    app.build_middleware_stack = lambda: BodyGuardMiddleware(build_stack(), get_settings)
    return app


app = create_app()
