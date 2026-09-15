import AVFoundation
import SwiftUI

/// AVCaptureVideoPreviewLayer를 SwiftUI에 올린다. 레터박스(resizeAspect)로 화각 전체 보존.
///
/// 세션을 값으로 받지 않고 CameraManager를 받는다. 레이어에 세션을 붙이고 떼는 일이
/// 세션 변형이어서 sessionQueue를 거쳐야 하고(CameraManager.attachPreview 주석 참고),
/// 그 큐를 아는 것은 매니저뿐이다.
struct PreviewLayerView: NSViewRepresentable {
    let camera: CameraManager
    let isMirrored: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(camera: camera)
    }

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        context.coordinator.view = view
        // 메인에서 layer.session에 대입하지 않는다. 그 대입이 startRunning()의 연결
        // 순회와 겹치면 프로세스가 죽는다(3회차 스모크 실측).
        camera.attachPreview(view.previewLayer)
        return view
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {
        // 부착이 sessionQueue를 거치므로 첫 update 시점에는 connection이 아직 없을 수
        // 있다. 그때는 아무것도 하지 않고, 연결이 생긴 뒤의 다음 update에서 적용된다.
        if let connection = nsView.previewLayer.connection {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = isMirrored
        }
    }

    /// 뷰가 사라질 때 레이어를 세션에서 뗀다. 메인에서 떼면 teardown(returnToConnect의
    /// stopRunning)과 겹칠 수 있으므로 이 경로도 sessionQueue로 보낸다.
    static func dismantleNSView(_ nsView: PreviewNSView, coordinator: Coordinator) {
        coordinator.camera.detachPreview(nsView.previewLayer)
    }

    final class Coordinator {
        let camera: CameraManager
        /// dismantleNSView가 불리지 않는 teardown 경로가 있어도 레이어가 세션에 붙은
        /// 채로 남지 않게 하는 안전망. 이미 떼인 뒤 한 번 더 nil을 대입해도 무해하다.
        weak var view: PreviewNSView?

        init(camera: CameraManager) {
            self.camera = camera
        }

        deinit {
            if let view { camera.detachPreview(view.previewLayer) }
        }
    }
}

final class PreviewNSView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        previewLayer.videoGravity = .resizeAspect
        layer = previewLayer
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("사용하지 않음") }
}
