# W0 · Windows 쪽 Android 에뮬레이터 + WSL2 브리지 설정 안내

작성일: 2026-10-20 · 대상: 개발자 본인(Windows 사용자 `NICE`) · 상태: W0에서 직접 수행·검증 필요

WSL2에서는 에뮬레이터를 띄울 수 없으므로 **에뮬레이터는 Windows, 빌드는 WSL2**로 나눈다.
이 문서는 Windows에서 손으로 해야 하는 단계와, WSL2 쪽 연결 방법을 적는다. 2026-10-20 기준 Windows에는
Android Studio, adb, Tailscale이 모두 설치되어 있지 않다.

## 1. WSL2 네트워킹 모드 결정 (먼저 할 것)

현재 WSL2는 기본 **NAT 모드**다(`/mnt/c/Users/NICE/.wslconfig` 없음, WSL에서 본 Windows 호스트 IP는 `172.25.0.1`,
재부팅 시 바뀔 수 있음). 두 가지 길이 있고 **mirrored 모드를 권장**한다.

| | NAT (기본) | mirrored (권장) |
|---|---|---|
| WSL → Windows adb 서버 | 게이트웨이 IP(`ip route`로 확인)로 접속, 방화벽 규칙 필요 | `localhost:5037` |
| 에뮬레이터 → WSL 백엔드 | `netsh interface portproxy`로 WSL 포트를 Windows에 노출해야 함 | 에뮬레이터에서 `10.0.2.2:8000`이 바로 WSL 포트에 닿음 |
| 요구 사항 | 없음 | Windows 11 22H2 이상 |

mirrored 모드 설정: Windows에서 `C:\Users\NICE\.wslconfig` 파일을 만들고 아래를 넣은 뒤 PowerShell에서 `wsl --shutdown` 후 다시 연다.

```ini
[wsl2]
networkingMode=mirrored
```

확인: WSL에서 `ip route show default`가 더 이상 `172.25.x.x`가 아니고 Windows와 같은 네트워크로 보이면 적용된 것이다.

## 2. Windows에 Android Studio 설치 (수동)

1. https://developer.android.com/studio 에서 Android Studio 설치. 기본 구성 그대로 두면 SDK가 `C:\Users\NICE\AppData\Local\Android\Sdk`에 깔린다.
2. SDK Manager에서 확인: **Android SDK Platform-Tools**, **Android Emulator**, 그리고 WSL 쪽 Flutter가 쓰는 플랫폼과 같은 API 레벨의 **system image**(x86_64, Google APIs).
3. Device Manager에서 AVD 생성: Pixel 계열, API 34 이상, x86_64. RAM 2~4GB.
4. 에뮬레이터 실행 후 **Extended controls(…) → Microphone → "Virtual microphone uses host audio input"** 켜기. 이걸 안 켜면 녹음 테스트가 무음으로 나온다.

## 3. adb 브리지: WSL2의 Flutter가 Windows 에뮬레이터를 보게 하기

핵심 조건 두 가지.
- **adb 버전이 양쪽에서 같아야 한다.** Windows의 `platform-tools\adb.exe version`과 WSL의 `adb version`이 다르면 서로 서버를 죽이고 다시 띄우는 일이 반복된다. 둘 다 SDK Manager / sdkmanager로 최신 platform-tools를 받으면 보통 같아진다.
- adb **서버는 Windows 하나만** 돈다. WSL은 클라이언트로만 붙는다.

### 3.1 Windows 쪽

PowerShell(일반 권한)에서, 에뮬레이터를 켠 뒤:

```powershell
cd $env:LOCALAPPDATA\Android\Sdk\platform-tools
.\adb.exe kill-server
.\adb.exe -a -P 5037 nodaemon server     # 모든 인터페이스에서 수신. 이 창은 켜둔다
```

NAT 모드라면 Windows 방화벽에서 TCP 5037 인바운드를 WSL 서브넷(예: 172.25.0.0/20)에 허용해야 한다. mirrored 모드면 필요 없다.

### 3.2 WSL 쪽

```bash
# mirrored 모드
export ADB_SERVER_SOCKET=tcp:127.0.0.1:5037
# NAT 모드 (IP는 `ip route show default`의 게이트웨이)
export ADB_SERVER_SOCKET=tcp:172.25.0.1:5037

adb devices          # emulator-5554 가 보여야 한다
flutter devices      # 같은 에뮬레이터가 보여야 한다
```

성공하면 `~/.zshrc`의 툴체인 블록에 `export ADB_SERVER_SOCKET=...` 한 줄을 추가한다. NAT 모드에서는 IP가 바뀔 수 있으므로
`export ADB_SERVER_SOCKET=tcp:$(ip route show default | awk '{print $3}'):5037` 처럼 동적으로 잡는다.

### 3.3 대안 (브리지가 계속 불안정할 때)

- WSL의 `$ANDROID_HOME/platform-tools/adb`를 Windows `adb.exe`를 호출하는 래퍼 스크립트로 바꾸는 방법이 있다. 버전 불일치 문제를 원천 제거한다.
- 그래도 안 되면 Flutter를 Windows에 설치하고 저장소를 Windows 파일시스템(예: `C:\dev\pseudo-lab-13`)으로 옮긴다.
  `\\wsl$` 경로에서 Gradle 빌드는 매우 느리므로 저장소 위치를 꼭 옮겨야 한다.

## 4. 에뮬레이터에서 WSL2 백엔드(FastAPI :8000) 접속

- 에뮬레이터 안에서 Windows 호스트는 항상 `10.0.2.2`다.
- mirrored 모드: WSL에서 `uvicorn ... --host 0.0.0.0 --port 8000`을 띄우면 에뮬레이터에서 `http://10.0.2.2:8000/health`로 바로 닿는다.
- NAT 모드: PowerShell(관리자)에서 WSL IP(`hostname -I`로 확인)로 포트프록시를 만든다. WSL IP가 바뀌면 다시 해야 한다.

```powershell
netsh interface portproxy add v4tov4 listenport=8000 listenaddress=0.0.0.0 connectport=8000 connectaddress=<WSL IP>
```

앱 설정 화면의 서버 주소에는 `http://10.0.2.2:8000`을 넣는다(에뮬레이터 전용). 실제 iPhone에서는 Tailscale 주소를 쓴다(W4).

## 5. W0 완료 체크리스트

- [ ] `.wslconfig` mirrored 적용 또는 NAT 유지 결정
- [ ] Android Studio 설치, AVD 생성, 호스트 마이크 연결
- [ ] Windows adb 서버 `-a` 모드로 실행
- [ ] WSL `adb devices`와 `flutter devices`에 에뮬레이터 표시
- [ ] WSL에서 `flutter run`으로 에뮬레이터에 앱 실행
- [ ] 에뮬레이터 브라우저에서 `http://10.0.2.2:8000/health` 응답 확인

## 6. 아직 결정·설치되지 않은 것

- Tailscale: Windows에도 WSL에도 없다. W4(운영 배포)에서 설치한다. 실기기(iPhone)에서 백엔드에 붙는 유일한 경로다.
- Apple Developer 가입: W1 시작 시.
