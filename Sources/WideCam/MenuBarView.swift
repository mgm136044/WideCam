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
    /// 큰 창의 NSWindow. 창이 세션을 쓰는 중인지 추정하지 않고 직접 본다.
    let mainWindowHolder: WindowHolder
    /// 이 팝오버가 열려 있다는 사실을 큰 창 쪽에 알리는 공유 플래그.
    let popoverPresence: PopoverPresence
    /// Wi-Fi 전원 상태. 팝오버가 열려 있는 동안 켜고 꺼도 안내가 따라온다.
    @ObservedObject private var wifi = WiFiMonitor.shared
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
            popoverPresence.isOpen = true
            // 팝오버를 여는 행동 자체를 "카메라 켜기"로 본다. 메뉴바 앱에서 아이콘을
            // 누른 뒤 기기를 한 번 더 고르게 하면 클릭이 두 번이 된다.
            if camera.phase == .connect, let device = camera.availableDevices.first {
                camera.select(device: device)
            }
        }
        .onDisappear {
            popoverPresence.isOpen = false
            // 팝오버를 닫으면 카메라를 놓아(녹색 점 소등) 쓰지 않는 동안 아이폰
            // 카메라를 점유하지 않는다. 단 녹화 중이거나 큰 창이 세션을 쓰는 중이면
            // 유지한다.
            //
            // 판정을 다음 메인 큐 턴으로 미루는 이유: "큰 창 열기"는 창을 열면서
            // 팝오버를 닫으므로 onDisappear가 창이 화면에 올라오기 전에 불릴 수 있다.
            // 한 턴 뒤에 보면 그 사이에 창이 등록될 기회가 생긴다.
            DispatchQueue.main.async {
                // 창을 직접 본다. 예전에는 "제목줄 있는 NSPanel 아닌 보이는 창"으로
                // 추정했는데, 상태 복원으로 되살아난 창이나 앱의 다른 제목줄 창까지
                // 걸려 판정이 영구히 참으로 굳을 수 있었다.
                guard camera.phase == .capturing,
                      !camera.isRecording,
                      mainWindowHolder.window?.isVisible != true else { return }
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
                // 큰 창(ConnectView)과 같은 문장을 같은 순서로 쓴다. 두 화면이 같은
                // 상황을 다른 말로 설명하면 사용자는 다른 문제라고 오해한다.
                VStack(alignment: .leading, spacing: 6) {
                    // Wi-Fi 꺼짐은 추측이 아니라 실측이고 사용자가 바로 고칠 수 있는
                    // 원인이다. 그래서 헤드라인보다 위에, 눈에 띄는 색으로 둔다.
                    if wifi.isOff {
                        Label(WiFiMonitor.offMessage, systemImage: "wifi.slash")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    Text("아이폰이 보이지 않아요. 다음을 확인하세요.")
                        .font(.callout)
                    Label("맥과 아이폰이 같은 Apple 계정으로 로그인되어 있어야 합니다",
                          systemImage: "person.circle")
                    Label("양쪽 모두 Wi-Fi와 블루투스가 켜져 있어야 합니다", systemImage: "wifi")
                    Label("USB 케이블로 연결하면 가장 안정적입니다", systemImage: "cable.connector")
                }
                .font(.caption)
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
                PreviewLayerView(camera: camera, isMirrored: camera.isMirrored)
                // 팝오버에는 셔터 소리도 저장물 안내도 없다. 큰 창과 같은 번쩍임으로
                // 사진이 찍혔다는 사실을 알린다(CaptureView의 FlashOverlay 재사용).
                FlashOverlay(trigger: camera.flashPulse)
            }
            .frame(width: previewWidth, height: previewHeight)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // 해제 실패를 숨기면 사용자는 좁아진 화각의 원인을 알 수 없다(설계 §9).
            // 큰 창의 statusBadge와 같은 사실을 같은 문장으로 말한다.
            if camera.centerStageState == .failed {
                Label("센터 스테이지 해제 실패 — 화각이 좁을 수 있습니다",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let spec = camera.activeSpec {
                Text(spec.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

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
}

/// 팝오버가 열려 있는지를 큰 창 쪽과 나눠 갖는 상자. 큰 창이 닫힐 때 카메라를 놓아도
/// 되는지 판단하는 데만 쓴다. 이 값으로 뷰를 다시 그릴 일이 없고(판정 시점에 읽기만
/// 한다) @Published를 달면 팝오버가 열고 닫힐 때마다 큰 창이 불필요하게 갱신되므로
/// 일부러 평범한 프로퍼티로 둔다. 메인 큐에서만 읽고 쓴다.
final class PopoverPresence: ObservableObject {
    var isOpen = false
}
