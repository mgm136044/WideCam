import AVFoundation
import SwiftUI

struct ConnectView: View {
    @ObservedObject var camera: CameraManager

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "iphone.rear.camera")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("아이폰 카메라 연결")
                .font(.largeTitle.bold())

            if camera.availableDevices.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("아이폰이 보이지 않아요. 다음을 확인하세요.")
                        .font(.headline)
                    // 맥 쪽 Wi-Fi가 꺼져 있다는 것은 실측이다. 아래 세 줄의 "확인하세요"
                    // 중에서 이미 확정된 원인 하나를 먼저 짚어준다(팝오버와 같은 문장).
                    if ConnectivityHint.isWiFiOff {
                        Label("Wi-Fi가 꺼져 있습니다 — 켜주세요", systemImage: "wifi.slash")
                            .foregroundStyle(.orange)
                    }
                    Label("맥과 아이폰이 같은 Apple 계정으로 로그인되어 있어야 합니다",
                          systemImage: "person.circle")
                    Label("양쪽 모두 Wi-Fi와 블루투스가 켜져 있어야 합니다", systemImage: "wifi")
                    Label("USB 케이블로 연결하면 가장 안정적입니다", systemImage: "cable.connector")
                }
                .padding(24)
                .glassEffect(in: RoundedRectangle(cornerRadius: 20))
            } else {
                ForEach(camera.availableDevices, id: \.uniqueID) { device in
                    Button {
                        camera.select(device: device)
                    } label: {
                        Label(device.localizedName, systemImage: "iphone")
                            .font(.title3)
                            .frame(maxWidth: 320)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                }
            }

            if let message = camera.errorBanner {
                Text(message)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .glassEffect(in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
