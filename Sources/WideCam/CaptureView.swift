import SwiftUI

struct CaptureView: View {
    @ObservedObject var camera: CameraManager

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            PreviewLayerView(session: camera.session, isMirrored: camera.isMirrored)
                .ignoresSafeArea()

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
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .glassEffect(in: Capsule())
        }
    }
}
