import AppKit
import SwiftUI

@main
struct WideCamApp: App {
    @StateObject private var camera: CameraManager
    /// 큰 창의 NSWindow를 붙잡아 둔다. "큰 창이 세션을 쓰는 중인가"를 창 클래스와
    /// styleMask로 추정하면(이전 구현) 상태 복원이나 앱의 다른 제목줄 창 때문에 판정이
    /// 영구히 참으로 굳을 수 있다. 창 자체를 들고 isVisible을 보면 추정이 사라진다.
    @StateObject private var mainWindowHolder: WindowHolder
    /// 팝오버가 열려 있는지. 큰 창을 닫을 때 카메라를 놓아도 되는지 판단하는 데 쓴다.
    @StateObject private var popoverPresence: PopoverPresence

    init() {
        let camera = CameraManager()
        let holder = WindowHolder()
        let presence = PopoverPresence()
        // 최초 실행의 권한 대화상자는 팝오버를 닫아버린다. 허용 직후 세션을 켜면 보여줄
        // 화면이 하나도 없는 채로 카메라만 켜진 채(녹색 점) 남는다. 켜기 전에 "지금
        // 보여줄 화면이 있는가"를 묻게 한다 — CameraManager는 뷰를 모르고 이 클로저만
        // 부른다. 거절되면 .connect에 머물고, 다음 팝오버 열기의 자동 시작이 화면과
        // 함께 제대로 켠다.
        camera.isPresentationReady = { presence.isOpen || holder.window?.isVisible == true }
        _camera = StateObject(wrappedValue: camera)
        _mainWindowHolder = StateObject(wrappedValue: holder)
        _popoverPresence = StateObject(wrappedValue: presence)
    }

    var body: some Scene {
        // WindowGroup은 Cmd+N으로 창이 여러 개 열리고, 그러면 하나의 AVCaptureSession을
        // 여러 프리뷰가 물게 되어 설계 §3(단일 윈도우)이 깨진다. Window는 창을 하나로
        // 묶고 새 창 메뉴 항목 자체를 없앤다(macOS 13+).
        Window("WideCam", id: "main") {
            MainWindowView(camera: camera,
                           windowHolder: mainWindowHolder,
                           popoverPresence: popoverPresence)
        }
        // 메뉴바 상주 앱은 시작할 때 창을 열지 않는다. 이 한 줄이 없으면 SwiftUI가
        // 시작과 동시에 이 창을 띄워, 메뉴바 아이콘만 있어야 할 자리에 큰 창이 함께
        // 뜬다. 창은 "큰 창 열기"나 창 복원 때만 열린다.
        .defaultLaunchBehavior(.suppressed)

        // 메뉴바 상주. 위 Window와 같은 camera를 공유하므로 세션은 하나다. 팝오버는
        // 켜고·찍고·끄는 일만 하고, 전체화면·해상도·좌우반전은 큰 창에 남긴다.
        // .window 스타일은 메뉴처럼 항목만 나열하는 대신 임의의 SwiftUI 뷰(라이브
        // 프리뷰)를 띄울 수 있게 한다.
        // 아이콘이 녹화 상태를 말한다. 팝오버를 닫고 녹화하는 동안 앱이 내보내는 신호가
        // 하나도 없으면(경과 시간과 정지 버튼은 팝오버를 다시 열어야 보인다) 사용자는
        // 녹화 중임을 잊는다 — 전체화면 자동 숨김에서까지 녹화를 예외로 둔 기준(§9)을
        // 메뉴바에도 같이 적용한다.
        MenuBarExtra("WideCam",
                     systemImage: camera.isRecording ? "record.circle" : "iphone.rear.camera") {
            MenuBarView(camera: camera,
                        mainWindowHolder: mainWindowHolder,
                        popoverPresence: popoverPresence)
        }
        .menuBarExtraStyle(.window)
    }
}

/// 큰 창의 루트. 세 단계 화면을 고르는 일 외에 두 가지를 더 한다 — 자기 NSWindow를
/// mainWindowHolder에 넘기고, 창이 닫힐 때 카메라를 놓는다.
///
/// 생명주기 수식어를 Group이 아니라 ZStack에 붙인 이유: Group에 붙은 수식어는 자식마다
/// 따로 적용되므로, phase가 바뀌어 자식이 교체될 때 onDisappear가 불릴 수 있다. 그러면
/// 세션을 켠 직후(.connect → .capturing) 스스로 껐다 켜는 순환이 된다. ZStack은 진짜
/// 컨테이너라 수식어가 컨테이너에 붙고, 창이 사라질 때만 onDisappear가 불린다.
struct MainWindowView: View {
    @ObservedObject var camera: CameraManager
    let windowHolder: WindowHolder
    let popoverPresence: PopoverPresence

    var body: some View {
        ZStack {
            Group {
                switch camera.phase {
                case .connect:
                    ConnectView(camera: camera)
                case .capturing:
                    CaptureView(camera: camera)
                case .permissionDenied:
                    PermissionDeniedView()
                }
            }
            .frame(minWidth: 720, minHeight: 560)
        }
        // 이 창을 붙잡아 두기 위한 크기 0의 숨은 브리지. 레이아웃과 히트 테스트에
        // 영향을 주지 않는다(CaptureView의 전체화면 브리지와 같은 방식).
        .background(WindowAccessor(holder: windowHolder).frame(width: 0, height: 0))
        .onDisappear {
            // 빨간 X로 창을 닫아도 카메라를 놓는다. 팝오버가 열려 있거나 녹화 중이면
            // 그쪽이 세션을 쓰는 중이므로 유지한다. 창이 사라지는 시점과 팝오버가 열리는
            // 시점의 순서는 보장되지 않아 MenuBarView와 같이 한 턴 뒤에 판정한다.
            DispatchQueue.main.async {
                // 녹화 시작 진행 중(권한 대화상자 대기)도 녹화 중과 같게 본다 —
                // 팝오버 쪽 판정과 같은 이유다.
                guard camera.phase == .capturing,
                      !camera.isRecording,
                      !camera.isRecordingStartPending,
                      !popoverPresence.isOpen else { return }
                camera.returnToConnect()
            }
        }
    }
}

struct PermissionDeniedView: View {
    /// 팝오버(MenuBarView)도 같은 곳을 열어야 한다. 문자열을 두 벌 두면 한쪽만
    /// 고쳐졌을 때 서로 다른 설정 패널이 열린다.
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("카메라 권한이 필요합니다").font(.title2.bold())
            Text("시스템 설정 → 개인정보 보호 및 보안 → 카메라에서 WideCam을 허용해주세요.")
                .multilineTextAlignment(.center)
            Button("시스템 설정 열기") {
                NSWorkspace.shared.open(Self.settingsURL)
            }
            .buttonStyle(.glassProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
