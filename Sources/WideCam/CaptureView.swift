import SwiftUI

struct CaptureView: View {
    @ObservedObject var camera: CameraManager

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            PreviewLayerView(session: camera.session, isMirrored: camera.isMirrored)
                .ignoresSafeArea()

            FlashOverlay(trigger: camera.flashPulse)

            toolbar
                .padding(.bottom, 24)
        }
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
            statusBadge.padding(16)
        }
    }

    private var statusBadge: some View {
        VStack(alignment: .leading, spacing: 6) {
            if camera.isCenterStageForcedOff {
                Label("센터 스테이지 해제됨", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
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
                .help("해상도·프레임레이트")

                Toggle(isOn: $camera.isMirrored) {
                    Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                .toggleStyle(.button)
                .buttonStyle(.glass)
                .help("좌우반전 (프리뷰에만 적용)")

                Button {
                    NSApp.keyWindow?.toggleFullScreen(nil)
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
