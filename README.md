# pseudo-lab-13

모바일 앱 시리즈 프로젝트. 앱(Flutter)과 백엔드(FastAPI)를 한 저장소에 둔다.

| # | 앱 | 상태 | 기획서 |
|---|---|---|---|
| 01 | 회의 녹음·전사 앱 (Flutter 앱 + FastAPI 백엔드 + OpenAI STT) | W0 환경 구축 중 | [docs/01-meeting-recorder-plan.md](docs/01-meeting-recorder-plan.md) |

## 저장소 구조

```
apps/meeting_recorder/     Flutter 앱 (Android APK + iOS)
services/meeting_api/      FastAPI 백엔드 (OpenAI 키 보관, 전사·요약 파이프라인, SQLite)
docs/                      기획서와 설정 안내
codemagic.yaml             Android APK / iOS TestFlight CI (수동 트리거)
```

## 개발 환경 요약

- 빌드·백엔드는 WSL2(Ubuntu 22.04), Android 에뮬레이터는 Windows. 연결 방법은 [docs/02-w0-windows-emulator-setup.md](docs/02-w0-windows-emulator-setup.md).
- iOS는 로컬 빌드 불가. Codemagic → TestFlight로만 설치한다.
- 백엔드 실행: `cd services/meeting_api && uv sync && uv run uvicorn app.main:app --reload --host 0.0.0.0 --port 8000` (자세한 내용은 해당 디렉터리 README).
