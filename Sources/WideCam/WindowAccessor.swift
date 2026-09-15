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
        DispatchQueue.main.async { [weak holder] in
            guard let window = nsView.window else { return }
            holder?.window = window
            window.collectionBehavior.insert(.fullScreenPrimary)
        }
    }
}
