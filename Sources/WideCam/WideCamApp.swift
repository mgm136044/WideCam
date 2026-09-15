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
    }
}

struct PermissionDeniedView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("카메라 권한이 필요합니다").font(.title2.bold())
            Text("시스템 설정 → 개인정보 보호 및 보안 → 카메라에서 WideCam을 허용해주세요.")
                .multilineTextAlignment(.center)
            Button("시스템 설정 열기") {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
            }
            .buttonStyle(.glassProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
