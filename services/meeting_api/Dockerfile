FROM python:3.12.12-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*

COPY --from=ghcr.io/astral-sh/uv:0.9.14 /uv /usr/local/bin/uv

RUN useradd --create-home --uid 1000 app \
    && mkdir -p /app /data \
    && chown app:app /app /data
WORKDIR /app
USER app

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never \
    PATH="/app/.venv/bin:$PATH" \
    DATA_DIR=/data

COPY --chown=app:app pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev
COPY --chown=app:app app ./app

VOLUME ["/data"]
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request as u; u.urlopen('http://127.0.0.1:8000/health', timeout=3)"
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
