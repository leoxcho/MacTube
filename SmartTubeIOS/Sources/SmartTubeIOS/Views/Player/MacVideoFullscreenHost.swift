#if os(macOS)
import AppKit
import QuartzCore
import SwiftUI

/// AppKit owns the native transition. Capture the window *before* SwiftUI changes
/// layout, and restore once AppKit has finished exiting, never during animation.
struct MacVideoFullscreenHost: NSViewRepresentable {
    @Binding var fullscreen: Bool
    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ view: Host, context: Context) {
        view.exit = { fullscreen = false }
        view.setDesired(fullscreen)
    }
    static func dismantleNSView(_ view: Host, coordinator: ()) { view.finish() }

    final class Host: NSView {
        private static var pendingRestorations: [ObjectIdentifier: Host] = [:]
        private var detached = false
        var desired = false
        var active = false
        var ownsNativeFullscreen = false
        var transitioning = false
        var exit: (() -> Void)?
        var frameBeforeFullscreen: NSRect?
        var titleVisibility: NSWindow.TitleVisibility = .visible
        var titlebarTransparent = false
        var toolbarVisible = false
        var hadFullSizeContent = false
        var fullscreenToolbarStyle: NSWindow.ToolbarStyle = .automatic
        var observers: [NSObjectProtocol] = []
        weak var observedWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, observedWindow !== window else { return }
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            observedWindow = window
            observe(NSWindow.willEnterFullScreenNotification) { host in
                if host.desired { host.prepareChrome() }
                host.transitioning = true
            }
            observe(NSWindow.didEnterFullScreenNotification) { host in
                host.transitioning = false
                host.apply()
            }
            observe(NSWindow.willCloseNotification) { host in host.cleanup() }
            observe(NSWindow.didExitFullScreenNotification) { host in
                host.transitioning = false
                if host.active { host.desired = false; host.exit?() }
                host.restore()
            }
            apply()
        }
        private func observe(_ name: Notification.Name, action: @escaping @MainActor (Host) -> Void) {
            guard let observedWindow else { return }
            observers.append(NotificationCenter.default.addObserver(forName: name, object: observedWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { action(self) } }
            })
        }
        func setDesired(_ value: Bool) { desired = value; apply() }
        func apply() {
            guard let window, !transitioning else { return }
            if desired && !active {
                active = true
                ownsNativeFullscreen = !window.styleMask.contains(.fullScreen)
                frameBeforeFullscreen = ownsNativeFullscreen ? window.frame : nil
                titleVisibility = window.titleVisibility
                titlebarTransparent = window.titlebarAppearsTransparent
                toolbarVisible = window.toolbar?.isVisible ?? false
                hadFullSizeContent = window.styleMask.contains(.fullSizeContentView)
                fullscreenToolbarStyle = window.toolbarStyle
                prepareChrome()
                if ownsNativeFullscreen {
                    transitioning = true
                    window.toggleFullScreen(nil)
                }
            } else if !desired && active {
                if ownsNativeFullscreen, window.styleMask.contains(.fullScreen) {
                    transitioning = true
                    window.toggleFullScreen(nil)
                } else { restore() }
            }
        }
        private func prepareChrome() {
            guard let window = observedWindow else { return }
            // Commit chrome and the new SwiftUI geometry before AppKit snapshots
            // the first fullscreen frame. Never schedule a delayed hide.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.toolbar?.isVisible = false
            window.styleMask.insert(.fullSizeContentView)
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            window.contentView?.superview?.displayIfNeeded()
            CATransaction.commit()
        }
        private func restore() {
            guard active, let window = observedWindow else { return }
            active = false
            window.titleVisibility = titleVisibility
            window.titlebarAppearsTransparent = titlebarTransparent
            window.toolbarStyle = fullscreenToolbarStyle
            window.toolbar?.isVisible = toolbarVisible
            if !hadFullSizeContent { window.styleMask.remove(.fullSizeContentView) }
            if let original = frameBeforeFullscreen {
                // Keep the exact frame on its original display. Clamp only if the
                // display was removed or its available bounds changed meanwhile.
                let screen = NSScreen.screens.max { a, b in
                    a.visibleFrame.intersection(original).width * a.visibleFrame.intersection(original).height
                        < b.visibleFrame.intersection(original).width * b.visibleFrame.intersection(original).height
                } ?? window.screen
                var restored = original
                if let bounds = screen?.visibleFrame, !bounds.contains(original) {
                    restored.size.width = min(original.width, bounds.width)
                    restored.size.height = min(original.height, bounds.height)
                    restored.origin.x = min(max(original.minX, bounds.minX), bounds.maxX - restored.width)
                    restored.origin.y = min(max(original.minY, bounds.minY), bounds.maxY - restored.height)
                }
                window.setFrame(restored, display: true)
            }
            frameBeforeFullscreen = nil
            ownsNativeFullscreen = false
            if detached { cleanup() }
        }
        private func cleanup() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            Self.pendingRestorations.removeValue(forKey: ObjectIdentifier(self))
        }
        func finish() {
            detached = true
            desired = false
            // Keep the restoration observer alive through AppKit's asynchronous
            // exit even if navigation has removed this representable already.
            if active && ownsNativeFullscreen {
                Self.pendingRestorations[ObjectIdentifier(self)] = self
                apply()
            } else {
                apply()
                cleanup()
            }
        }
    }
}
#endif
