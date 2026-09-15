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
        // 순회와 겹치면 프로세스가 죽는다(3회차 스모크 실측). 첫 프레임부터 좌우반전이
        // 맞도록 현재 값을 같이 넘긴다 — 부착이 비동기라서 아래 updateNSView가
        // 첫 렌더에서는 연결을 못 볼 수 있다.
        camera.attachPreview(view.previewLayer, mirrored: isMirrored)
        return view
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {
        // 최초 적용은 attachPreview가 맡는다(부착이 비동기라 여기서는 첫 렌더에 연결이
        // 없을 수 있다). 이 경로는 그 뒤의 토글 변경을 반영한다 — isMirrored가 바뀌면
        // 렌더가 보장되고 그때는 연결이 이미 존재한다.
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
