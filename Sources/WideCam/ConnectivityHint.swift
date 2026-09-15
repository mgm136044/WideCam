import CoreWLAN

/// 아이폰이 목록에 없을 때 "왜 없는지"를 짚어주기 위한 환경 점검.
///
/// 연속성 카메라는 맥과 아이폰 양쪽의 Wi-Fi·블루투스가 켜져 있어야 동작한다. 그런데
/// 안내 문구만 나열하면 사용자는 세 가지 가능성을 모두 직접 확인해야 한다. 맥 쪽
/// Wi-Fi 전원만은 앱이 직접 알 수 있으므로, 꺼져 있으면 그것을 먼저 말한다.
enum ConnectivityHint {
    /// 맥의 Wi-Fi가 꺼져 있는가. Wi-Fi 하드웨어가 없는 기기(interface() == nil)에서는
    /// false다 — 없는 것과 꺼진 것은 다르고, 켤 수 없는 것을 켜라고 하면 안 된다.
    ///
    /// `powerOn()`은 위치 권한을 요구하지 않는다. 권한이 필요한 것은 SSID·BSSID 읽기
    /// (`ssid()`, `bssid()`)이고, 그건 여기서 하지 않는다 — 권한 대화상자가 뜨면
    /// 카메라 권한과 뒤섞여 사용자가 무엇을 허용하는지 알 수 없게 된다.
    static var isWiFiOff: Bool {
        CWWiFiClient.shared().interface()?.powerOn() == false
    }
}
