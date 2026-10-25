# meeting_recorder

Flutter client for `services/meeting_api`, modelled on 에이닷 노트 (feature map in
`docs/05-anote-features.md`).

- **홈**: notes grouped by day with AI title, one-line summary, template and tags; title search,
  category chips, folder filter; **새 노트** → 지금 녹음 / 파일 가져오기.
- **녹음**: template chips, 실시간 받아쓰기 switch, live captions with partial lines, 실시간 요약
  card, 중요 표시, AI 질문 sheet while recording. Live on = one PCM16 24 kHz stream feeding gapless
  WAV segments and the server's live socket; live off = AAC 48 kbps segments.
- **파일 가져오기**: any audio file (voice memos included) becomes a note with the chosen template.
- **노트**: 노트 / 받아쓰기 / AI 질문 tabs. Template chip re-summarizes with another template;
  long-press to edit bullets, decisions, to-dos, live summaries and transcript lines; rename
  speakers; tap a line or a `[mm:ss]` citation to play from there.
- **공유**: pick note / 실시간 요약 / 받아쓰기, then text, PDF (Noto Sans KR fetched on first use),
  clipboard or the whole recording as MP3. Menu: rename, move to folder, delete.

## Run on the WSL2 emulator

```bash
emu                                   # boot AVD pixel_api36 (see docs/02); opens gRPC port 8554
TOKEN=$(grep '^MEETING_API_TOKEN=' ../../services/meeting_api/.env | cut -d= -f2)
flutter run -d emulator-5554 \
  --dart-define=MEETING_API_URL=http://10.0.2.2:8000 \
  --dart-define=MEETING_API_TOKEN=$TOKEN
```

The dart-defines are only defaults; the settings screen overrides them (stored in
`flutter_secure_storage`) and also holds the live-captions default and the default template.
Grant the microphone once with
`adb shell pm grant dev.pseudolab13.meeting_recorder android.permission.RECORD_AUDIO`.

To test live captions, start a recording and feed speech into the emulator mic (it cannot hear the
PC microphone):

```bash
cd ../../services/meeting_api
uv run python scripts/make_test_dialogue.py            # once: data/samples/dialogue.wav
uv run --with grpcio --with grpcio-tools python scripts/emulator_mic.py data/samples/dialogue.wav
```

Checks: `flutter analyze && flutter test` (models, export, WAV writer).

## Layout

```
lib/app/settings.dart              AppSettings (+ live default, template) and secure storage
lib/app/api.dart                   MeetingApi (dio) and ApiException (server error codes)
lib/app/models.dart                notes, summary v3, chat, live summaries, templates, formatters
lib/app/theme.dart                 colors, template icons
lib/features/home_screen.dart      list, filters, new-note chooser
lib/features/record/               RecordingController, WavSegmentWriter, LiveClient, screen
lib/features/import/               ImportScreen (file picker → upload → finish)
lib/features/meeting/              MeetingScreen, NoteView, ChatView, share sheet, PDF/markdown export
lib/features/settings_screen.dart
```

## Not yet done

- Upload queue is in memory; a kill during recording loses pending uploads (issue #3).
- No Android foreground service yet; keep the app in the foreground while recording (issue #4).
- Speaker registration UI (reference clips) is not exposed; automatic references cover most cases
  (issue #5).
- Live mode uploads uncompressed WAV (about 8x AAC); prefer Wi-Fi.
- Not verified on a real iPhone: live mode with the screen locked, PDF share sheet, file picker.
