#if os(macOS)
import AppKit
import AVKit
import SwiftUI

extension Notification.Name {
    /// Navigation should reopen MacPlaybackSession.shared.currentVideo when AVKit restores PiP.
    static let macRestoreNativePictureInPicture = Notification.Name("MacTube.restoreNativePictureInPicture")
}

/// Keeps one AVPlayerView mounted while switching controls. Its AVPlayer is the session's player.
struct MacNativePlayerView: NSViewRepresentable {
    @MainActor static var isPictureInPictureActive: Bool { Coordinator.hasActiveHosts }
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspect
    var nativeControls = false

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.allowsPictureInPicturePlayback = true
        view.showsFullScreenToggleButton = false // The watch page owns fullscreen layout.
        view.pictureInPictureDelegate = context.coordinator
        context.coordinator.view = view
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        // Updating controls never reloads the current item or resets playback position.
        if view.player !== player { view.player = player }
        view.videoGravity = videoGravity
        view.controlsStyle = nativeControls ? .floating : .none
        context.coordinator.mounted = true
    }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        coordinator.originalWindow = view.window ?? coordinator.originalWindow
        coordinator.mounted = false
        if !coordinator.active { view.player = nil }
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency AVPlayerViewPictureInPictureDelegate {
        // AVKit needs its presentation host and delegate to survive navigation out of watch.
        private static var activeHosts: [ObjectIdentifier: Coordinator] = [:]
        static var hasActiveHosts: Bool { !activeHosts.isEmpty }
        var view: AVPlayerView?
        weak var originalWindow: NSWindow?
        var active = false
        var mounted = true
        func playerViewWillStartPicture(inPicture playerView: AVPlayerView) {
            active = true
            originalWindow = playerView.window
            Self.activeHosts[ObjectIdentifier(playerView)] = self
        }
        func playerView(_ playerView: AVPlayerView, failedToStartPictureInPictureWithError error: any Error) {
            finish(playerView)
        }
        func playerViewDidStopPicture(inPicture playerView: AVPlayerView) { finish(playerView) }
        func playerViewShouldAutomaticallyDismissAtPicture(inPictureStart playerView: AVPlayerView) -> Bool { false }
        func playerView(_ playerView: AVPlayerView,
                        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
            let window = playerView.window ?? originalWindow
            window?.deminiaturize(nil)
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .macRestoreNativePictureInPicture, object: playerView.player)
            completionHandler(window != nil)
        }
        private func finish(_ playerView: AVPlayerView) {
            active = false
            Self.activeHosts.removeValue(forKey: ObjectIdentifier(playerView))
            if !mounted { playerView.player = nil; view = nil }
            if !Self.hasActiveHosts && !MacDesktopLifetime.hasOpenWindows {
                MacPlaybackSession.shared.stop()
            }
        }
    }
}
#endif
