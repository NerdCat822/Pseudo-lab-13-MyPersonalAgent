import asyncio
import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI

from app import __version__
from app.config import get_settings
from app.db import create_tables, make_engine, make_session_factory
from app.live import OpenAIUpstream
from app.middleware import BodyGuardMiddleware
from app.routers import health, live, meetings
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
    # The worker, "AI에게 질문하기" and live summaries share one OpenAI wrapper; live captions
    # get a factory for upstream Realtime connections. Tests replace both on app.state.
    app.state.transcriber = None
    app.state.live_upstream_factory = None
    if settings.openai_api_key:
        app.state.transcriber = OpenAITranscriber(
            settings.openai_api_key,
            settings.transcribe_model,
            settings.summary_model,
            settings.chat_model,
        )
        app.state.live_upstream_factory = OpenAIUpstream.connect
    else:
        log.warning("OPENAI_API_KEY is empty: worker, chat and live captions are disabled")

    stop = asyncio.Event()
    task: asyncio.Task[None] | None = None
    if settings.worker_enabled and app.state.transcriber is not None:
        reset_stale(app.state.session_factory)
        task = asyncio.create_task(
            worker_loop(app.state.session_factory, settings, app.state.transcriber, stop)
        )
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
    app.include_router(meetings.meta_router)
    app.include_router(live.router)

    # Wrap the complete stack so the guard sits outside Starlette's error middleware.
    build_stack = app.build_middleware_stack
    app.build_middleware_stack = lambda: BodyGuardMiddleware(build_stack(), get_settings)
    return app


app = create_app()
