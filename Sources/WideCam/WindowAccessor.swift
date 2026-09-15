import AppKit
import SwiftUI

/// SwiftUI 뷰가 자신이 속한 NSWindow를 붙잡기 위한 브리지.
/// @State가 이 머신에서 컴파일되지 않으므로(매크로 dylib 부재) ObservableObject로 보관한다.
final class WindowHolder: ObservableObject {
    weak var window: NSWindow?
}

struct WindowAccessor: NSViewRepresentable {
    let holder: WindowHolder

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak holder] in
            guard let window = view.window else { return }
            holder?.window = window
            window.collectionBehavior.insert(.fullScreenPrimary)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // 이미 같은 창을 잡아 뒀으면 아무 일도 하지 않는다. 녹화 중에는 초당 1회 body가
        // 재평가되고 그때마다 main.async + collectionBehavior 쓰기가 WindowServer로
        // 나갔다 — 전체화면 관련 플래그를 값이 안 바뀌었는데도 반복해서 건드리는 것은
        // 부작용 위험이 0이 아니다.
        if let window = nsView.window, window === holder.window { return }
        DispatchQueue.main.async { [weak holder] in
            guard let window = nsView.window else { return }
            holder?.window = window
            window.collectionBehavior.insert(.fullScreenPrimary)
        }
    }
}
