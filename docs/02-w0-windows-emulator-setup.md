# W0 · Android 에뮬레이터 설정 안내 (WSL2 내부 KVM 방식)

작성일: 2026-10-20 · 갱신: 2026-10-21 · 대상: 개발자 본인 · 상태: **검증 완료** (2026-10-21, Windows 사용자 `김현규` PC)

## 0. 결론 먼저

**에뮬레이터도 WSL2 안에서 KVM으로 돌린다.** Windows 쪽 에뮬레이터(WHPX)는 이 PC에서 부팅되지 않았고, WSL2는 중첩 가상화로
`/dev/kvm`을 제공하므로 빌드·adb·에뮬레이터·백엔드가 전부 WSL 한 곳에서 돈다. Windows ↔ WSL adb 브리지, portproxy,
mirrored 네트워킹이 모두 필요 없다. 에뮬레이터 창은 WSLg를 통해 Windows 바탕화면에 뜬다.

2026-10-21 검증 결과:
- `flutter doctor` Flutter·Android toolchain 녹색 (Linux desktop toolchain 빨강은 의도적으로 무시).
- AVD `pixel_api36`(API 36, google_apis x86_64, RAM 2GB, 소프트웨어 GPU) 콜드 부팅 약 75초.
- 디버그 APK 설치 → Hello World 표시 확인. `flutter devices`에 `emulator-5554` 표시.
- WSL에서 `uvicorn --host 0.0.0.0 --port 8000` 실행 → 에뮬레이터 Chrome에서 `http://10.0.2.2:8000/health` 200 확인.

## 1. WSL2 쪽 구성 (설치 완료)

| 항목 | 위치 / 버전 |
|---|---|
| Flutter | `~/development/flutter` 3.47.7 stable (Dart 3.13.5) |
| JDK | `~/development/jdk-21` Temurin 21 (Gradle 9.3 / AGP 9.1 요구) |
| Android SDK | `~/Android/Sdk` — cmdline-tools 23, platform-tools 37.0.1, platforms 35·36, build-tools 36.0.0, NDK 28.2.13676358, emulator 37.2.12, system-images;android-36;google_apis;x86_64 |
| AVD | `~/.android/avd/pixel_api36.avd` (hw.ramSize=2048, hw.gpu.mode=swiftshader_indirect, hw.keyboard=yes) |
| 환경변수 | `~/.flutter-android-toolchain.sh` — `~/.zshrc`·`~/.bashrc`가 source. JAVA_HOME, ANDROID_HOME, PATH, 헬퍼 함수 |
| KVM 권한 | `nerdcat`을 `kvm` 그룹에 추가함 (sudo 없이 `wsl.exe -u root -- usermod -aG kvm nerdcat`). 새 셸부터 적용 |

sudo 비밀번호는 모르지만 Windows에서 `wsl.exe -u root -- <명령>`으로 루트 명령을 실행할 수 있다.

## 2. 일상 개발 루프

```bash
emu                    # AVD pixel_api36 부팅 (헬퍼 함수, 로그 ~/.android/emu-wsl.log)
adb devices            # emulator-5554  device
flutter devices
cd apps/meeting_recorder && flutter run -d emulator-5554
```

- 그룹 추가 전에 열어 둔 셸에서는 `sg kvm -c "emulator -avd pixel_api36 -gpu swiftshader_indirect"`로 띄운다.
- 백엔드: `cd services/meeting_api && uv run uvicorn app.main:app --host 0.0.0.0 --port 8000`. 앱 설정의 서버 주소는 `http://10.0.2.2:8000`(에뮬레이터에서 WSL 호스트). `.env`에 `MEETING_API_TOKEN` 필요(`.env.example` 참고, git 제외).
- 마이크: 에뮬레이터는 WSLg 오디오를 쓰지 못한다(`-allow-host-audio`를 줘도 로그에 "Could not init `pa' audio driver", 2026-10-25 확인). 그래서 녹음 파일이 무음이었다. 대신 에뮬레이터 gRPC API로 WAV를 마이크에 직접 넣는다: `emu`가 `-grpc 8554`를 열고, `services/meeting_api/scripts/emulator_mic.py`가 `injectAudio`로 재생한다. 테스트 음성은 `scripts/make_test_dialogue.py`(TTS 2인 대화). 이 방식으로 실시간 받아쓰기·요약·녹음 업로드·화자 분리를 앱에서 끝까지 확인했다.
- 창 충돌: WSLg 화면 서버가 재시작되면 에뮬레이터도 같이 죽는다("X connection to :0 broken"). 자동 검증이나 장시간 작업은 `-no-window`(헤드리스)로 띄우고 `adb exec-out screencap`으로 화면을 본다.
- 빌드 중 메모리: 에뮬레이터 + Gradle 빌드를 같이 돌리면 에뮬레이터가 멈추거나 WSL이 재시작된 적이 있다(2026-10-25). 큰 빌드 전에는 에뮬레이터를 내리고, 빌드 후 `./gradlew --stop`.
- 메모리: 호스트 15.7GB. `C:\Users\김현규\.wslconfig`에 `memory=8GB`, `autoMemoryReclaim=gradual`을 넣어 두었다(다음 `wsl --shutdown` 후 적용). Gradle 데몬이 3GB까지 먹으므로 부족하면 `./gradlew --stop`.

## 3. Windows 쪽 에뮬레이터를 쓰지 않는 이유 (2026-10-21 조사)

Windows에는 Android Studio, SDK(`C:\Users\김현규\AppData\Local\Android\Sdk`), AVD `Pixel_10_Pro`(android-37.0 Play Store 이미지)가 있다.
그러나 다음 순서로 전부 실패했다.

1. 에뮬레이터 36.5.11은 android-37.0 이미지가 요구하는 기능(VulkanVirtualQueue)을 지원하지 않음 → 37.2.12로 업데이트(Windows cmdline-tools도 설치함).
2. 호스트 GPU(NVIDIA RTX 2050) 모드에서 "graphics driver crashed"로 종료 → `-gpu swiftshader`.
3. 소프트웨어 GPU·코어 1개로도 게스트 CPU가 전혀 실행되지 않음(qemu CPU 시간 0초, `detected a hanging thread 'QEMU2 CPU0 thread'`).
   Windows 11 **26H2(빌드 26300)** 에서 WHPX 부팅이 멈추는 QEMU 버그 보고([qemu#3178](https://gitlab.com/qemu-project/qemu/-/issues/3178), 25H2에서 보고)와 증상이 같다.
   AEHD 드라이버는 설치되어 있지만 Hyper-V 때문에 STOPPED 상태라 대안이 못 된다(2026-12-31 지원 종료 예정).

Windows 쪽 상태를 그래도 쓰고 싶을 때를 위해 아래 사실은 남겨 둔다.
- WSL2 기본 NAT 모드에서도 Windows adb 서버(`adb.exe -a -P 5037 nodaemon server`)에 WSL 클라이언트가 방화벽 설정 없이 붙었다(게이트웨이 `ip route show default`).
- 헬퍼: `adb-win-server`(Windows adb 서버를 `-a`로 재시작하고 `ADB_SERVER_SOCKET` 설정), `adb-use-windows`, `adb-use-wsl`.
- Windows AVD `Pixel_10_Pro`의 `hw.gpu.mode`는 `swiftshader`로 바꿔 두었다(원본은 `config.ini.bak-20261021`).

## 4. W0 완료 체크리스트

- [x] WSL2 Flutter·JDK·Android SDK 설치, `flutter doctor` 통과
- [x] `/dev/kvm` 접근, AVD 생성, 에뮬레이터 부팅
- [x] `adb devices`·`flutter devices`에 에뮬레이터 표시
- [x] 디버그 APK 설치·실행 (Hello World)
- [x] 에뮬레이터 → WSL 백엔드 `http://10.0.2.2:8000/health` 응답
- [ ] 에뮬레이터 마이크 입력 동작 (W1 녹음 스파이크에서 확인)
- [ ] GitHub 원격 저장소 + Codemagic Android 빌드 (저장소 이름·공개 범위 결정 필요)

## 5. 아직 결정·설치되지 않은 것

- Tailscale: Windows에도 WSL에도 없다. W4(운영 배포)에서 설치한다. 실기기(iPhone)에서 백엔드에 붙는 유일한 경로다.
- Apple Developer 가입: W1 시작 시.
- gh CLI 없음.
