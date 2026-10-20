# meeting-api

Personal single-user FastAPI backend for the meeting recorder app. W0 scope: health check,
Bearer auth, SQLite schema, meeting/segment/speaker upload, finish signal, list and detail.
Transcription (OpenAI) arrives in W2; the worker will pick up meetings in `processing` status.

## Run

```bash
cp .env.example .env        # set MEETING_API_TOKEN
uv sync
uv run uvicorn app.main:app --reload --port 8000
```

Tables are created automatically on startup (`create_all`). There is no migration tool yet;
Alembic comes later, so schema changes still require deleting the dev SQLite file
(`data/meeting_api.db*`) during development.

Docker: `mkdir -p data` first, then `docker compose up --build`. Compose reads `.env`, publishes
`127.0.0.1:8000` only, and bind-mounts `./data`. The container runs as uid 1000; if Docker creates
`./data` for you it is owned by root and the app cannot write to it, so create it yourself as your
own user (uid 1000 on a typical Ubuntu/WSL2 setup).

On WSL2 the default Docker build network could not reach the Debian apt mirrors (`apt-get` failed with "Unable to locate package ffmpeg"). Build with host networking: `docker build --network=host -t meeting-api .` (verified 2026-10-20; the image is about 740 MB because of ffmpeg).

Checks: `uv run ruff check . && uv run ruff format --check . && uv run pytest -q`

## Configuration

| Variable | Default | Notes |
|---|---|---|
| `MEETING_API_TOKEN` | required | Bearer token, 32+ chars (`openssl rand -hex 32`); `change-me` is rejected |
| `DATA_DIR` | `./data` | audio files and SQLite |
| `DATABASE_URL` | `sqlite:///<DATA_DIR>/meeting_api.db` | |
| `MAX_UPLOAD_MB` | `200` | see Limits below |
| `ENABLE_DOCS` | `false` | serve `/docs`, `/redoc`, `/openapi.json` |

## curl examples

```bash
export T="Authorization: Bearer $MEETING_API_TOKEN" B=http://localhost:8000

curl $B/health                                              # no auth
ID=$(curl -s -H "$T" -H 'Content-Type: application/json' -d '{"title":"Weekly sync"}' \
  $B/meetings | python -c 'import sys,json; print(json.load(sys.stdin)["id"])')

curl -H "$T" -F display_name=Alice -F file=@alice.wav $B/meetings/$ID/speakers   # max 4
curl -H "$T" -F index=0 -F start_offset_sec=0 -F duration_sec=600 -F file=@000.m4a \
  $B/meetings/$ID/segments                                  # 202; duplicate index -> 409
curl -H "$T" $B/meetings/$ID                                # detail + progress
curl -H "$T" "$B/meetings?q=weekly&limit=20&offset=0"       # list / title search
curl -H "$T" -H 'Content-Type: application/json' -d '{"segment_count": 3}' \
  $B/meetings/$ID/finish                                    # -> processing
```

The finish body is `{"segment_count": N, "duration_sec": optional}`.

## Behaviour

- Every route except `/health` needs the Bearer token. A pure ASGI middleware checks it before the
  request body is read, so unauthenticated uploads are rejected without buffering anything.
- Limits: a `Content-Length` above `MAX_UPLOAD_MB` + 1 MiB gets 413 without reading the body, and
  streamed bodies (including chunked, with no Content-Length) are cut off with 413 once they pass
  that size. Each file is additionally capped at exactly `MAX_UPLOAD_MB` while it is written.
- Segments are accepted while the meeting is `recording` or `processing`; duplicate indexes return
  200 with the existing record. Errors use `{"detail": {"code", "message"}}`.

Allowed upload extensions: m4a, mp4, mp3, wav, webm, mpeg, mpga.

### Error codes (the Flutter client branches on `detail.code`)

| HTTP | code | When |
|---|---|---|
| 401 | `unauthorized` | Missing or wrong Bearer token (also from the middleware, before the body is read) |
| 404 | `not_found` | Unknown meeting id |
| 409 | `meeting_not_recording` | `finish` or speaker registration on a meeting that is not `recording` |
| 409 | `segment_count_too_small` | `finish` with `segment_count` not greater than the highest index already uploaded |
| 409 | `index_out_of_range` | Segment `index >= expected_segments` after `finish` |
| 409 | `meeting_closed` | Segment upload while the meeting is merging, summarizing, done or failed |
| 409 | `speaker_limit` | Fifth speaker on one meeting |
| 413 | `request_too_large` | Whole request above `MAX_UPLOAD_MB` + 1 MiB (middleware, streaming) |
| 413 | `file_too_large` | One file above `MAX_UPLOAD_MB` while being written |
| 422 | `unsupported_extension` | Upload extension not in the allow-list |
| 422 | (FastAPI default list) | Field validation: bad UUID, `index` outside 0..9999, negative or non-finite floats |

A duplicate `(meeting, index)` upload is not an error: it returns 200 with the existing segment.
