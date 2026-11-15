#if os(macOS)
import AppKit
import SwiftUI

/// Configure the native titlebar once per attachment, retaining standard window
/// buttons and dragging while allowing the shared backdrop beneath the chrome.
struct MacWindowGlassChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ view: Host, context: Context) {}
    @MainActor final class Host: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            window.styleMask.insert(.fullSizeContentView)
        }
    }
}
#endif
