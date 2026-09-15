import AppKit
import AVFoundation
import SwiftUI

/// 메뉴바 아이콘을 눌렀을 때 뜨는 팝오버. 큰 창(Window "main")과 같은 CameraManager를
/// 공유하므로 세션은 하나이고, 팝오버와 큰 창의 프리뷰 레이어가 같은 AVCaptureSession에
/// 동시에 붙을 수 있다(AVFoundation은 한 세션에 여러 AVCaptureVideoPreviewLayer를 허용).
///
/// 스타일: 팝오버는 이미 시스템 재질 위에 뜨므로 배경에 .glassEffect를 한 겹 더 깔지
/// 않고, 버튼만 큰 창(CaptureView·ConnectView)과 같은 glass 스타일로 맞췄다.
///
/// @State는 이 머신에서 컴파일되지 않으므로(매크로 플러그인 dylib 부재) 지역 상태를
/// 두지 않고 camera의 @Published만 구독한다.
struct MenuBarView: View {
    @ObservedObject var camera: CameraManager
    @Environment(\.openWindow) private var openWindow

    /// 프리뷰는 4:3 고정 크기다. 팝오버는 창처럼 늘릴 수 없으므로 화각 전체가 들어가는
    /// 비율로 못 박고, 세밀한 조정은 큰 창에 맡긴다.
    private let previewWidth: CGFloat = 320
    private let previewHeight: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch camera.phase {
            case .connect:
                connectSection
            case .capturing:
                captureSection
            case .permissionDenied:
                permissionSection
            }

            // 조용한 실패 금지(설계 §9). 메뉴바만 쓰는 사용자도 실패 사유를 봐야 한다.
            if let message = camera.errorBanner {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("닫기") { camera.clearError() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            }
        }
        .padding(12)
        .frame(width: previewWidth + 24)
        .onAppear {
            // 팝오버를 여는 행동 자체를 "카메라 켜기"로 본다. 메뉴바 앱에서 아이콘을
            // 누른 뒤 기기를 한 번 더 고르게 하면 클릭이 두 번이 된다.
            if camera.phase == .connect, let device = camera.availableDevices.first {
                camera.select(device: device)
            }
        }
        .onDisappear {
            // 팝오버를 닫으면 카메라를 놓아(녹색 점 소등) 쓰지 않는 동안 아이폰
            // 카메라를 점유하지 않는다. 단 녹화 중이거나 큰 창이 세션을 쓰는 중이면
            // 유지한다.
            //
            // 판정을 다음 메인 큐 턴으로 미루는 이유: "큰 창 열기"는 창을 열면서
            // 팝오버를 닫으므로 onDisappear가 창이 화면에 올라오기 전에 불릴 수 있다.
            // 한 턴 뒤에 보면 그 사이에 창이 등록될 기회가 생긴다.
            DispatchQueue.main.async {
                guard camera.phase == .capturing,
                      !camera.isRecording,
                      !isMainWindowVisible else { return }
                camera.returnToConnect()
            }
        }
    }

    // MARK: - 단계별 화면

    private var connectSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("아이폰 카메라 연결", systemImage: "iphone.rear.camera")
                .font(.headline)

            if camera.availableDevices.isEmpty {
                // 큰 창(ConnectView)과 같은 문장으로 시작한다. 두 화면이 같은 상황을
                // 다른 말로 설명하면 사용자는 다른 문제라고 오해한다.
                Text("아이폰이 보이지 않아요. 같은 Apple 계정으로 로그인했는지, 양쪽 Wi-Fi와 블루투스가 켜져 있는지 확인하세요.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(camera.availableDevices, id: \.uniqueID) { device in
                    Button {
                        camera.select(device: device)
                    } label: {
                        Label(device.localizedName, systemImage: "iphone")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                }
            }

            footer
        }
    }

    private var captureSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Color.black
                PreviewLayerView(session: camera.session, isMirrored: camera.isMirrored)
                // 팝오버에는 셔터 소리도 저장물 안내도 없다. 큰 창과 같은 번쩍임으로
                // 사진이 찍혔다는 사실을 알린다(CaptureView의 FlashOverlay 재사용).
                FlashOverlay(trigger: camera.flashPulse)
            }
            .frame(width: previewWidth, height: previewHeight)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 8) {
                Button {
                    camera.capturePhoto()
                } label: {
                    Image(systemName: "camera.fill")
                }
                .buttonStyle(.glassProminent)
                .help("사진 촬영")

                Button {
                    if camera.isRecording { camera.stopRecording() }
                    else { camera.startRecording() }
                } label: {
                    Image(systemName: camera.isRecording ? "stop.fill" : "record.circle")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.glass)
                .help(camera.isRecording ? "녹화 정지" : "녹화 시작")

                if camera.isRecording {
                    Text(camera.recordingClock)
                        .monospacedDigit()
                        .foregroundStyle(.red)
                }

                Spacer(minLength: 0)

                Button("큰 창 열기") { openMainWindow() }
                    .buttonStyle(.glass)
                    .help("해상도·좌우반전·전체화면은 큰 창에서")

                quitButton
            }
        }
    }

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("카메라 권한이 필요합니다", systemImage: "video.slash")
                .font(.headline)
            Text("시스템 설정 → 개인정보 보호 및 보안 → 카메라에서 WideCam을 허용해주세요.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                // URL은 PermissionDeniedView에 한 곳만 둔다(두 화면이 다른 설정 패널을
                // 열면 안 된다).
                Button("시스템 설정 열기") {
                    NSWorkspace.shared.open(PermissionDeniedView.settingsURL)
                }
                .buttonStyle(.glassProminent)
                Spacer(minLength: 0)
                quitButton
            }
        }
    }

    /// 캡처 화면은 컨트롤 줄에 종료가 들어가므로, 나머지 단계에서만 쓰는 하단 줄이다.
    private var footer: some View {
        HStack {
            Spacer(minLength: 0)
            quitButton
        }
    }

    private var quitButton: some View {
        // 녹화 중 종료를 막는다. AVCaptureMovieFileOutput은 정지 후 비동기로 파일을
        // 마무리하므로, 그 전에 프로세스가 죽으면 moov 원자가 없는 재생 불가 파일이
        // 남는다. stopRecording() 뒤에 terminate()를 바로 부르는 것도 같은 결과다
        // (마무리 콜백을 기다리지 않는다). 옆의 정지 버튼으로 먼저 끝내게 한다.
        Button("종료") { NSApp.terminate(nil) }
            .buttonStyle(.glass)
            .disabled(camera.isRecording)
            .help(camera.isRecording ? "녹화를 정지한 뒤에 종료할 수 있습니다" : "WideCam 종료")
    }

    // MARK: - 큰 창

    private func openMainWindow() {
        openWindow(id: "main")
        // 보조 앱(LSUIElement)은 창을 열어도 스스로 앞으로 나오지 않는다. 명시 활성화가
        // 없으면 새 창이 다른 앱 뒤에 가려진 채 열린다. macOS 14의 activate()가 있지만
        // 이 SDK에서 activate(ignoringOtherApps:)는 아직 경고 없이 쓸 수 있고
        // (API_TO_BE_DEPRECATED), 다른 앱이 활성인 상태에서 더 확실하게 올라온다.
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 큰 창이 지금 화면에 있는지. SwiftUI `Window(id: "main")`이 런타임에 어떤
    /// NSWindow.identifier를 갖는지는 실행 없이 확인할 수 없으므로(이 작업은 실행
    /// 금지) identifier에 의존하지 않는다. 대신 "제목줄이 있는 일반 창이 보이는가"로
    /// 판단한다 — 메뉴바 팝오버와 상태 아이템 창은 NSPanel이고 제목줄이 없으므로
    /// 이 조건에서 빠진다. 판정이 틀리는 쪽의 비용은 비대칭이다: 참을 거짓으로 보면
    /// 큰 창이 연결 화면으로 되돌아갈 뿐이고(기기를 다시 고르면 복구된다), 거짓을
    /// 참으로 보면 카메라가 계속 점유된다.
    private var isMainWindowVisible: Bool {
        NSApp.windows.contains { window in
            window.isVisible
                && !(window is NSPanel)
                && window.styleMask.contains(.titled)
        }
    }
}
