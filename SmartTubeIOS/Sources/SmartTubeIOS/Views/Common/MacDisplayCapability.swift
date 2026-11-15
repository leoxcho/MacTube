#if os(macOS)
import AppKit
import SwiftUI

/// Reads screen capabilities only on window/display events; owns no display link.
struct MacDisplayCapability: NSViewRepresentable {
    @Binding var maximumRefresh: Int
    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.report = { maximumRefresh = $0 }
        return view
    }
    func updateNSView(_ view: Probe, context: Context) { view.report = { maximumRefresh = $0 } }
    @MainActor final class Probe: NSView {
        var report: ((Int) -> Void)?
        private var windowTask: Task<Void, Never>?
        private var displayTask: Task<Void, Never>?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            windowTask?.cancel(); displayTask?.cancel()
            guard let window else { return }
            updateCapability()
            windowTask = Task { [weak self, weak window] in
                for await _ in NotificationCenter.default.notifications(named: NSWindow.didChangeScreenNotification) {
                    guard !Task.isCancelled else { return }
                    guard let self, let window, self.window === window else { continue }
                    self.updateCapability()
                }
            }
            displayTask = Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: NSApplication.didChangeScreenParametersNotification) {
                    guard !Task.isCancelled else { return }
                    self?.updateCapability()
                }
            }
        }
        private func updateCapability() { report?(window?.screen?.maximumFramesPerSecond ?? 0) }
        deinit { windowTask?.cancel(); displayTask?.cancel() }
    }
}
#endif
