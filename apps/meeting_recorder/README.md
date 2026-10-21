# meeting_recorder

Flutter client for `services/meeting_api`. Screens: meeting list, record (segmented recording with
immediate upload), meeting detail (progress polling, speaker-labelled transcript, summary, speaker
rename, markdown share) and settings (server URL, token, segment length).

## Run on the WSL2 emulator

```bash
emu                                   # boot AVD pixel_api36 (see docs/02)
TOKEN=$(grep '^MEETING_API_TOKEN=' ../../services/meeting_api/.env | cut -d= -f2)
flutter run -d emulator-5554 \
  --dart-define=MEETING_API_URL=http://10.0.2.2:8000 \
  --dart-define=MEETING_API_TOKEN=$TOKEN
```

The dart-defines are only defaults; the settings screen overrides them and stores values in
`flutter_secure_storage`. Grant the microphone once with
`adb shell pm grant dev.pseudolab13.meeting_recorder android.permission.RECORD_AUDIO` or accept the
prompt. Checks: `flutter analyze && flutter test`.

## Layout

```
lib/app/settings.dart            AppSettings + secure-storage repository + provider
lib/app/api.dart                 MeetingApi (dio) and ApiException (server error codes)
lib/app/models.dart              MeetingItem/Detail, Utterance, MeetingSummary, formatters
lib/features/home_screen.dart    list + FAB
lib/features/record/             RecordingController (record 7.x, segment rotation, upload retry)
lib/features/meeting/            MeetingScreen (poll every 3 s while active)
lib/features/settings_screen.dart
```

## Not yet done (W1 items)

- Upload queue is in memory; a kill during recording loses pending uploads (drift queue pending).
- No foreground service / background recording yet; keep the app in the foreground.
- Emulator microphone capture is unverified (recorded segments were silent on 2026-10-21).
- Speaker registration UI (reference clips) is not exposed; the server supports it.
