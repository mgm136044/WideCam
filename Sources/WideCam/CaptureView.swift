import SwiftUI

struct CaptureView: View {
    @ObservedObject var camera: CameraManager
    /// 전체화면 버튼이 참조할 자기 창. NSApp.keyWindow는 클릭 시점에 nil일 수 있어
    /// 창을 직접 붙잡아 둔다(@State 미사용 — 이 머신에서 매크로가 컴파일되지 않는다).
    @StateObject private var windowHolder = WindowHolder()
    /// 전체화면에서만 동작하는 UI 자동 숨김 상태. @State가 이 머신에서 컴파일되지
    /// 않으므로 FlashOverlay와 같은 방식(@StateObject + ObservableObject)으로 담는다.
    @StateObject private var visibility: ControlsVisibility

    init(camera: CameraManager) {
        _camera = ObservedObject(wrappedValue: camera)
        // 녹화 여부를 플래그로 복사하지 않고 판단 시점(타이머 발화)에 직접 읽는다.
        // 복사해 두면 동기화를 놓치는 경로가 생긴다 — 팝오버에서 녹화를 시작한 뒤
        // 큰 창을 열면 이 뷰는 "이미 녹화 중"인 상태로 나타나고, 그때는 값이 바뀌지
        // 않으므로 onChange가 불리지 않는다. CameraManager.isPresentationReady와 같은
        // 주입 방식이다.
        _visibility = StateObject(
            wrappedValue: ControlsVisibility(isRecording: { camera.isRecording }))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            PreviewLayerView(camera: camera, isMirrored: camera.isMirrored)
                .ignoresSafeArea()

            FlashOverlay(trigger: camera.flashPulse)

            toolbar
                .padding(.bottom, 24)
                .opacity(visibility.controlsHidden ? 0 : 1)
                // 투명해진 툴바가 클릭을 가로채면 프리뷰 위에 보이지 않는 벽이 생긴다.
                .allowsHitTesting(!visibility.controlsHidden)
                .animation(.easeInOut(duration: 0.3), value: visibility.controlsHidden)
        }
        // 마우스가 움직일 때마다 컨트롤을 다시 보이고 타이머를 처음부터 돌린다.
        // 정지 상태에서는 발화하지 않으므로(이동 이벤트 기반) 가만히 두면 숨는다.
        .onContinuousHover(coordinateSpace: .local) { _ in
            visibility.poke()
        }
        // 전체화면 진입·이탈은 알림으로 안다. styleMask를 poke 시점에 읽는 방식은
        // "전체화면에 들어갔지만 마우스를 움직이지 않은" 경우에 타이머를 걸 계기가
        // 없어서 첫 숨김이 일어나지 않는다.
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didEnterFullScreenNotification)) { note in
            if isMyWindow(note) { visibility.enterFullscreen() }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didExitFullScreenNotification)) { note in
            if isMyWindow(note) { visibility.exitFullscreen() }
        }
        // 녹화가 시작되면 이미 숨어 있던 컨트롤을 다시 보인다(숨은 채로 시작하면
        // 녹화 중이라는 사실이 화면에서 사라진다). 녹화가 끝나면 같은 poke가
        // 타이머를 다시 걸어 자동 숨김을 되살린다.
        .onChange(of: camera.isRecording) { _, _ in
            visibility.poke()
        }
        // 창 참조를 얻고 .fullScreenPrimary를 켜기 위한 크기 0의 숨은 브리지.
        // 레이아웃과 히트 테스트에 영향을 주지 않는다.
        .background(WindowAccessor(holder: windowHolder).frame(width: 0, height: 0))
        .overlay(alignment: .top) {
            if let message = camera.errorBanner {
                HStack(spacing: 12) {
                    Text(message).foregroundStyle(.red)
                    Button("닫기") { camera.clearError() }
                        .buttonStyle(.glass)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .glassEffect(in: Capsule())
                .padding(.top, 16)
            }
        }
        .overlay(alignment: .topLeading) {
            statusBadge
                .padding(16)
                .opacity(visibility.controlsHidden ? 0 : 1)
                .allowsHitTesting(!visibility.controlsHidden)
                .animation(.easeInOut(duration: 0.3), value: visibility.controlsHidden)
        }
    }

    /// 알림이 내 창의 것인지. 창 참조를 아직 못 잡은 경우(이론상)에는 받아들인다 —
    /// 이 앱에서 전체화면이 될 수 있는 창은 큰 창 하나뿐이다.
    private func isMyWindow(_ notification: Notification) -> Bool {
        guard let mine = windowHolder.window else { return true }
        return (notification.object as? NSWindow) === mine
    }

    private var statusBadge: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch camera.centerStageState {
            case .forcedOff:
                Label("센터 스테이지 해제됨", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            case .failed:
                // 해제에 실패한 사실을 숨기면 사용자는 좁아진 화각의 원인을 알 수 없다.
                Label("센터 스테이지 해제 실패 — 화각이 좁을 수 있습니다",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            case .unknown:
                EmptyView()
            }
            if let spec = camera.activeSpec {
                Text(spec.label).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .glassEffect(in: RoundedRectangle(cornerRadius: 14))
    }

    private var toolbar: some View {
        GlassEffectContainer {
            HStack(spacing: 18) {
                Button {
                    camera.returnToConnect()
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .buttonStyle(.glass)
                .help("연결 화면으로")

                Button {
                    camera.capturePhoto()
                } label: {
                    Image(systemName: "camera.fill")
                        .font(.title3)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .help("사진 촬영")

                Button {
                    if camera.isRecording { camera.stopRecording() }
                    else { camera.startRecording() }
                } label: {
                    Image(systemName: camera.isRecording ? "stop.fill" : "record.circle")
                        .font(.title3)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .help(camera.isRecording ? "녹화 정지" : "녹화 시작")

                if camera.isRecording {
                    Text(camera.recordingClock)
                        .monospacedDigit()
                        .foregroundStyle(.red)
                }

                Picker("포맷", selection: Binding(
                    get: { camera.activeSpec },
                    set: { if let spec = $0 { camera.apply(spec: spec) } }
                )) {
                    ForEach(camera.formatSpecs) { spec in
                        Text(spec.label).tag(Optional(spec))
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                // 녹화 중 activeFormat을 바꾸면 기록 중인 파일의 해상도가 중간에
                // 갈리거나 녹화가 끊긴다. 녹화 중에는 선택 자체를 막는다.
                .disabled(camera.isRecording)
                .help("해상도·프레임레이트")

                Toggle(isOn: $camera.isMirrored) {
                    Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                .toggleStyle(.button)
                .buttonStyle(.glass)
                .help("좌우반전 (프리뷰에만 적용)")

                Button {
                    // keyWindow가 nil인 순간(패널·메뉴가 키를 가진 경우 등)에도
                    // 동작해야 하므로 자기 창 → keyWindow → 보이는 첫 창 순으로 폴백한다.
                    let resolved = windowHolder.window
                        ?? NSApp.keyWindow
                        ?? NSApp.windows.first { $0.isVisible }
                    if let window = resolved {
                        // .fullScreenNone이 켜져 있으면 .fullScreenPrimary를 넣어도
                        // 전체화면이 거부된다. 상충 플래그를 먼저 뺀다.
                        window.collectionBehavior.remove(.fullScreenNone)
                        window.collectionBehavior.insert(.fullScreenPrimary)
                        window.toggleFullScreen(nil)
                    } else {
                        // 창을 하나도 못 잡으면 표준 경로(메뉴의 전체화면 명령)에 맡긴다.
                        NSApp.sendAction(#selector(NSWindow.toggleFullScreen(_:)), to: nil, from: nil)
                    }
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.glass)
                .help("전체화면")

                if camera.lastSavedURL != nil {
                    Button {
                        camera.revealLastSaved()
                    } label: {
                        Image(systemName: "photo.on.rectangle")
                    }
                    .buttonStyle(.glass)
                    .help("마지막 저장물 Finder에서 보기")
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .glassEffect(in: Capsule())
        }
        // 툴바를 누르는 것도 "사용 중"이다. 포인터를 고정한 채 셔터만 연타하면
        // 마우스 이동 이벤트가 없어 2.5초 뒤 툴바가 숨어버리고, 그때부터
        // allowsHitTesting(false) 때문에 클릭이 먹지 않는다.
        //
        // simultaneousGesture는 버튼 자신의 제스처와 나란히 인식되므로 버튼 동작을
        // 가로채거나 늦추지 않는다(버튼마다 poke()를 심는 대신 한 곳에서 처리한다).
        .simultaneousGesture(TapGesture().onEnded { visibility.poke() })
    }
}

/// 전체화면에서 가만히 두면 툴바와 상태 배지를 감추는 상태 기계.
///
/// 전체화면일 때만 동작한다. 창 모드에서는 타이머를 걸지 않고 컨트롤을 항상 보인다 —
/// 창 모드의 툴바는 화면을 가리는 것이 아니라 창의 일부이기 때문이다.
/// 오류 배너는 이 숨김에서 제외한다(설계 §9: 오류는 사라지면 안 된다).
///
/// 모든 접근은 메인 큐에서 일어난다(뷰 이벤트와 메인 런루프 타이머).
private final class ControlsVisibility: ObservableObject {
    @Published private(set) var controlsHidden = false

    /// 마지막 마우스 움직임 뒤 이만큼 지나면 감춘다.
    private let idleDelay: TimeInterval = 2.5
    /// 지금 녹화 중인지 묻는 훅. 값을 복사해 두지 않고 숨기기 직전에 읽는다.
    private let isRecording: () -> Bool
    private var isFullscreen = false
    private var timer: Timer?

    init(isRecording: @escaping () -> Bool) {
        self.isRecording = isRecording
    }

    /// 마우스가 움직였다. 컨트롤을 보이고 유예 시간을 처음부터 다시 센다.
    func poke() {
        if controlsHidden { controlsHidden = false }
        armTimer()
    }

    func enterFullscreen() {
        isFullscreen = true
        controlsHidden = false
        // 전체화면에 들어간 뒤 마우스를 한 번도 움직이지 않아도 숨어야 하므로
        // 여기서 타이머를 건다.
        armTimer()
    }

    func exitFullscreen() {
        isFullscreen = false
        timer?.invalidate()
        timer = nil
        controlsHidden = false
    }

    private func armTimer() {
        timer?.invalidate()
        timer = nil
        guard isFullscreen else { return }
        // 기본 런루프 모드의 타이머는 메뉴 트래킹 중에 억제된다. 녹화 경과 시간과
        // 같은 이유로 공통 모드에 등록한다. 한 번만 발화하며 self를 약하게 잡으므로
        // 뷰가 사라진 뒤 남은 발화는 아무 일도 하지 않는다.
        let timer = Timer(timeInterval: idleDelay, repeats: false) { [weak self] _ in
            self?.hide()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func hide() {
        // 타이머가 걸린 뒤 전체화면에서 나갔다면 숨기지 않는다.
        guard isFullscreen else { return }
        // 전체화면 녹화 중에 빨간 표시와 경과 시간까지 숨으면 녹화하고 있다는 사실
        // 자체가 화면에서 사라진다. 상태를 숨기지 않는다는 설계 §9의 취지에 어긋나므로
        // 녹화 중에는 감추지 않는다.
        guard !isRecording() else { return }
        controlsHidden = true
        // 동영상 플레이어 관례: 컨트롤이 사라지면 포인터도 사라진다. 다음 마우스
        // 움직임에서 AppKit이 되살리고, 같은 움직임이 onContinuousHover로 들어와
        // 컨트롤도 함께 돌아온다.
        NSCursor.setHiddenUntilMouseMoves(true)
    }
}

/// 셔터를 누르면 화면이 짧게 하얗게 번쩍인다 (소리 없음).
///
/// 이 SDK의 @State는 매크로(SwiftUIMacros.StateMacro)로 구현돼 있고 CLT에는 해당
/// 플러그인 dylib이 없어 컴파일되지 않는다. 같은 일을 하는 비매크로 프로퍼티 래퍼
/// @StateObject로 지역 상태를 담는다(Task 4에서 이미 검증된 방식).
struct FlashOverlay: View {
    let trigger: Int
    @StateObject private var state = FlashState()

    var body: some View {
        Color.white.opacity(state.opacity)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .onChange(of: trigger) { _, _ in state.pulse() }
    }
}

/// FlashOverlay의 지역 상태. 메인 큐에서만 변경한다.
private final class FlashState: ObservableObject {
    @Published private(set) var opacity = 0.0

    func pulse() {
        // 0.8 대입과 0으로의 애니메이션을 한 업데이트 사이클에 같이 넣으면, 직전에
        // 렌더된 값(0)에서 0으로 애니메이션하는 셈이 되어 아무것도 보이지 않는다.
        // 흰 화면을 먼저 한 번 그린 뒤 다음 턴에 페이드아웃시킨다.
        opacity = 0.8
        DispatchQueue.main.async { [weak self] in
            withAnimation(.easeOut(duration: 0.35)) { self?.opacity = 0 }
        }
    }
}
