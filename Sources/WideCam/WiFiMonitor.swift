import CoreWLAN
import Foundation

/// 맥의 Wi-Fi 전원 상태를 지켜본다.
///
/// 연속성 카메라는 맥과 아이폰 양쪽의 Wi-Fi·블루투스가 켜져 있어야 동작한다. 안내
/// 문구만 나열하면 사용자가 세 가지 가능성을 모두 직접 확인해야 하는데, 맥 쪽 Wi-Fi
/// 전원만은 앱이 실측할 수 있으므로 꺼져 있으면 그것을 먼저 말한다.
///
/// 값을 볼 때마다 동기적으로 읽는 방식(이전 ConnectivityHint)은 화면을 다시 그리지
/// 않는 한 갱신되지 않았다 — 팝오버를 열어둔 채 Wi-Fi를 켜도 경고가 남았다. 그래서
/// 전원 변경 이벤트를 구독해 @Published로 밀어준다.
final class WiFiMonitor: NSObject, ObservableObject, CWEventDelegate {
    /// 프로세스에 하나만 둔다(생성은 이 프로퍼티로만 한다). 감싸는 대상인
    /// `CWWiFiClient.shared()` 자체가 프로세스 싱글턴이고, 앱이 소유해
    /// MainWindowView → ConnectView로 넘기면 매개변수만 늘고 진실은 늘지 않는다.
    static let shared = WiFiMonitor()

    /// 팝오버와 연결 화면이 같은 문장을 쓰도록 문구도 한 곳에 둔다(두 화면이 같은
    /// 상황을 다른 말로 설명하면 사용자는 다른 문제라고 오해한다).
    static let offMessage = "Wi-Fi가 꺼져 있습니다 — 켜주세요"

    @Published private(set) var isOff: Bool

    private let client = CWWiFiClient.shared()

    override init() {
        // super.init() 전에는 self.client를 읽을 수 없으므로 싱글턴을 직접 쓴다.
        isOff = Self.readIsOff(CWWiFiClient.shared())
        super.init()
        client.delegate = self
        // 구독에 실패하면 초기값에 머문다. 그 경우에도 없는 문제를 알리지는 않는다.
        try? client.startMonitoringEvent(with: .powerDidChange)
    }

    /// 전원 상태만 읽는다. SSID·BSSID 읽기는 위치 권한을 요구하므로 절대 부르지
    /// 않는다 — 위치 권한 대화상자가 카메라 권한과 뒤섞이면 사용자는 무엇을 허용하는지
    /// 알 수 없다.
    ///
    /// Wi-Fi 하드웨어가 없으면(`interface()`가 nil) "꺼짐"이 아니다. 없는 것과 꺼진
    /// 것은 다르고, 켤 수 없는 것을 켜라고 하면 안 된다.
    private static func readIsOff(_ client: CWWiFiClient) -> Bool {
        client.interface()?.powerOn() == false
    }

    // MARK: - CWEventDelegate

    /// 콜백이 어느 큐로 올지는 문서가 보장하지 않는다. @Published는 메인 큐에서만 바꾼다.
    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let current = Self.readIsOff(self.client)
            // @Published는 같은 값을 넣어도 발행한다. 값이 바뀔 때만 알린다.
            if self.isOff != current { self.isOff = current }
        }
    }
}
