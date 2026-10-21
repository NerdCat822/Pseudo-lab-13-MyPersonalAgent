# 아이폰 설치 경로 · 무료 Apple ID 사이드로드

작성일: 2026-10-21 · 상태: 설정 중 · 전제: Mac 없음, Apple Developer Program 미가입, Windows PC + WSL2

## 0. 결정

Apple Developer Program($99/년) 대신 **무료 Apple ID 사이드로드**로 아이폰에 설치한다(2026-10-21 사용자 결정).
`.ipa`는 Codemagic의 macOS 빌더에서 **서명 없이** 만들고, Windows의 Sideloadly가 무료 Apple ID로 서명해 USB로 설치한다.

| | 무료 사이드로드 (선택) | TestFlight (기획서 7.3) |
|---|---|---|
| 비용 | 0 | $99/년 |
| 유효기간 | **7일**, 지나면 앱이 열리지 않음 → Sideloadly로 재설치(데이터 유지) | 90일 |
| 동시 설치 앱 수 | 3개 | 제한 없음 |
| 필요 장비 | Windows PC + USB 케이블 + iTunes(Apple 배포판) | 없음(TestFlight 앱) |
| 백그라운드 녹음 | `UIBackgroundModes: audio`는 plist 키라 무료 서명으로도 동작할 것으로 예상. **실기기 검증 필요(리스크 1)** | 동일 |
| 푸시 알림·iCloud | 불가(무료 계정 entitlement 없음) — MVP엔 불필요 | 가능 |

## 1. 한 번만 하는 설정

1. **GitHub**: 저장소 `NerdCat822/Pseudo-lab-13-MyPersonalAgent`에 최신 커밋을 push한다. Codemagic은 git 호스팅에서 코드를 받는다.
2. **Codemagic** (https://codemagic.io, GitHub 계정으로 가입, 개인 계정 무료 500분/월):
   - Add application → GitHub → 이 저장소 선택 → "codemagic.yaml" 선택.
   - (선택) Teams → Environment variables → 그룹 `meeting_api`에 `MEETING_API_URL`(예: `http://100.117.191.115:8000`, Tailscale 주소)과 `MEETING_API_TOKEN`(Secret 체크)을 넣으면 앱에 기본값이 들어간다. 안 넣으면 설치 후 앱 설정 화면에서 입력한다.
3. **Windows**:
   - iTunes를 **Apple 사이트 배포판**으로 설치(Microsoft Store 버전은 Sideloadly가 못 쓴다). https://support.apple.com/ko-kr/106372 의 "Windows용 iTunes" 링크.
   - Sideloadly 설치: https://sideloadly.io
4. **아이폰**: 설정 → 개인정보 보호 및 보안 → 개발자 모드 켜기(iOS 16+, 재부팅 필요). Sideloadly 설치 후 설정 → 일반 → VPN 및 기기 관리에서 본인 Apple ID 프로파일을 "신뢰".

## 2. 빌드 → 설치 (매번)

1. Codemagic → 앱 → Start new build → workflow **"iOS unsigned IPA (sideload)"** → 브랜치 main → Start. 약 10~15분.
2. 빌드 완료 화면의 Artifacts에서 `meeting_recorder-0.1.0-1-unsigned.ipa` 내려받기.
3. 아이폰을 USB로 PC에 연결하고 "이 컴퓨터를 신뢰" 허용. Sideloadly 실행 → IPA 드래그 → Apple ID 입력 → Start. 2단계 인증 코드를 물으면 입력. 비밀번호는 Sideloadly가 Apple 서버에 직접 보낸다.
4. 7일 뒤 앱이 안 열리면 같은 IPA를 Sideloadly로 다시 설치한다(앱 데이터는 남는다).

## 3. 폰에서 서버 접속

- 같은 Wi-Fi: `http://192.168.0.23:8000` (Windows 포트프록시 8000 → WSL, 2026-10-21 동작 확인).
- 어디서나: 폰에 Tailscale 설치 후 `http://100.117.191.115:8000` (이 PC의 Tailscale 주소, 동작 확인). iOS는 HTTP 평문 접속을 기본 차단하므로 `Info.plist`에 `NSAppTransportSecurity`의 `NSAllowsArbitraryLoads`가 켜져 있어야 한다(아래 4장).
- WSL IP가 바뀌면 관리자 PowerShell에서 포트프록시를 다시 만든다(02 문서 참고).

## 4. 코드 쪽에서 맞춘 것

- `codemagic.yaml`에 `ios-unsigned-ipa` 워크플로 추가: `flutter build ios --release --no-codesign` → `Payload/Runner.app`을 zip → `.ipa` 아티팩트.
- `ios/Runner/Info.plist`: HTTP 서버에 붙기 위한 `NSAppTransportSecurity` 예외.

## 5. 알아 둘 제약

- 무료 Apple ID는 **7일마다 재서명**해야 하고, 10일 동안 등록할 수 있는 App ID 수에 제한이 있다(Sideloadly가 번들 ID에 Apple ID를 붙여 충돌을 피한다).
- Sideloadly가 USB 없이 Wi-Fi로도 설치할 수 있지만 첫 설치는 USB가 안정적이다.
- 백그라운드·화면 잠금 녹음 2시간 검증(기획서 리스크 1)은 이 경로로 설치한 뒤 바로 해 본다. 실패하면 유료 계정 여부와 무관한 iOS 제약이므로 화면 켜둔 운영으로 간다.
