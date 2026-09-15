# WideCam 설계 문서

날짜: 2026-09-15
상태: 승인됨 (사용자 승인 완료, 스파이크 실측 반영)

## 1. 목적

macOS의 연속성 카메라(Continuity Camera)로 아이폰을 연결하면 Photo Booth 등 기본
앱에서는 센터 스테이지를 꺼도 아이폰 기본 카메라보다 좁은(줌인된) 화각으로만
나온다. WideCam은 **API가 허용하는 최대 화각을 강제로 유지**하며 미리보기·사진
촬영·영상 녹화를 제공하는 개인용 macOS 앱이다.

- 대상 사용자: 본인 1인 (로컬 사용, 스토어/공증 배포 없음)
- UI 언어: 한국어
- 디자인: macOS 26+ Liquid Glass (리퀴드 글라스)

## 2. 스파이크 실측 결과 (2026-09-15, macOS 27.0 + 아이폰 실기기)

이 설계는 아래 실측 사실에 근거한다.

1. 아이폰 연속성 카메라가 노출하는 포맷은 8종이며 최대는 **1920×1440 (4:3),
   1~60fps**. 모든 포맷이 센터 스테이지 지원(`isCenterStageSupported=true`).
2. macOS AVFoundation에는 `videoZoomFactor`, `videoFieldOfView`,
   `AVCaptureSession.Preset.inputPriority`가 **존재하지 않는다**
   (`API_UNAVAILABLE(macos)`). 따라서 줌으로 화각을 넓히는 길은 없고,
   **포맷 선택 + 센터 스테이지 해제**가 화각을 넓히는 유일한 수단이다.
   초광각(0.5x) 전체 화각은 어떤 서드파티 앱도 얻을 수 없다.
3. 센터 스테이지는 클래스 속성 `AVCaptureDevice.centerStageControlMode = .app`
   설정 후 `AVCaptureDevice.isCenterStageEnabled = false`로 **앱이 강제 해제
   가능**함을 확인했다 (mode 0→1 전환 및 enabled=false 유지 실측).
4. **함정**: `session.startRunning()`이 `activeFormat`을 1920×1080으로 되돌린다.
   `startRunning()` **이후에** `activeFormat`을 재설정해야 1920×1440이 유지된다
   (1920×1440 프레임 저장으로 실측 확인).
5. 카메라 TCC 권한은 이 맥에서 이미 승인 상태였으나, 신규 앱 번들은 자체적으로
   권한을 받아야 하며 Info.plist의 `NSCameraUsageDescription` 없이는 크래시한다.

## 3. 화면 흐름

메뉴바 상주 앱이다. **메뉴바 아이콘 → 팝오버(라이브 프리뷰) → 필요할 때만 큰 창**이
기본 동선이고, Dock 아이콘은 없다(배포 번들 `LSUIElement`). 앱을 시작하면 창 없이
메뉴바 아이콘만 남는다.

- **팝오버**(`MenuBarView`): 아래 3.1·3.2·권한 안내를 압축한 한 화면. 열면 카메라가
  켜지고(기기가 있으면 자동 선택) 닫으면 꺼진다 — 녹화 중이거나 큰 창이 열려 있으면
  세션을 유지한다. 사진·녹화·큰 창 열기·종료만 담는다.
- **큰 창**(`Window(id: "main")`): 해상도 선택, 좌우반전, 전체화면, 마지막 저장물
  Finder에서 보기처럼 자리가 필요한 조작이 있는 곳. 팝오버의 "큰 창 열기"로 열고,
  빨간 X로 닫으면(팝오버도 닫혀 있고 녹화 중이 아니면) 카메라를 놓는다.

두 화면은 하나의 `CameraManager`와 하나의 `AVCaptureSession`을 공유한다. 아래 3.1·3.2는
큰 창의 2단계 화면 전환을 말한다.

### 3.1 연결 화면 (시작 화면)
- 감지된 연속성 카메라(아이폰) 목록을 글라스 카드로 표시. 기기명 클릭 시 촬영
  화면으로 전환.
- 기기가 없으면 안내 문구: 같은 Apple ID 로그인, Wi-Fi/블루투스 켜기, USB 연결이
  가장 안정적임을 설명.
- `AVCaptureDevice.wasConnectedNotification` / `wasDisconnectedNotification`으로
  목록 실시간 갱신.
- 촬영 중 기기 연결이 끊기면 이 화면으로 복귀.

### 3.2 촬영 화면
- 라이브 프리뷰: `AVCaptureVideoPreviewLayer`, `videoGravity = .resizeAspect`
  (레터박스). 화면 비율과 달라도 **화각 전체 보존**이 원칙.
- 하단 플로팅 글라스 툴바(Liquid Glass, `GlassEffectContainer`):
  - 사진 촬영 버튼
  - 녹화 시작/정지 버튼 (녹화 중 경과 시간 표시)
  - 포맷 선택 (기본 1920×1440@30, 목록은 기기가 노출하는 포맷에서 생성)
  - 좌우반전(미러) 토글 — 프리뷰에만 적용, 저장물은 비반전
  - 전체화면 버튼 (macOS 표준 전체화면, 프리뷰는 여전히 aspect-fit)
  - 마지막 저장물 Finder에서 보기
- 창 제목: WideCam. 앱 상태 표시: 센터 스테이지 강제 해제 여부.

## 4. 화각 강제 로직 (핵심)

`CameraManager`가 다음 순서를 보장한다.

1. 세션 구성 (입력=아이폰, 출력=프리뷰/사진/동영상)
2. `startRunning()`
3. **그 후** `lockForConfiguration()` → `activeFormat = 1920×1440` 재설정
4. `centerStageControlMode = .app`, `isCenterStageEnabled = false`
5. `activeFormat` KVO 감시 — 외부 요인으로 포맷이 되돌아가면 즉시 재강제
   (재강제 루프 방지를 위해 자신이 설정 중일 때는 무시)

## 5. 캡처와 저장

- 사진: `AVCapturePhotoOutput`, HEIC. 촬영 시 셔터 플래시 효과(화면 깜빡임)만,
  소리 없음.
- 영상: `AVCaptureMovieFileOutput`, .mov(HEVC 기본). 아이폰 마이크를 오디오
  입력으로 포함 (`NSMicrophoneUsageDescription` 필요).
- 저장 위치: `~/Pictures/WideCam/`, 파일명 `WideCam_yyyyMMdd_HHmmss.heic/.mov`.
- 촬영/녹화 완료 후 툴바에서 마지막 파일 Finder 표시 가능.

## 6. 구조

SwiftUI + AVFoundation. Swift Package Manager 실행 파일 타깃.

```
widecam_app/
├── Package.swift
├── Sources/WideCam/
│   ├── WideCamApp.swift        # 앱 엔트리, 메뉴바/윈도우 scene, 큰 창 루트
│   ├── MenuBarView.swift       # 메뉴바 팝오버 (프리뷰·사진·녹화·큰 창 열기·종료)
│   ├── CameraManager.swift     # 세션·포맷강제·센터스테이지·캡처 (ObservableObject)
│   ├── ConnectView.swift       # 연결 화면
│   ├── CaptureView.swift       # 촬영 화면 + 글라스 툴바
│   ├── PreviewLayerView.swift  # AVCaptureVideoPreviewLayer NSViewRepresentable
│   ├── WindowAccessor.swift    # SwiftUI 뷰 ↔ 자기 NSWindow 브리지 (전체화면·창 추적)
│   └── MediaStore.swift        # 저장 경로·파일명 생성 (순수 로직, 단위 테스트 대상)
├── Tests/WideCamTests/         # 포맷 선택·파일명 로직 단위 테스트
├── Resources/AppIcon.icns      # 앱 아이콘 (Info.plist는 deploy.sh가 생성)
├── deploy.sh                   # 빌드→번들 생성→서명→실행
└── docs/superpowers/specs/     # 본 문서
```

- `CameraManager`: 기기 발견, 세션 수명주기, §4 강제 로직, 사진/영상 캡처를
  담당하는 유일한 AVFoundation 접점. 뷰는 이 매니저의 상태만 구독한다.
- 포맷 선택 로직(노출 포맷 목록 → 기본값 결정)은 순수 함수로 분리해 단위 테스트.

## 7. 디자인 (Liquid Glass)

- macOS 26+ SwiftUI `glassEffect` / `GlassEffectContainer` / 글라스 버튼 스타일
  사용. 촬영 화면 툴바는 프리뷰 위에 떠 있는 글라스 바, 연결 화면은 글라스 카드.
- 다크/라이트 모두 시스템 머티리얼에 위임 (수동 색상 하드코딩 최소화).
- 정확한 API 명칭(SDK 시그니처)은 구현 시 컴파일로 검증한다.

## 8. 빌드·배포 (RainDrop 방식과 다른 점)

RainDrop의 deploy.sh는 기존 번들에 바이너리만 교체하는 방식이라 신규 앱에는
쓸 수 없다. WideCam의 deploy.sh는 **번들 생성부터** 수행한다.

1. `swift build -c release`
2. `/Applications/WideCam.app` 뼈대 생성 (Contents/MacOS, Contents/Resources,
   Info.plist — 번들 ID `com.mingyeongmin.WideCam`, 카메라/마이크 사용 설명 포함)
3. 바이너리 배치
4. 코드 서명: RainDrop과 동일한 Apple Development 인증서
   (`Apple Development: YOUR NAME (TEAMID)`) — 서명 신원이
   안정적이어야 TCC 카메라 권한이 리빌드 후에도 유지된다. ad-hoc은 빌드마다
   권한을 다시 묻게 되므로 쓰지 않는다.
5. `codesign -v` 검증 후 실행

## 9. 오류 처리

- 카메라 권한 거부: 촬영 화면 대신 시스템 설정으로 안내하는 화면 표시.
- 기기 연결 끊김: 연결 화면으로 복귀, 녹화 중이었다면 녹화 파일은 그 시점까지
  저장됨을 안내.
- 포맷 강제 실패(미래 OS 변경 등): 실제 activeFormat을 UI에 그대로 표시해
  사용자가 눈치챌 수 있게 한다 (조용한 실패 금지).
- 디스크 쓰기 실패: 촬영 화면에 배너로 오류 표시.

## 10. 검증 계획

- 단위 테스트: 포맷 기본값 선택 로직, 파일명/경로 생성 (swift test).
- 수동 체크리스트 (실기기):
  1. 앱 시작 → 메뉴바 아이콘만 표시(큰 창·Dock 없음) → 아이콘 클릭 → 팝오버에 아이폰 표시
  2. 선택 → 프리뷰가 4:3 1920×1440으로 표시 (Photo Booth 대비 넓은 화각 확인)
  3. 제어 센터에서 센터 스테이지를 켜도 앱 화면은 넓은 화각 유지(강제 해제 동작)
  4. 사진 촬영 → `~/Pictures/WideCam/`에 HEIC 저장, 해상도 1920×1440
  5. 녹화 시작/정지 → .mov 저장, 소리 포함
  6. 전체화면 전환 → 화각 전체 유지(레터박스)
  7. 촬영 중 아이폰 잠금/이탈 → 연결 화면 복귀, 크래시 없음
  8. 앱 재실행 → 카메라 권한 재요청 없음 (서명 안정성 확인)

## 11. 범위 밖 (명시적 제외)

- 가상 카메라(다른 앱에서 웹캠으로 사용) — 필요해지면 CoreMediaIO 확장으로 별도
  프로젝트
- 초광각(0.5x) 화각 — macOS API가 노출하지 않음 (실측 §2)
- 스토어 배포/공증, 자동 업데이트, 다국어
