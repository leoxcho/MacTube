#if os(macOS)
import AppKit
import AVFoundation
import SmartTubeIOSCore
import SwiftUI

private struct MacTheaterKey: EnvironmentKey {
    static let defaultValue: Binding<Bool> = .constant(false)
}
extension EnvironmentValues {
    var macTheaterMode: Binding<Bool> {
        get { self[MacTheaterKey.self] }
        set { self[MacTheaterKey.self] = newValue }
    }
}

extension PlayerView {
    func macTransportControls(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 8) {
                macProgress
                HStack(spacing: width < 480 ? 6 : 14) {
                    macControl(vm.isPlaying ? "pause.fill" : "play.fill", vm.isPlaying ? "Pause (K)" : "Play (K)") { vm.togglePlayPause() }
                    if width >= 480, vm.hasPrevious { macControl("backward.end.fill", "Previous (Shift P)") { vm.playPrevious() } }
                    if width >= 480, vm.hasNext { macControl("forward.end.fill", "Next (Shift N)") { vm.playNext() } }
                    if width >= 680 { macVolume }
                    else { macControl(vm.player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", "Mute (M)") { vm.player.isMuted.toggle() } }
                    if width >= 480 { Text(formatDuration(vm.currentTime) + " / " + (vm.isLivePlayback ? "LIVE" : formatDuration(vm.duration)))
                        .font(.caption.monospacedDigit()).lineLimit(1) }
                    Spacer(minLength: 4)
                    if width >= 300 { MacCaptionControls(vm: vm) }
                    Menu {
                        Button("Quality…") { showQualityPicker = true; vm.cancelControlsHide() }
                        Menu("Playback speed") {
                            ForEach(AppSettings.availableSpeeds, id: \.self) { speed in
                                Button(speed == 1 ? "Normal (1×)" : "\(speed.formatted())×") {
                                    store.settings.playbackSpeed = speed
                                    vm.setPlaybackSpeed(speed)
                                }
                            }
                        }
                        Toggle("Loop this video", isOn: Binding(get: { vm.isCurrentVideoLooping }, set: {
                            vm.setCurrentVideoLooping($0)
                        }))
                        Button("System controls / Picture in Picture") { macNativePlayerControls = true }
                    } label: { Image(systemName: "gearshape.fill").font(.title3) }
                    .menuStyle(.borderlessButton).fixedSize().help("Player settings")
                    if width >= 480 { macControl("pip.enter", "Mini-player (I)") { macClose?() } }
                    if width >= 580 {
                        macControl("rectangle", "Theater mode (T)") { macTheaterMode.wrappedValue.toggle() }
                    }
                    macControl(macFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", "Fullscreen (F), exit (Escape)") {
                        macFullscreen.toggle()
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 14).padding(.top, 38)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom))
        }
        .foregroundStyle(.white).buttonStyle(.plain)
    }

    private var macProgress: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22)).frame(height: 4)
                let buffered = vm.player.currentItem?.loadedTimeRanges.compactMap { value -> Double? in
                    let range = value.timeRangeValue
                    let end = CMTimeRangeGetEnd(range).seconds
                    return end.isFinite ? end : nil
                }.max() ?? 0
                Capsule().fill(.white.opacity(0.45))
                    .frame(width: geometry.size.width * min(1, max(0, buffered / max(vm.duration, 1))), height: 4)
                Slider(value: Binding(get: { vm.isScrubbing ? vm.scrubTime : vm.currentTime }, set: { vm.updateScrub(to: $0) }),
                       in: 0...max(vm.duration, 1), onEditingChanged: { editing in
                    if editing { vm.beginScrubbing(); vm.cancelControlsHide() } else { vm.commitScrub() }
                })
                .tint(.red).disabled(vm.duration <= 0 || vm.isLivePlayback)
                .accessibilityLabel("Playback position").help("Seek")
            }
        }.frame(height: 18)
    }
    private var macVolume: some View {
        HStack(spacing: 6) {
            macControl(vm.player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", "Mute (M)") {
                vm.player.isMuted.toggle()
            }
            Slider(value: Binding(get: { Double(vm.player.volume) }, set: {
                vm.player.volume = Float($0)
                vm.player.isMuted = $0 == 0
            }), in: 0...1)
            .frame(width: 65).accessibilityLabel("Volume")
        }
    }
    private func macControl(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button { action(); vm.showControls() } label: {
            Image(systemName: symbol).font(.system(size: 18)).frame(minWidth: 24, minHeight: 28).contentShape(Rectangle())
        }.help(title).accessibilityLabel(title)
    }
}

/// Registers presentation actions with the centralized input dispatcher. No monitor
/// or playback session is created by the watch page.
struct MacPlaybackKeyboard: NSViewRepresentable {
    let vm: PlaybackViewModel
    @Binding var fullscreen: Bool
    @Binding var theater: Bool
    let minimize: () -> Void
    let setSpeed: (Double) -> Void
    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ host: Host, context: Context) {
        host.handle = { action in
            guard MacPlaybackSession.shared.activeModel === vm else { return false }
            switch action {
            case .fullscreen: fullscreen.toggle()
            case .exitFullscreen:
                guard fullscreen else { return false }; fullscreen = false
            case .theater: theater.toggle()
            case .miniPlayer: minimize()
            case .speedUp: setSpeed(min(2, vm.settings.playbackSpeed + 0.25))
            case .speedDown: setSpeed(max(0.25, vm.settings.playbackSpeed - 0.25))
            default: return false
            }
            vm.showControls(); return true
        }
        host.register()
    }
    static func dismantleNSView(_ host: Host, coordinator: ()) { host.stop() }
    @MainActor final class Host: NSView {
        var handle: ((MacInputAction) -> Bool)?
        weak var registeredWindow: NSWindow?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); stop(); register() }
        func register() {
            guard let window else { return }
            registeredWindow = window
            MacInputDispatcher.shared.presentation(window: window) { [weak self] in self?.handle?($0) ?? false }
        }
        func stop() {
            if let registeredWindow { MacInputDispatcher.shared.removePresentation(window: registeredWindow) }
            registeredWindow = nil
        }
    }
}
#endif
