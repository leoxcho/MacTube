#if os(macOS)
import AVFoundation
import AppKit
import SwiftUI

/// Item-scoped geometry observation; no polling or playback state mutation.
struct MacVideoGeometryObserver: NSViewRepresentable {
    let player: AVPlayer
    let changed: (CGFloat) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(changed: changed) }
    func makeNSView(context: Context) -> NSView {
        context.coordinator.attach(player)
        return NSView(frame: .zero)
    }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.changed = changed
        context.coordinator.attach(player)
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.invalidate() }
    @MainActor final class Coordinator {
        var changed: (CGFloat) -> Void
        weak var player: AVPlayer?
        var itemObservation: NSKeyValueObservation?
        var sizeObservation: NSKeyValueObservation?
        init(changed: @escaping (CGFloat) -> Void) { self.changed = changed }
        func attach(_ player: AVPlayer) {
            guard self.player !== player else { return }
            self.player = player
            itemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] player, _ in
                Task { @MainActor [weak self, weak player] in
                    guard let self, let player, self.player === player else { return }
                    self.observeSize(player.currentItem)
                }
            }
        }
        func observeSize(_ item: AVPlayerItem?) {
            sizeObservation = nil
            guard let item else { return }
            sizeObservation = item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] item, _ in
                let size = item.presentationSize
                Task { @MainActor [weak self, weak item] in
                    guard let self, let item, self.player?.currentItem === item,
                          size.width > 0, size.height > 0 else { return }
                    self.changed(size.width / size.height)
                }
            }
        }
        func invalidate() { itemObservation = nil; sizeObservation = nil; player = nil }
    }
}
#endif
