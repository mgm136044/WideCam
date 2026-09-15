import AVFoundation
import Foundation

/// AVFoundation 접점 전체를 담당한다. 뷰는 이 객체의 @Published 상태만 구독한다.
/// @Published 변경은 반드시 메인 큐에서, 세션/포맷 조작은 sessionQueue에서 수행한다.
final class CameraManager: NSObject, ObservableObject {
    enum Phase: Equatable {
        case connect
        case capturing
        case permissionDenied
    }

    @Published private(set) var phase: Phase = .connect
    @Published private(set) var availableDevices: [AVCaptureDevice] = []
    @Published private(set) var formatSpecs: [FormatSpec] = []
    @Published private(set) var activeSpec: FormatSpec?
    @Published private(set) var isCenterStageForcedOff = false
    @Published var isMirrored = false
    @Published private(set) var errorBanner: String?

    let session = AVCaptureSession()
    let sessionQueue = DispatchQueue(label: "com.mingyeongmin.WideCam.session")

    private(set) var selectedDevice: AVCaptureDevice?
    private var formatObservation: NSKeyValueObservation?
    // 아래 두 변수는 sessionQueue에서만 접근한다.
    private var targetSpec: FormatSpec?
    private var isApplyingFormat = false

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(devicesChanged),
            name: AVCaptureDevice.wasConnectedNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(devicesChanged),
            name: AVCaptureDevice.wasDisconnectedNotification, object: nil)
        refreshDevices()
    }

    // MARK: - 기기 발견

    @objc private func devicesChanged(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshDevices()
            if let current = self.selectedDevice, !self.availableDevices.contains(current) {
                self.returnToConnect()
                self.errorBanner = "아이폰 연결이 끊어졌습니다."
            }
        }
    }

    private func refreshDevices() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.continuityCamera, .external],
            mediaType: .video, position: .unspecified)
        availableDevices = discovery.devices.filter { $0.isContinuityCamera }
    }

    // MARK: - 세션 시작과 화각 강제 (설계 §4)

    func select(device: AVCaptureDevice) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            start(device: device)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.start(device: device) }
                    else { self?.phase = .permissionDenied }
                }
            }
        default:
            phase = .permissionDenied
        }
    }

    private func start(device: AVCaptureDevice) {
        selectedDevice = device
        formatSpecs = FormatPolicy.specs(fromDimensions: device.formats.map { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let maxRate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
            return (Int(dims.width), Int(dims.height), maxRate)
        })
        let initial = FormatPolicy.defaultSpec(in: formatSpecs)
        phase = .capturing

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.inputs.forEach(self.session.removeInput)
            if let input = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(input) {
                self.session.addInput(input)
            }
            self.session.commitConfiguration()
            self.session.startRunning()

            // 스파이크 실측: startRunning()이 activeFormat을 1080p로 되돌린다.
            // 반드시 시작 "후"에 포맷을 강제해야 1920x1440이 유지된다.
            if let initial { self.apply(spec: initial, to: device) }
            self.forceCenterStageOff()
            self.observeFormatReversion(of: device)
        }
    }

    func apply(spec: FormatSpec) {
        guard let device = selectedDevice else { return }
        sessionQueue.async { [weak self] in self?.apply(spec: spec, to: device) }
    }

    /// sessionQueue에서만 호출한다.
    private func apply(spec: FormatSpec, to device: AVCaptureDevice) {
        guard let format = device.formats.first(where: { candidate in
            let dims = CMVideoFormatDescriptionGetDimensions(candidate.formatDescription)
            let maxRate = candidate.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            return Int(dims.width) == spec.width && Int(dims.height) == spec.height
                && maxRate == spec.maxFrameRate
        }) else { return }
        do {
            isApplyingFormat = true
            defer { isApplyingFormat = false }
            try device.lockForConfiguration()
            device.activeFormat = format
            device.unlockForConfiguration()
            targetSpec = spec
            DispatchQueue.main.async { self.activeSpec = spec }
        } catch {
            DispatchQueue.main.async {
                self.errorBanner = "포맷 설정 실패: \(error.localizedDescription)"
            }
        }
    }

    private func forceCenterStageOff() {
        AVCaptureDevice.centerStageControlMode = .app
        AVCaptureDevice.isCenterStageEnabled = false
        let forcedOff = !AVCaptureDevice.isCenterStageEnabled
        DispatchQueue.main.async { self.isCenterStageForcedOff = forcedOff }
    }

    /// 외부 요인(OS·제어 센터)이 포맷을 되돌리면 즉시 재강제한다. 조용한 실패 금지(설계 §9).
    private func observeFormatReversion(of device: AVCaptureDevice) {
        formatObservation = device.observe(\.activeFormat) { [weak self] device, _ in
            guard let self else { return }
            self.sessionQueue.async {
                guard !self.isApplyingFormat, let target = self.targetSpec else { return }
                let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                if Int(dims.width) != target.width || Int(dims.height) != target.height {
                    self.apply(spec: target, to: device)
                }
            }
        }
    }

    // MARK: - 종료

    func returnToConnect() {
        formatObservation = nil
        selectedDevice = nil
        activeSpec = nil
        phase = .connect
        sessionQueue.async { [session] in
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            session.outputs.forEach(session.removeOutput)
            session.commitConfiguration()
            if session.isRunning { session.stopRunning() }
        }
    }

    func clearError() {
        errorBanner = nil
    }
}
