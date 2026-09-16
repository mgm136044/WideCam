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

    /// 녹화 시작 요청이 진행 중인지. 메인 큐에서만 읽고 쓴다(판정 시점에만 읽으므로
    /// @Published로 두지 않는다 — 발행하면 녹화를 누를 때마다 화면이 재평가된다).
    ///
    /// 첫 실행에서 녹화를 누르면 마이크 권한 대화상자가 뜨고, 그 대화상자가 팝오버를
    /// 닫는다. 그때 팝오버의 자동 정지 판정은 "녹화 중도 아니고 큰 창도 없다"고 보고
    /// 세션을 내려버렸다. 사용자가 "허용"을 눌러도 녹화할 세션이 남아 있지 않아 아무것도
    /// 기록되지 않았고, 그 사실을 알리는 배너마저 팝오버를 다시 열 때의 자동 시작이
    /// 지워버렸다. 그래서 이 구간을 녹화 중과 똑같이 취급한다 — 세션을 놓지 않는다.
    ///
    /// **불변식**: 세우는 곳은 `startRecording()` 하나뿐이고, 내리는 곳은 녹화 시작
    /// 성공(`didStartRecordingTo`), 녹화 종료(`didFinishRecordingTo` — 시작 직후 실패한
    /// 경우도 이 콜백으로 온다), `beginRecording()`의 모든 실패 반환, 그리고
    /// `returnToConnect()`다. 한 곳이라도 빠지면 플래그가 남아 카메라를 영구히 붙잡는다.
    private(set) var isRecordingStartPending = false

    /// "지금 세션을 보여줄 화면이 있는가"를 묻는 훅. 앱 조립부(WideCamApp)가 주입하고
    /// 메인 큐에서만 부른다. nil이면(주입 전·테스트) 항상 켠다. 뷰 계층을 모른 채로
    /// 물어보기만 하려고 클로저로 받는다.
    var isPresentationReady: (() -> Bool)?

    // 세션과 그 소유 큐는 매니저 밖으로 내보내지 않는다. 뷰가 session을 직접 쥐면
    // 이번 크래시(메인에서 layer.session 대입 ↔ sessionQueue의 startRunning 경합)가
    // 그대로 재발할 수 있다. 프리뷰 부착은 attachPreview/detachPreview로만 한다.
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.mingyeongmin.WideCam.session")
    /// 기기 열거 전용 직렬 큐. 알림이 몰려도 열거가 겹치지 않고, 메인에 올라가는 순서가
    /// 열거 순서와 같다(세션을 만지지 않으므로 sessionQueue와 섞지 않는다).
    private let discoveryQueue = DispatchQueue(label: "com.mingyeongmin.WideCam.discovery")

    private(set) var selectedDevice: AVCaptureDevice?
    // formatObservation의 소유 큐는 sessionQueue다. 등록(observeFormatReversion)과
    // 해제(returnToConnect)를 모두 sessionQueue에서 처리해 FIFO 순서를 보장한다.
    private var formatObservation: NSKeyValueObservation?
    // 아래 세 변수도 sessionQueue에서만 접근한다.
    private var targetSpec: FormatSpec?
    private var isApplyingFormat = false
    /// 연속 재강제 횟수. 사용자가 포맷을 새로 고르거나 일치에 성공하면 0으로 되돌린다.
    private var reforceAttempts = 0
    /// 이 횟수를 넘기면 재강제를 포기하고 배너로 알린다.
    private static let maxReforceAttempts = 3

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

    /// 알림 페이로드는 읽지 않는다(위조 가능하고, 오디오 기기 착탈도 같은 알림을 낸다).
    /// 목록을 다시 열거하고 그 결과로만 판단한다.
    @objc private func devicesChanged(_ note: Notification) {
        refreshDevices()
    }

    /// 기기 열거를 메인 큐에서 하지 않는다. `DiscoverySession` 생성은 CoreMediaIO DAL
    /// 플러그인 로드를 유발할 수 있어(가상 카메라 앱이 깔린 기기에서 특히) 수십 밀리초
    /// 메인 스레드를 잡는데, 이 앱은 메뉴바 상주라 AirPods 착탈 같은 무관한 알림에도
    /// 이 경로가 깨어난다. 열거는 전용 직렬 큐에서 하고 결과만 메인으로 올린다.
    /// init()에서도 이 경로를 쓰므로 실행 시점의 메인 블로킹도 같이 사라진다.
    private func refreshDevices() {
        discoveryQueue.async { [weak self] in
            // 실측(2026-09-16): 아이폰 연속성 카메라는 이 macOS에서 .continuityCamera가
            // 아니라 .external 타입으로 열거된다(.continuityCamera만으로는 0대).
            // isContinuityCamera 필터가 선별을 담당하므로 .external은 죽은 값이 아니라
            // 유일한 통로다. 제거 금지.
            //
            // 한 번 지웠다가 스모크에서 "팝오버에 아이폰이 안 보인다"로 되돌렸다. 정적
            // 분석만으로 "필터가 어차피 걸러낸다"고 본 것이 틀렸다 — 필터가 걸러내는
            // 대상과 통과시키는 대상을 실기기로 확인하지 않았다. .continuityCamera는
            // 다른 OS 빌드에서 잡힐 수 있어 함께 남긴다(있어서 해가 없다).
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.continuityCamera, .external],
                mediaType: .video, position: .unspecified)
            let found = discovery.devices.filter { $0.isContinuityCamera }
            DispatchQueue.main.async {
                guard let self else { return }
                // 값이 같으면 발행하지 않는다. @Published는 같은 값에도 발행하므로
                // 게이팅이 없으면 무관한 기기 착탈마다 화면이 재평가된다.
                // AVCaptureDevice는 NSObject라 배열 비교가 동일성 비교로 성립한다.
                if self.availableDevices != found { self.availableDevices = found }
                // 연결 끊김 판정은 반드시 새 목록이 올라온 "뒤"에 한다. 열거가 동기였을
                // 때는 같은 블록의 순서가 이를 보장했지만 이제는 여기가 그 지점이다.
                if let current = self.selectedDevice, !found.contains(current) {
                    self.returnToConnect()
                    self.errorBanner = "아이폰 연결이 끊어졌습니다."
                }
            }
        }
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
            // 마이크는 여기서 붙이지 않는다. 프리뷰를 켜는 것만으로 아이폰 마이크가
            // 잡히면 메뉴바에 마이크 사용 표시가 뜨고, 녹화를 시도하지도 않은 사용자에게
            // 마이크 권한을 묻게 된다 — 번들의 사용 설명("영상 녹화에")과도 어긋난다.
            // 부착은 startRecording()으로, 분리는 녹화 종료 시점으로 옮겼다.

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
    /// `mirrored`는 호출하는 쪽(메인 큐)에서 읽은 현재 좌우반전 값이다. 세션을 붙이면
    /// 그 자리에서 연결이 생기므로 미러링도 같은 블록에서 함께 적용한다. 여기서 하지
    /// 않으면 첫 프레임이 기기 기본값(자동 미러링)으로 그려지고, updateNSView는
    /// isMirrored가 바뀌지 않는 한 그것을 교정할 기회가 없다.
    func attachPreview(_ layer: AVCaptureVideoPreviewLayer, mirrored: Bool) {
        sessionQueue.async { [session] in
            layer.session = session
            guard let connection = layer.connection else { return }
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
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
        sessionQueue.async { [weak self] in
            // 사용자가 새 포맷을 고르면 재강제 상한을 처음부터 다시 센다(이전 포맷에서
            // 상한에 걸렸다는 이유로 새 요청을 포기하면 안 된다).
            self?.reforceAttempts = 0
            self?.apply(spec: spec, to: device)
        }
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
                guard observed.width != target.width || observed.height != target.height else {
                    self.reforceAttempts = 0
                    return
                }
                // 재강제가 또 KVO를 깨우므로, 기기가 요청을 끝까지 거부하면 이 경로는
                // 무한 루프가 된다. 한 회차가 곧 캡처 스트림 재시작 1회라서 프리뷰가
                // 영구히 깜빡이고 코어 하나를 태운다(isApplyingFormat 가드는 이 경로를
                // 막지 못한다 — KVO 콜백이 sessionQueue로 다시 넘기면서 apply의 defer가
                // 이미 지나가 있다). 상한을 두되 조용히 포기하지는 않는다(설계 §9).
                self.reforceAttempts += 1
                guard self.reforceAttempts <= Self.maxReforceAttempts else {
                    DispatchQueue.main.async {
                        let message =
                            "기기가 \(target.label)을 유지하지 않아 재설정을 멈췄습니다 — 센터 스테이지가 켜져 있는지 확인해주세요."
                        // 포맷이 계속 흔들리는 기기에서는 이 경로가 반복해서 불린다.
                        // @Published는 같은 값에도 발행하므로 값이 바뀔 때만 쓴다.
                        if self.errorBanner != message { self.errorBanner = message }
                    }
                    return
                }
                self.apply(spec: target, to: device)
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
    private static let noCameraMessage = "카메라가 연결되어 있지 않아 녹화할 수 없습니다."

    /// 녹화를 시작해도 되는 상태인지. sessionQueue에서만 읽는다.
    ///
    /// 활성·사용 가능한 비디오 연결이 없거나 세션이 멈춘 상태에서 `startRecording(to:)`을
    /// 부르면 Swift에서 잡을 수 없는 NSException("no active and enabled connection")이
    /// 난다 — 즉 크래시다. capturePhoto()의 가드와 같은 이유다.
    private var canStartRecording: Bool {
        guard let connection = movieOutput.connection(with: .video) else { return false }
        return connection.isActive && connection.isEnabled && session.isRunning
    }

    /// 마이크를 세션에 붙인다. 실행 중인 세션을 고치므로 구성 트랜잭션으로 감싼다.
    /// sessionQueue에서만 호출한다.
    private func attachAudioInput(pairedWith camera: AVCaptureDevice) {
        // 이미 붙어 있으면 다시 붙이지 않는다(연속 녹화에서 입력이 겹쳐 쌓이는 것 방지).
        guard !session.inputs.contains(where: { Self.isAudioInput($0) }) else { return }
        // 그 사이 뒤로가기나 연결 끊김으로 이 카메라가 세션에서 빠졌으면 붙이지 않는다.
        // 세션 상태는 소유 큐인 sessionQueue에서 읽는다.
        guard session.inputs.contains(where: {
            ($0 as? AVCaptureDeviceInput)?.device.uniqueID == camera.uniqueID
        }) else { return }
        session.beginConfiguration()
        addAudioInput(pairedWith: camera)
        session.commitConfiguration()
    }

    /// 녹화가 끝나면 마이크를 뗀다. 프리뷰만 보는 동안 마이크 사용 표시가 켜져 있으면
    /// 사용자는 카메라 앱이 왜 마이크를 쓰는지 알 수 없다. sessionQueue에서만 호출한다.
    private func detachAudioInput() {
        let audioInputs = session.inputs.filter { Self.isAudioInput($0) }
        guard !audioInputs.isEmpty else { return }
        session.beginConfiguration()
        audioInputs.forEach(session.removeInput)
        session.commitConfiguration()
    }

    private static func isAudioInput(_ input: AVCaptureInput) -> Bool {
        (input as? AVCaptureDeviceInput)?.device.hasMediaType(.audio) == true
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

    /// 메인 큐에서 호출한다(뷰의 버튼에서만 불린다 — selectedDevice를 메인에서 읽는다).
    ///
    /// 마이크는 여기서 비로소 붙는다. 권한을 가르는 일은 예전에 세션 시작 경로가 하던
    /// 것을 그대로 옮겨 왔다. 권한이 없는데 그냥 붙이면 입력은 추가되지만 무음으로
    /// 기록되고, 사용자는 "마이크를 찾지 못했다"는 엉뚱한 설명만 보게 된다(설계 §9).
    func startRecording() {
        guard let camera = selectedDevice else {
            errorBanner = Self.noCameraMessage
            return
        }
        // 여기서부터 "녹화 시작 진행 중"이다. 권한 대화상자가 팝오버를 닫아도 자동 정지
        // 판정이 세션을 내리지 않게 한다(isRecordingStartPending 주석의 불변식 참고).
        isRecordingStartPending = true
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginRecording(audioFrom: camera)
        case .notDetermined:
            // 권한 대화상자는 비동기다. 허용되면 소리와 함께, 거절되면 소리 없이 녹화한다
            // (녹화 자체를 막지는 않는다).
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.beginRecording(audioFrom: camera)
                } else {
                    DispatchQueue.main.async { self.errorBanner = Self.micDeniedMessage }
                    self.beginRecording(audioFrom: nil)
                }
            }
        default:
            errorBanner = Self.micDeniedMessage
            beginRecording(audioFrom: nil)
        }
    }

    /// `audioFrom`이 nil이면 소리 없이 녹화한다. 부착과 녹화 시작을 같은 sessionQueue
    /// 블록에 넣어 순서를 보장한다 — 부착이 늦게 실행되면 첫 구간의 소리가 빠진다.
    ///
    /// 모든 실패 반환은 `finishRecordingStart()`를 거친다(성공 경로는 녹화 델리게이트가
    /// 내린다). 하나라도 빠지면 플래그가 남아 카메라를 영구히 붙잡는다.
    private func beginRecording(audioFrom camera: AVCaptureDevice?) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard !self.movieOutput.isRecording else {
                self.finishRecordingStart()
                return
            }
            // 마이크 부착보다 먼저 본다. 녹화를 못 하는 상황에 마이크만 붙이면 녹화도
            // 안 하면서 마이크 사용 표시가 켜진 채 남는다.
            guard self.canStartRecording else {
                self.finishRecordingStart()
                DispatchQueue.main.async { self.errorBanner = Self.noCameraMessage }
                return
            }
            do {
                try self.mediaStore.ensureDirectoryExists()
            } catch {
                self.finishRecordingStart()
                DispatchQueue.main.async {
                    self.errorBanner = "저장 폴더 생성 실패: \(error.localizedDescription)"
                }
                return
            }
            if let camera { self.attachAudioInput(pairedWith: camera) }
            // 마이크를 붙이는 구성 트랜잭션은 실행 중인 세션을 잠깐 멈추고 연결을 다시
            // 만든다. 그 뒤의 상태로 한 번 더 확인한다 — 여기서 어긋난 채 부르면 잡을 수
            // 없는 예외로 프로세스가 죽는다. 어긋났으면 붙인 마이크도 되돌린다.
            guard self.canStartRecording else {
                self.detachAudioInput()
                self.finishRecordingStart()
                DispatchQueue.main.async { self.errorBanner = Self.noCameraMessage }
                return
            }
            self.movieOutput.startRecording(to: self.mediaStore.movieURL(), recordingDelegate: self)
        }
    }

    /// 녹화 시작 진행 표시를 내린다. 내리는 경로 일부가 sessionQueue에 있으므로 항상
    /// 메인 큐로 넘긴다(메인에서 불러도 한 턴 뒤에 내려가며, 그 사이의 판정은 "진행 중"
    /// 으로 보는 쪽이 안전하다 — 세션을 놓지 않는 쪽이다).
    private func finishRecordingStart() {
        DispatchQueue.main.async { self.isRecordingStartPending = false }
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
        // 세션을 내리는 중이므로 진행 중이던 녹화 시작 요청도 끝난 것으로 본다. 남겨
        // 두면 다음 자동 정지 판정이 영구히 "진행 중"으로 읽어 카메라를 놓지 않는다.
        isRecordingStartPending = false
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartDate = nil
        phase = .connect
        sessionQueue.async { [weak self, session] in
            // 소유 큐에서 해제한다. 등록도 sessionQueue이므로 순서가 뒤집히지 않는다.
            self?.formatObservation = nil
            // targetSpec도 비운다. 남겨 두면 다음 세션에서 KVO를 거는 시점과 새 초기
            // 포맷을 적용하는 시점 사이에 "이전 기기의 목표"로 비교하게 되고, 새 기기에
            // 이전 해상도를 강제하거나 없는 포맷을 요청하는 배너가 뜬다(start()의
            // "이 시점에는 targetSpec이 아직 nil"이라는 주석이 그래야 참이 된다).
            self?.targetSpec = nil
            self?.reforceAttempts = 0
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
        // 이 콜백은 메인이 아닌 큐로 도착한다. 예전에는 일부러 메인으로 넘긴 뒤 거기서
        // HEIC 직렬화(5~30밀리초)와 디스크 쓰기까지 했다 — 셔터 한 번에 메인 스레드가
        // 그만큼 멈췄고, 번쩍임이 쓰기 "뒤"에 올라가 셔터 피드백도 그만큼 늦었다.
        // 무거운 일은 이 큐에서 끝내고 메인에는 결과만 올린다.
        if let error {
            DispatchQueue.main.async {
                self.errorBanner = "사진 촬영 실패: \(error.localizedDescription)"
            }
            return
        }
        // 번쩍임은 디스크를 기다리지 않는다. 사진이 찍힌 사실은 이미 확정됐다.
        DispatchQueue.main.async { self.flashPulse += 1 }

        let fileExtension = usesHEVCPhotos ? "heic" : "jpg"
        guard let data = photo.fileDataRepresentation() else {
            DispatchQueue.main.async {
                self.errorBanner = "사진 데이터를 만들지 못했습니다."
            }
            return
        }
        let url = mediaStore.photoURL(fileExtension: fileExtension)
        do {
            try mediaStore.ensureDirectoryExists()
            // .withoutOverwriting은 O_EXCL이라 경로에 무엇이 이미 있으면 실패한다.
            // 끊어진 심볼릭 링크는 fileExists가 "없음"으로 보고하므로(stat 의미론) 그
            // 링크를 따라가 엉뚱한 위치에 사진을 쓸 수 있었는데, 이 옵션이 그 경로를
            // 닫는다. 이름 충돌은 photoURL의 _2 접미사가 이미 피하므로 정상 저장을
            // 막지 않고, 실패하면 아래 배너가 그대로 알린다.
            try data.write(to: url, options: .withoutOverwriting)
            DispatchQueue.main.async { self.lastSavedURL = url }
        } catch {
            DispatchQueue.main.async {
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
            // 실제로 시작됐으니 진행 표시를 내린다(이제 isRecording이 세션을 지킨다).
            self.isRecordingStartPending = false
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
            // 시작 직후 실패해 didStartRecordingTo 없이 이 콜백만 오는 경우까지 덮는다
            // (불변식: 진행 표시를 내리지 않는 종료 경로가 있으면 안 된다).
            self.isRecordingStartPending = false
            self.isRecording = false
            self.recordingTimer?.invalidate()
            self.recordingTimer = nil
            self.recordingStartDate = nil
            // 녹화가 끝났으니 마이크를 뗀다(세션 변형이므로 소유 큐로 넘긴다). 이 시점에
            // 파일은 이미 마무리돼 있다 — 델리게이트가 그 사실을 알리는 콜백이다.
            // (바깥 블록이 self를 강하게 잡고 있으므로 여기서도 강한 캡처로 맞춘다.)
            self.sessionQueue.async { self.detachAudioInput() }
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
