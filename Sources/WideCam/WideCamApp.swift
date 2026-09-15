import AppKit
import SwiftUI

@main
struct WideCamApp: App {
    @StateObject private var camera = CameraManager()

    var body: some Scene {
        // WindowGroup은 Cmd+N으로 창이 여러 개 열리고, 그러면 하나의 AVCaptureSession을
        // 여러 프리뷰가 물게 되어 설계 §3(단일 윈도우)이 깨진다. Window는 창을 하나로
        // 묶고 새 창 메뉴 항목 자체를 없앤다(macOS 13+).
        Window("WideCam", id: "main") {
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
        // 메뉴바 상주 앱은 시작할 때 창을 열지 않는다. 이 한 줄이 없으면 SwiftUI가
        // 시작과 동시에 이 창을 띄우고, 그러면 MenuBarView의 자동 정지 판정
        // (isMainWindowVisible)이 항상 참이 되어 팝오버를 닫아도 카메라가 켜진 채로
        // 남는다. 창은 "큰 창 열기"나 창 복원 때만 열린다.
        .defaultLaunchBehavior(.suppressed)

        // 메뉴바 상주. 위 Window와 같은 camera를 공유하므로 세션은 하나다. 팝오버는
        // 켜고·찍고·끄는 일만 하고, 전체화면·해상도·좌우반전은 큰 창에 남긴다.
        // .window 스타일은 메뉴처럼 항목만 나열하는 대신 임의의 SwiftUI 뷰(라이브
        // 프리뷰)를 띄울 수 있게 한다.
        MenuBarExtra("WideCam", systemImage: "iphone.rear.camera") {
            MenuBarView(camera: camera)
        }
        .menuBarExtraStyle(.window)
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
