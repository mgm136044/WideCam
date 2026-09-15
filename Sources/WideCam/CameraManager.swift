import AppKit
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

    /// 센터 스테이지 해제 결과. "아직 시도하지 않음"과 "시도했지만 실패"를 구분해야
    /// 화면이 의도가 아니라 실측을 말할 수 있다(설계 §9: 조용한 실패 금지).
    enum CenterStageState: Equatable {
        case unknown
        case forcedOff
        case failed
    }

    @Published private(set) var phase: Phase = .connect
    @Published private(set) var availableDevices: [AVCaptureDevice] = []
    @Published private(set) var formatSpecs: [FormatSpec] = []
    @Published private(set) var activeSpec: FormatSpec?
    @Published private(set) var centerStageState: CenterStageState = .unknown
    @Published var isMirrored = false
    @Published private(set) var errorBanner: String?
    @Published private(set) var lastSavedURL: URL?
    @Published private(set) var flashPulse = 0
    @Published private(set) var isRecording = false
    @Published private(set) var recordingSeconds = 0

    /// 경과 시간 표시값. 큰 창과 팝오버가 같은 형식을 써야 하므로 여기 한 곳에 둔다.
    /// recordingSeconds가 메인 큐에서만 바뀌므로 이 계산도 메인 큐에서만 읽는다.
    var recordingClock: String {
        String(format: "%02d:%02d", recordingSeconds / 60, recordingSeconds % 60)
    }

    /// "지금 세션을 보여줄 화면이 있는가"를 묻는 훅. 앱 조립부(WideCamApp)가 주입하고
    /// 메인 큐에서만 부른다. nil이면(주입 전·테스트) 항상 켠다. 뷰 계층을 모른 채로
    /// 물어보기만 하려고 클로저로 받는다.
    var isPresentationReady: (() -> Bool)?

    // 세션과 그 소유 큐는 매니저 밖으로 내보내지 않는다. 뷰가 session을 직접 쥐면
    // 이번 크래시(메인에서 layer.session 대입 ↔ sessionQueue의 startRunning 경합)가
    // 그대로 재발할 수 있다. 프리뷰 부착은 attachPreview/detachPreview로만 한다.
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.mingyeongmin.WideCam.session")

    private(set) var selectedDevice: AVCaptureDevice?
    // formatObservation의 소유 큐는 sessionQueue다. 등록(observeFormatReversion)과
    // 해제(returnToConnect)를 모두 sessionQueue에서 처리해 FIFO 순서를 보장한다.
    private var formatObservation: NSKeyValueObservation?
    // 아래 두 변수도 sessionQueue에서만 접근한다.
    private var targetSpec: FormatSpec?
    private var isApplyingFormat = false

    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let mediaStore = MediaStore()
    // sessionQueue에서 쓰고, 그 뒤에 도착하는 델리게이트 콜백에서만 읽는다.
    private var usesHEVCPhotos = false
    // 아래 두 변수는 메인 큐에서만 만들고 비운다(녹화 델리게이트 콜백이 메인 큐로 넘긴다).
    private var recordingTimer: Timer?
    private var recordingStartDate: Date?

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
        // 이전 기기에서 남은 배너가 새 세션의 상태로 오해되지 않게 먼저 비운다.
        errorBanner = nil
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            start(device: device)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard granted else {
                        self.phase = .permissionDenied
                        return
                    }
                    // 권한 대화상자는 팝오버를 닫아버린다. 그 상태에서 세션을 켜면
                    // 보여줄 화면 없이 카메라만 켜진 채(녹색 점) 남는다. .connect에
                    // 머물러 있으면 다음 팝오버 열기의 자동 시작이 화면과 함께 켠다.
                    guard self.isPresentationReady?() ?? true else { return }
                    self.start(device: device)
                }
            }
        default:
            phase = .permissionDenied
        }
    }

    /// 포맷 하나를 FormatSpec으로 환산한다. 목록을 만들 때와 activeFormat을 실측할 때
    /// 같은 규칙을 써야 실측값이 피커 항목과 어긋나지 않으므로 한 곳에 모았다.
    private static func spec(of format: AVCaptureDevice.Format) -> FormatSpec {
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let maxRate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
        return FormatSpec(width: Int(dims.width), height: Int(dims.height), maxFrameRate: maxRate)
    }

    private func start(device: AVCaptureDevice) {
        selectedDevice = device
        formatSpecs = FormatPolicy.specs(fromDimensions: device.formats.map { format in
            let spec = Self.spec(of: format)
            return (spec.width, spec.height, spec.maxFrameRate)
        })
        let initial = FormatPolicy.defaultSpec(in: formatSpecs)
        phase = .capturing

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.inputs.forEach(self.session.removeInput)

            // 입력 연결 실패는 조용히 넘기지 않는다(설계 §9). 입력 없는 세션을
            // startRunning()하면 프리뷰가 검은 화면으로 남고 원인을 알 수 없다.
            let input: AVCaptureDeviceInput
            do {
                input = try AVCaptureDeviceInput(device: device)
            } catch {
                self.session.commitConfiguration()
                self.failToStart("카메라 입력 연결 실패: \(error.localizedDescription)")
                return
            }
            guard self.session.canAddInput(input) else {
                self.session.commitConfiguration()
                self.failToStart("카메라 입력을 세션에 추가할 수 없습니다.")
                return
            }
            self.session.addInput(input)

            // 출력 추가 실패도 조용히 넘기지 않는다(설계 §9). 단 입력과 달리 세션을
            // 되돌리지는 않는다 — 사진 기능 없이도 프리뷰는 그대로 쓸 수 있고,
            // 셔터 크래시는 capturePhoto()의 연결 가드가 막아준다.
            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
            } else {
                DispatchQueue.main.async {
                    self.errorBanner = "사진 출력을 세션에 추가하지 못했습니다."
                }
            }

            // 영상 출력도 같은 원칙(설계 §9): 실패는 배너로 알리지만 세션은 되돌리지
            // 않는다. 녹화 크래시는 startRecording()의 연결 가드가 막아준다.
            if self.session.canAddOutput(self.movieOutput) {
                self.session.addOutput(self.movieOutput)
            } else {
                DispatchQueue.main.async {
                    self.errorBanner = "영상 출력을 세션에 추가하지 못했습니다."
                }
            }
            self.attachAudioInput(pairedWith: device)

            self.session.commitConfiguration()
            self.session.startRunning()

            // KVO를 가장 먼저 건다. 센터 스테이지 해제가 그 자체로 activeFormat을
            // 건드릴 수 있어서, 관찰자가 그보다 늦게 붙으면 그 변경을 놓친다.
            // 이 시점에는 targetSpec이 아직 nil이라 핸들러가 즉시 반환하므로
            // 초기 포맷 적용 전에 걸어두어도 안전하다.
            self.observeFormatReversion(of: device)
            self.forceCenterStageOff()

            // 스파이크 실측: startRunning()이 activeFormat을 1080p로 되돌린다.
            // 반드시 시작 "후"에 포맷을 강제해야 1920x1440이 유지된다.
            if let initial { self.apply(spec: initial, to: device) }

            // 코덱 설정은 연결이 만들어진 뒤(= startRunning 이후)에만 가능하다.
            // 계획서의 availableVideoCodecTypes 사전 확인은 이 SDK에서 쓸 수 없다
            // (API_UNAVAILABLE(macos), 대체 후보인 supportedOutputSettingsKeys-
            // ForConnection:도 동일). macOS 26이 도는 기기는 모두 HEVC 하드웨어
            // 인코딩을 지원하고, 설정이 받아들여지지 않아도 파일 자체는 정상
            // 기록되므로 조건 없이 지정한다.
            if let connection = self.movieOutput.connection(with: .video) {
                self.movieOutput.setOutputSettings(
                    [AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
            }
        }
    }

    // MARK: - 프리뷰 레이어 부착

    /// 프리뷰 레이어의 세션 부착도 "세션 변형"이다. 메인 큐에서 `layer.session = ...`을
    /// 대입하면 sessionQueue의 `startRunning()`이 세션의 연결 컬렉션을 순회하는 중에
    /// 그 컬렉션이 바뀌어 NSGenericException("Collection was mutated while being
    /// enumerated")으로 프로세스가 죽는다 — 3회차 스모크에서 실측했다.
    ///
    /// start()는 sessionQueue 블록을 넣기 "전에" 메인에서 phase를 .capturing으로 바꾸므로,
    /// SwiftUI가 프리뷰 뷰를 만들어 부착하는 시점과 startRunning()이 정확히 겹친다.
    /// 메뉴바 구조에서 프리뷰 표면이 둘(팝오버·큰 창)로 늘어 그 창이 더 넓어졌다.
    /// 그래서 세션을 만지는 모든 경로를 sessionQueue 하나로 모은다(FIFO 덕에 부착은
    /// 항상 startRunning() 뒤, 분리는 항상 teardown 뒤로 줄을 선다).
    func attachPreview(_ layer: AVCaptureVideoPreviewLayer) {
        sessionQueue.async { [session] in layer.session = session }
    }

    /// 분리도 같은 이유로 sessionQueue에서 한다. 메인에서 떼면 returnToConnect()의
    /// removeInput/removeOutput·stopRunning과 겹칠 수 있다.
    func detachPreview(_ layer: AVCaptureVideoPreviewLayer) {
        sessionQueue.async { layer.session = nil }
    }

    /// 세션 시작에 실패했을 때 연결 화면으로 되돌리고 원인을 배너로 알린다(설계 §9).
    private func failToStart(_ message: String) {
        DispatchQueue.main.async {
            self.returnToConnect()
            self.errorBanner = message
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
        }) else {
            // 일치 포맷이 없으면 activeSpec을 그대로 두면 거짓 상태가 된다(설계 §9).
            DispatchQueue.main.async {
                self.errorBanner = "요청한 포맷을 기기가 제공하지 않습니다: \(spec.label)"
            }
            return
        }
        do {
            isApplyingFormat = true
            defer { isApplyingFormat = false }
            try device.lockForConfiguration()
            device.activeFormat = format
            device.unlockForConfiguration()
            targetSpec = spec
            // 요청값이 아니라 실측값을 올린다. 기기가 요청을 그대로 받아들이지 않아도
            // 화면은 항상 실제 활성 포맷을 말해야 한다(설계 §9).
            let observed = Self.spec(of: device.activeFormat)
            DispatchQueue.main.async { self.activeSpec = observed }
        } catch {
            DispatchQueue.main.async {
                self.errorBanner = "포맷 설정 실패: \(error.localizedDescription)"
            }
        }
    }

    private func forceCenterStageOff() {
        AVCaptureDevice.centerStageControlMode = .app
        AVCaptureDevice.isCenterStageEnabled = false
        // 대입 결과를 되읽어 확인한다. 제어권을 못 가져오면 대입이 조용히 무시될 수
        // 있고, 그때 "해제됨"이라고 표시하면 좁은 화각의 원인을 숨기게 된다.
        let state: CenterStageState = AVCaptureDevice.isCenterStageEnabled ? .failed : .forcedOff
        DispatchQueue.main.async { self.centerStageState = state }
    }

    /// 외부 요인(OS·제어 센터)이 포맷을 되돌리면 즉시 재강제한다. 조용한 실패 금지(설계 §9).
    private func observeFormatReversion(of device: AVCaptureDevice) {
        formatObservation = device.observe(\.activeFormat) { [weak self] device, _ in
            guard let self else { return }
            self.sessionQueue.async {
                guard !self.isApplyingFormat, let target = self.targetSpec else { return }
                let observed = Self.spec(of: device.activeFormat)
                // 되돌려졌든 아니든 표시 값은 실측으로 갱신한다. 재강제가 뒤따르면
                // 그쪽 실측값이 메인 큐에서 이 값 다음에 올라가므로 최종 값은 교정값이다.
                DispatchQueue.main.async { self.activeSpec = observed }
                if observed.width != target.width || observed.height != target.height {
                    self.apply(spec: target, to: device)
                }
            }
        }
    }

    // MARK: - 사진 촬영

    func capturePhoto() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            // 활성·사용 가능한 비디오 연결이 없거나 세션이 멈춘 상태에서 capturePhoto()를
            // 호출하면 "No active and enabled video connection" NSException이 난다. Swift에서
            // 잡을 수 없으므로 연결의 존재만이 아니라 활성·사용 가능 여부와 세션 실행 여부까지
            // 본다. 뒤로가기 직후 도착한 탭, 그리고 기기가 물리적으로 빠졌지만 연결 끊김
            // 알림이 아직 도착하지 않아 연결 객체만 남은 경우가 여기서 걸린다.
            guard let connection = self.photoOutput.connection(with: .video),
                  connection.isActive, connection.isEnabled, self.session.isRunning else {
                DispatchQueue.main.async {
                    self.errorBanner = "카메라가 연결되어 있지 않아 촬영할 수 없습니다."
                }
                return
            }
            let settings: AVCapturePhotoSettings
            if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
                self.usesHEVCPhotos = true
            } else {
                settings = AVCapturePhotoSettings()
                self.usesHEVCPhotos = false
            }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    // MARK: - 영상 녹화

    private static let micDeniedMessage =
        "마이크 권한이 없어 소리 없이 녹화됩니다 — 시스템 설정 → 개인정보 보호 및 보안 → 마이크에서 허용해주세요."

    /// 마이크 권한을 먼저 가른다. 권한이 없는데 그냥 붙이면 입력은 추가되지만 무음으로
    /// 기록되고, 사용자는 "마이크를 찾지 못했다"는 엉뚱한 설명만 보게 된다(설계 §9).
    /// sessionQueue에서, 세션 구성(beginConfiguration) 중에만 호출한다.
    private func attachAudioInput(pairedWith camera: AVCaptureDevice) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            addAudioInput(pairedWith: camera)
        case .notDetermined:
            // 권한 대화상자는 비동기다. 지금 열려 있는 구성 트랜잭션 안에서 기다릴 수
            // 없으므로, 허용되면 별도 트랜잭션으로 마이크만 뒤늦게 붙인다.
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard let self else { return }
                guard granted else {
                    DispatchQueue.main.async { self.errorBanner = Self.micDeniedMessage }
                    return
                }
                self.sessionQueue.async {
                    // 그 사이 뒤로가기나 연결 끊김으로 이 카메라가 세션에서 빠졌으면
                    // 붙이지 않는다. 세션 상태는 소유 큐인 sessionQueue에서 읽는다.
                    guard self.session.inputs.contains(where: {
                        ($0 as? AVCaptureDeviceInput)?.device.uniqueID == camera.uniqueID
                    }) else { return }
                    self.session.beginConfiguration()
                    self.addAudioInput(pairedWith: camera)
                    self.session.commitConfiguration()
                }
            }
        default:
            DispatchQueue.main.async { self.errorBanner = Self.micDeniedMessage }
        }
    }

    /// 아이폰(연속성 카메라)의 마이크를 찾아 연결한다. uniqueID 앞자리가 카메라와 같으면
    /// 같은 기기의 마이크다. 없으면 시스템 기본 마이크로 대체한다.
    /// sessionQueue에서, 세션 구성(beginConfiguration) 중에만 호출한다.
    private func addAudioInput(pairedWith camera: AVCaptureDevice) {
        let mics = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
        let prefix = String(camera.uniqueID.prefix(8))
        let mic = mics.first { $0.uniqueID.hasPrefix(prefix) }
            ?? AVCaptureDevice.default(for: .audio)
        guard let mic,
              let input = try? AVCaptureDeviceInput(device: mic),
              session.canAddInput(input) else {
            DispatchQueue.main.async { self.errorBanner = "마이크를 찾지 못해 소리 없이 녹화됩니다." }
            return
        }
        session.addInput(input)
    }

    func startRecording() {
        sessionQueue.async { [weak self] in
            guard let self, !self.movieOutput.isRecording else { return }
            // capturePhoto()와 같은 이유의 가드다. 활성·사용 가능한 비디오 연결이 없거나
            // 세션이 멈춘 상태에서 startRecording(to:)을 호출하면 Swift에서 잡을 수 없는
            // NSException("no active and enabled connection")이 난다.
            guard let connection = self.movieOutput.connection(with: .video),
                  connection.isActive, connection.isEnabled, self.session.isRunning else {
                DispatchQueue.main.async {
                    self.errorBanner = "카메라가 연결되어 있지 않아 녹화할 수 없습니다."
                }
                return
            }
            do {
                try self.mediaStore.ensureDirectoryExists()
            } catch {
                DispatchQueue.main.async {
                    self.errorBanner = "저장 폴더 생성 실패: \(error.localizedDescription)"
                }
                return
            }
            self.movieOutput.startRecording(to: self.mediaStore.movieURL(), recordingDelegate: self)
        }
    }

    func stopRecording() {
        sessionQueue.async { [weak self] in
            guard let self, self.movieOutput.isRecording else { return }
            self.movieOutput.stopRecording()
        }
    }

    func revealLastSaved() {
        guard let url = lastSavedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - 종료

    func returnToConnect() {
        // 먼저 호출하면 정지 명령이 아래 teardown 블록보다 앞서 sessionQueue에 들어간다
        // (FIFO). FIFO가 보장하는 것은 그 순서뿐이다 — 남은 데이터는 정지 이후
        // 백그라운드에서 기록되므로(AVCaptureFileOutput 헤더) 파일이 끝까지 온전히
        // 마무리되는지는 이 순서만으로 단정할 수 없고, 실기기 스모크에서 실측한다.
        stopRecording()
        selectedDevice = nil
        activeSpec = nil
        // 다음 기기의 상태로 오해될 값을 모두 비운다. 이전 기기의 포맷 목록이 남으면
        // 연결 화면을 거쳐 다시 들어온 피커가 없는 포맷을 내보인다.
        formatSpecs = []
        centerStageState = .unknown
        // 녹화 표시도 여기서 끝낸다. 정지 델리게이트가 뒤늦게 도착해 같은 값을 다시
        // 써도 무해하고, 콜백이 오지 않는 경우에도 타이머가 남아 돌지 않는다.
        isRecording = false
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartDate = nil
        phase = .connect
        sessionQueue.async { [weak self, session] in
            // 소유 큐에서 해제한다. 등록도 sessionQueue이므로 순서가 뒤집히지 않는다.
            self?.formatObservation = nil
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

extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let fileExtension = usesHEVCPhotos ? "heic" : "jpg"
        DispatchQueue.main.async {
            if let error {
                self.errorBanner = "사진 촬영 실패: \(error.localizedDescription)"
                return
            }
            guard let data = photo.fileDataRepresentation() else {
                self.errorBanner = "사진 데이터를 만들지 못했습니다."
                return
            }
            let url = self.mediaStore.photoURL(fileExtension: fileExtension)
            do {
                try self.mediaStore.ensureDirectoryExists()
                try data.write(to: url)
                self.lastSavedURL = url
                self.flashPulse += 1
            } catch {
                self.errorBanner = "사진 저장 실패: \(error.localizedDescription)"
            }
        }
    }
}

extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        // 타이머 블록이 self를 약하게 잡으므로(참조 순환 방지) 바깥 클로저의 강한 캡처도
        // 명시한다. 암묵 캡처와 섞이면 컴파일러가 경고한다.
        DispatchQueue.main.async { [self] in
            self.isRecording = true
            self.recordingSeconds = 0
            self.recordingStartDate = Date()
            // 발화 횟수를 세면 안 된다. 메뉴 트래킹이나 창 크기 조절 중에는 기본
            // 런루프 모드의 타이머가 억제되고, 억제된 만큼의 시간을 영구히 잃는다.
            // 공통 모드(.common)로 등록해 그런 구간에서도 돌게 하고, 표시 값은
            // 시작 시각과의 차이로 계산해 어긋남이 누적되지 않게 한다.
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                guard let self, let start = self.recordingStartDate else { return }
                self.recordingSeconds = Int(Date().timeIntervalSince(start))
            }
            RunLoop.main.add(timer, forMode: .common)
            self.recordingTimer = timer
        }
    }

    // 이 SDK가 요구하는 시그니처는 connections까지 받는 4인자 형태다
    // (captureOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:).
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async {
            self.isRecording = false
            self.recordingTimer?.invalidate()
            self.recordingTimer = nil
            self.recordingStartDate = nil
            // error가 있다는 것만으로 실패라고 볼 수 없다. AVFoundation은 기기 이탈처럼
            // "중단됐지만 파일은 재생 가능한" 경우에도 error를 채워 보내고, 진짜 성공
            // 여부는 AVErrorRecordingSuccessfullyFinishedKey가 알려준다. 그래서 파일이
            // 온전할 때는 배너 없이 저장물로만 넘기고(설계 §9: 그 시점까지는 저장된다.
            // 기기 이탈 사유는 devicesChanged의 연결 끊김 배너가 이미 설명한다),
            // 실패했을 때는 Finder 버튼이 죽은 파일을 가리키지 않도록 저장물로 올리지 않는다.
            let finishedCleanly = ((error as NSError?)?
                .userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) ?? (error == nil)
            if finishedCleanly {
                self.lastSavedURL = outputFileURL
            } else {
                self.errorBanner =
                    "녹화가 중단되었습니다: \(error?.localizedDescription ?? "알 수 없는 오류")"
            }
        }
    }
}
