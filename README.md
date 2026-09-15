# WideCam

*A macOS menu bar app that uses your iPhone's Continuity Camera at the widest field of view the API allows (1920×1440, Center Stage forced off).*

아이폰 연속성 카메라(Continuity Camera)를 **API가 허용하는 최대 화각**으로 쓰게 해주는 macOS 메뉴바 앱이다. 4:3 1920×1440 포맷을 강제하고 센터 스테이지를 앱 권한으로 꺼둔다.

## 왜 만들었나

아이폰을 연속성 카메라로 맥에 연결하면, Photo Booth 같은 기본 앱에서는 센터 스테이지를 꺼도 아이폰에서 직접 보는 것보다 좁게(줌인된 상태로) 나온다. 화각을 되돌릴 방법을 AVFoundation에서 찾다가 실측으로 확인한 것은 다음 세 가지다.

- macOS AVFoundation에는 `videoZoomFactor`, `videoFieldOfView`, `AVCaptureSession.Preset.inputPriority`가 **없다**(`API_UNAVAILABLE(macos)`). 줌으로 화각을 넓히는 길은 애초에 막혀 있다.
- 그래서 남는 수단은 **포맷 선택 + 센터 스테이지 해제** 둘뿐이다. 아이폰이 노출하는 포맷은 8종이고 최대는 1920×1440(4:3)이다.
- 센터 스테이지는 `AVCaptureDevice.centerStageControlMode = .app`으로 제어권을 가져온 뒤 `isCenterStageEnabled = false`로 앱이 강제 해제할 수 있다.

즉 **이 앱이 뽑는 1920×1440이 서드파티 앱이 얻을 수 있는 최대치**다. 아이폰 카메라 앱의 초광각(0.5x) 화각은 macOS API가 노출하지 않으므로 어떤 앱도 얻을 수 없다. WideCam은 그 상한선을 항상 유지하는 것까지만 한다.

구현하면서 밟은 함정도 기록해 둔다.

- `session.startRunning()`이 `activeFormat`을 1920×1080으로 **되돌린다**. 포맷 강제는 반드시 시작 *후*에 해야 하고, 그 뒤로도 `activeFormat`을 KVO로 지켜보다가 외부 요인으로 되돌아가면 즉시 재강제한다.
- 프리뷰 레이어에 `layer.session = ...`을 대입하는 것도 세션 변형이다. 메인 스레드에서 대입하면 `startRunning()`이 연결 컬렉션을 순회하는 중에 그 컬렉션이 바뀌어 프로세스가 죽는다(실제로 죽었다). 세션을 만지는 모든 경로를 `sessionQueue` 하나로 직렬화해서 막았다.

## 주요 기능

- **메뉴바 상주**: 아이콘을 누르면 라이브 프리뷰 팝오버가 뜬다. 사진 촬영, 녹화 시작/정지, 큰 창 열기, 종료. 팝오버를 열면 카메라가 켜지고 닫으면 꺼진다(녹화 중이거나 큰 창이 열려 있으면 유지).
- **큰 창**: 자리가 필요한 조작을 모아뒀다. 해상도·프레임레이트 선택, 좌우반전(프리뷰에만 적용되고 저장물은 비반전), 전체화면, 마지막 저장물 Finder에서 보기.
- **화각 강제**: 기본값은 4:3 최대 해상도에 30fps 이상 중 가장 낮은 fps. 센터 스테이지 해제에 실패하면 "화각이 좁을 수 있습니다"를 화면에 그대로 띄운다(조용한 실패 금지).
- **프리뷰 레터박스**: `videoGravity = .resizeAspect`. 창 비율이 4:3이 아니어도 화각을 잘라내지 않는다.
- **사진·영상**: 사진은 HEIC(HEVC 코덱을 못 쓰는 환경에서는 JPEG로 내려간다), 영상은 .mov / HEVC에 아이폰 마이크 소리를 담는다.
- **저장**: `~/Pictures/WideCam/`에 `WideCam_yyyyMMdd_HHmmss.heic` / `.mov`. 파일명 해상도가 1초라 같은 초에 두 번 찍으면 뒤의 것이 앞의 것을 덮어쓰게 되므로 `_2`, `_3` … 접미사를 붙인다.
- **Liquid Glass**: macOS 26+의 `glassEffect` / `GlassEffectContainer` / 글라스 버튼 스타일을 쓴다. 다크·라이트는 시스템 머티리얼에 맡긴다.
- **기기가 안 보일 때**: 맥의 Wi-Fi가 꺼져 있으면 일반 안내보다 위에 그 사실을 먼저 알린다(CoreWLAN으로 실측, 위치 권한은 요구하지 않는다).

## 요구사항

- macOS 26 이상 (`Package.swift`의 `platforms`, 번들의 `LSMinimumSystemVersion` 모두 26.0)
- 연속성 카메라를 지원하는 아이폰. 맥과 같은 Apple 계정으로 로그인, 양쪽 Wi-Fi·블루투스 켜기(USB 연결이 가장 안정적)
- Swift 6.1 이상 툴체인(`Package.swift`의 swift-tools-version). **Xcode는 필요 없고 Command Line Tools만으로 빌드된다**(`xcode-select --install`)

## 빌드와 실행

```bash
swift build
swift run WideCam
```

`swift run`으로 띄우는 개발 실행에는 Dock 아이콘이 있다. 메뉴바 전용(`LSUIElement`)은 배포 번들의 Info.plist에만 들어가므로, 메뉴바 상주 동작을 확인하려면 아래 `./deploy.sh`로 설치한 쪽을 봐야 한다.

빌드 중 `ld: warning: search path '/Library/Developer/CommandLineTools/Developer/...' not found` 경고 두 줄이 나오는 것은 정상이다. 빌드 시스템이 Xcode 레이아웃을 가정해서 나오는 것이고 결과물에는 영향이 없다.

## 테스트

```bash
./scripts/test.sh
```

**반드시 이 래퍼로 돌려야 한다.** Command Line Tools 환경에서 plain `swift test`는 Swift Testing 매크로 플러그인 탐색이 간헐적으로 실패한다. 실측 통과율이 대략 25%(클린 빌드 1/5, 증분 1/3)였고, 실패할 때는 코드와 무관한 빌드 오류가 난다.

```
error: external macro implementation type 'TestingMacros.TestDeclarationMacro' could not be found
       for macro 'Test'; plugin for module 'TestingMacros' not found
```

원인은 `swiftbuild` 백엔드가 `plugins/testing/` 하위에 있는 이 플러그인을 비결정적으로 놓치는 것이다. 래퍼는 `-Xswiftc -load-plugin-library`로 플러그인 경로를 직접 박아 넣어 그 탐색 단계를 없앤다(실측 9/9 통과). 플래그를 `Package.swift`에 넣지 않은 이유는 `.unsafeFlags`가 되어 매니페스트를 오염시키고 경로가 머신 종속 절대경로이기 때문이다.

현재 테스트는 8개다. 포맷 기본값 선택 로직과 저장 경로·파일명 생성처럼 카메라 없이 검증할 수 있는 순수 로직을 덮는다.

## 설치

```bash
./deploy.sh              # 빌드 → /Applications/WideCam.app 번들 생성 → 서명 → 실행
./deploy.sh --skip-build # 기존 .build/release 바이너리 재사용
./deploy.sh --no-launch  # 설치만 하고 실행하지 않음
```

**쓰기 전에 스크립트 상단 `IDENTITY` 변수를 본인의 Apple Development 인증서 이름으로 바꿔야 한다.** `security find-identity -v -p codesigning`으로 이름을 확인해서 그대로 넣으면 된다. 스크립트는 시작할 때 그 인증서가 키체인에 있는지 검사하고 없으면 중단한다.

ad-hoc 서명(`-`)은 권하지 않는다. 서명 신원이 바뀌면 macOS가 다른 앱으로 보기 때문에 리빌드마다 TCC 카메라·마이크 권한을 다시 물어본다.

## 알려진 제약

- **전면(셀카) 카메라는 쓸 수 없다.** macOS의 연속성 카메라 API가 아이폰 전면 카메라를 노출하지 않는다. 목록에는 macOS가 연속성 카메라로 보고하는 기기(후면 카메라, 데스크뷰)만 올라온다.
- **초광각(0.5x)은 불가**. 위에 적은 대로 API 자체의 한계다.
- **로컬 전용**. 공증(notarization)도 스토어 배포도 하지 않는다. 본인 맥에서 본인 인증서로 서명해 쓰는 것을 전제로 만들었다.
- 다른 앱에서 웹캠으로 쓰는 가상 카메라 기능은 없다(CoreMediaIO 확장이 필요해 범위 밖으로 뒀다).
- 다국어 없음. UI는 한국어다.

## 프로젝트 구조

```
widecam_app/
├── Package.swift
├── Sources/WideCam/
│   ├── WideCamApp.swift        # 앱 엔트리, MenuBarExtra·Window scene, 큰 창 루트
│   ├── MenuBarView.swift       # 메뉴바 팝오버 (프리뷰·사진·녹화·큰 창 열기·종료)
│   ├── CameraManager.swift     # 세션·포맷강제·센터스테이지·캡처 (유일한 AVFoundation 접점)
│   ├── ConnectView.swift       # 연결 화면 (기기 목록)
│   ├── CaptureView.swift       # 촬영 화면 + 글라스 툴바
│   ├── PreviewLayerView.swift  # AVCaptureVideoPreviewLayer NSViewRepresentable
│   ├── ConnectivityHint.swift  # 기기 미발견 원인 실측 (CoreWLAN Wi-Fi 전원)
│   ├── WindowAccessor.swift    # SwiftUI 뷰 ↔ 자기 NSWindow 브리지 (전체화면·창 추적)
│   └── MediaStore.swift        # 저장 경로·파일명 생성 (순수 로직)
├── Tests/WideCamTests/         # 포맷 선택·파일명 로직 단위 테스트
├── Resources/AppIcon.icns      # 앱 아이콘 (Info.plist는 deploy.sh가 생성)
├── scripts/test.sh             # 매크로 플러그인 경로를 고정한 swift test 래퍼
└── deploy.sh                   # 빌드 → 번들 생성 → 서명 → 실행
```

뷰는 `CameraManager`의 `@Published` 상태만 구독한다. `@Published` 변경은 메인 큐에서, 세션과 포맷 조작은 `sessionQueue`에서 한다는 규칙을 코드 전체에서 지킨다.

## 개발 노트

설계 판단의 근거와 실측 기록은 저장소 안에 남겨뒀다.

- `docs/superpowers/specs/2026-09-15-widecam-design.md` — 설계 문서. API 실측 결과, 화각 강제 로직, 범위 밖 항목
- `docs/superpowers/plans/2026-09-15-widecam.md` — 구현 계획서
- `.superpowers/sdd/2026-09-15-widecam/` — 태스크별 작업 보고와 리뷰 기록

## 라이선스

MIT. [LICENSE](LICENSE) 참조.
