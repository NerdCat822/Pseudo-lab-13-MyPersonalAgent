# meeting-api

Personal single-user FastAPI backend for the meeting recorder app: health check, Bearer auth,
SQLite schema, meeting/segment/speaker upload, finish signal, list and detail, plus an in-process
worker that normalizes each segment with ffmpeg, transcribes it with OpenAI
(`gpt-4o-transcribe-diarize`, speaker labels), merges the utterances with the segment offsets and
summarizes the meeting with a JSON-schema response (`gpt-5-mini`).

Note features (에이닷 노트-style, see `docs/05-anote-features.md`):

- **Templates** `meeting` 회의록, `keypoints` 요점 정리, `lecture` 강의 노트, `thoughts` 생각 노트.
  Set on `POST /meetings`, switch later with `POST /meetings/{id}/resummarize {"template": ...}`
  (re-summarizes only). Notes without a title get the generated one. The summary also carries
  `keyword_counts` (tags/terms counted in the transcript, spacing-insensitive).
- **Speaker continuity**: after each chunk the longest 2-10 s utterance of every new speaker becomes
  a reference clip, and later chunks/segments send them as `known_speaker_names` ("참석자 N").
  Long uploads are cut into `TRANSCRIBE_CHUNK_SEC` chunks.
- **Live captions** `WS /meetings/{id}/live` (Bearer header): the app streams 24 kHz PCM16, the
  server endpoints speech (adaptive energy VAD; silence is not forwarded), relays it to
  `gpt-live-transcribe`, stores final lines and pushes `partial/final/summary/status/error/closed`
  JSON events. Every `LIVE_SUMMARY_MIN_SEC` and `LIVE_SUMMARY_MIN_CHARS` it adds a 1-3 bullet
  "실시간 요약". Protocol details at the top of `app/live.py`.
- **AI 질문** `POST /meetings/{id}/chat {"question", "web_search"}`: answers from the transcript (live
  captions too while recording), `[mm:ss]` citations resolved to utterances, optional OpenAI web
  search with URL sources. History is stored (`GET`, `DELETE /chat`).
- **Edits**: `PATCH /meetings/{id}` (title, folder), `PUT /summary`, `PATCH /utterances/{uid}`,
  `PATCH /live-summaries/{sid}`. **Folders** via `folder` + `GET /folders`; **delete** with
  `DELETE /meetings/{id}` (rows and audio files). **Audio** of the whole note as one MP3:
  `GET /meetings/{id}/audio`.

Pipeline: segment `received → normalizing → transcribing → done|failed` (3 attempts), meeting
`recording → processing → merging → summarizing → done|failed`. Segments are transcribed as soon as
they arrive, even while the meeting is still recording; finalization waits until `done` segments
reach `expected_segments` from `finish`. With no speech at all the summary step is skipped (model
`none`). A restart re-queues in-flight work. `POST /meetings/{id}/retry` re-queues failed segments.

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
| `OPENAI_API_KEY` | empty | empty disables the worker; uploads then stay `received` |
| `TRANSCRIBE_MODEL` | `gpt-4o-transcribe-diarize` | only OpenAI model with speaker labels (deprecated, shuts down 2027-02-26) |
| `SUMMARY_MODEL` | `gpt-5-mini` | Responses API with a strict JSON schema |
| `WORKER_ENABLED` | `true` | tests set it to `false` |
| `WORKER_POLL_SEC` | `2` | idle poll interval |
| `SEGMENT_MAX_RETRIES` | `3` | attempts per segment before `failed` |
| `CHAT_MODEL` | `gpt-5-mini` | AI 질문 |
| `TRANSCRIBE_CHUNK_SEC` | `600` | long uploads are split into chunks of at most this length |
| `AUTO_SPEAKER_REFS` | `true` | build speaker reference clips from earlier chunks |
| `LIVE_TRANSCRIBE_MODEL` | `gpt-live-transcribe` | live captions ($0.017/min of forwarded speech) |
| `LIVE_LANGUAGES` | `ko` | comma-separated |
| `LIVE_DELAY` | `low` | latency/accuracy trade-off of gpt-live-transcribe |
| `LIVE_SUMMARY_MIN_SEC` / `LIVE_SUMMARY_MIN_CHARS` | `120` / `300` | when a 실시간 요약 window closes |

Schema changes: new tables are created on startup and missing nullable/defaulted columns are added to
existing SQLite tables (`ensure_columns`), so the dev database keeps its data. Type changes or new NOT
NULL columns without a default still need a fresh database.

Dev scripts (OpenAI key from `.env`):

- `uv run python scripts/make_test_dialogue.py` — two-voice Korean test meeting via TTS into
  `data/samples/` (git-ignored; costs well under $0.01).
- `uv run --with grpcio --with grpcio-tools python scripts/emulator_mic.py data/samples/dialogue.wav`
  — plays a WAV into the Android emulator's microphone (emulator started with `-grpc 8554`), for
  testing live captions without a real phone.

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
curl -H "$T" $B/meetings/$ID/transcript                     # utterances so far (speaker_name, start_sec, text)
curl -H "$T" $B/meetings/$ID/summary                        # 404 summary_not_ready until done
curl -H "$T" -X PATCH -H 'Content-Type: application/json' -d '{"display_name":"민수"}' \
  $B/meetings/$ID/speakers/$SPEAKER_ID                      # rename A/B labels
curl -H "$T" -X POST $B/meetings/$ID/retry                  # only when status is failed
```

Verified 2026-10-21 with a 0.5 s English sample: transcript `[0.0-0.2] A: Hello.`, summary from
`gpt-5-mini`, cost logged as $0.0008.

The finish body is `{"segment_count": N, "duration_sec": optional}`.

## Behaviour

- Every route except `/health` needs the Bearer token. A pure ASGI middleware checks it before the
  request body is read, so unauthenticated uploads are rejected without buffering anything.
- Limits: a `Content-Length` above `MAX_UPLOAD_MB` + 1 MiB gets 413 without reading the body, and
  streamed bodies (including chunked, with no Content-Length) are cut off with 413 once they pass
  that size. Each file is additionally capped at exactly `MAX_UPLOAD_MB` while it is written.
- Segments are accepted while the meeting is `recording` or `processing`; duplicate indexes return
  200 with the existing record. Errors use `{"detail": {"code", "message"}}`.

Allowed upload extensions: m4a, mp4, mp3, wav, webm, mpeg, mpga, aac, flac, ogg, oga, opus, 3gp, amr, caf.

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
| 409 | `meeting_not_failed` | `retry` on a meeting that is not `failed` |
| 404 | `summary_not_ready` | `summary` (GET or PUT) before the meeting reached `done` |
| 409 | `meeting_busy` | `resummarize` while processing; `DELETE` while the worker is on it |
| 409 | `meeting_not_finished` | `resummarize` before `finish` |
| 409 | `audio_not_ready` | `GET /audio` before every segment is normalized |
| 422 | `unknown_template` | template other than meeting, keypoints, lecture, thoughts |
| 502 | `ai_failed` | the OpenAI call behind `chat` failed (the question is not stored) |
| 503 | `ai_unavailable` | `chat` or the live socket without `OPENAI_API_KEY` |
| 413 | `request_too_large` | Whole request above `MAX_UPLOAD_MB` + 1 MiB (middleware, streaming) |
| 413 | `file_too_large` | One file above `MAX_UPLOAD_MB` while being written |
| 422 | `unsupported_extension` | Upload extension not in the allow-list |
| 422 | (FastAPI default list) | Field validation: bad UUID, `index` outside 0..9999, negative or non-finite floats |

A duplicate `(meeting, index)` upload is not an error: it returns 200 with the existing segment.

### Live socket close codes

`4401` bad token (closed before accept), `4404` unknown meeting, `4409` meeting is not `recording`,
`4503` no OpenAI key. Each is preceded by an `{"type": "error", "code": ...}` event except 4401.
