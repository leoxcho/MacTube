#if os(macOS)
import AppKit
import AVFoundation
import CoreImage
import Metal
import Observation
import QuartzCore
import SmartTubeIOSCore
import SwiftUI

private enum AmbientPreference {
    static let enabled = "mactube.ambient.enabled"
    static let dynamic = "mactube.ambient.dynamic"
    static let intensity = "mactube.ambient.intensity"
    static let spread = "mactube.ambient.spread"
    static let saturation = "mactube.ambient.saturation"
    static let frequency = "mactube.ambient.frequency"
    static let smoothness = "mactube.ambient.smoothness"
    static let red = "mactube.ambient.static.red"
    static let green = "mactube.ambient.static.green"
    static let blue = "mactube.ambient.static.blue"
    static let opacity = "mactube.glass.opacity"
    static let tint = "mactube.glass.tint"
}

// The pixel buffer is retained across the actor hop and treated as immutable.
private struct AmbientFrame: @unchecked Sendable { let buffer: CVPixelBuffer }
private actor AmbientPaletteProcessor {
    private let context: CIContext?
    nonisolated let available: Bool
    init() {
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
            available = true
        } else {
            context = nil
            available = false
        }
    }
    func palette(_ frame: AmbientFrame) -> [[Double]]? {
        guard let context else { return nil } // Never fall back to CPU frame processing.
        let image = CIImage(cvPixelBuffer: frame.buffer)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        // Reduce the decoded frame on the GPU before reading only four RGBA pixels.
        let small = image.transformed(by: CGAffineTransform(scaleX: 64 / extent.width, y: 36 / extent.height))
        let edges = [CGRect(x: 0, y: 0, width: 8, height: 36),
                     CGRect(x: 56, y: 0, width: 8, height: 36),
                     CGRect(x: 0, y: 28, width: 64, height: 8),
                     CGRect(x: 0, y: 0, width: 64, height: 8)]
        return edges.map { edge in
            let average = small.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: edge)])
            var pixel = [UInt8](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { bytes in
                if let address = bytes.baseAddress {
                    context.render(average, toBitmap: address, rowBytes: 4,
                                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                   format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
                }
            }
            return pixel.prefix(3).map { Double($0) / 255 }
        }
    }
}

@MainActor @Observable
private final class MacAmbientLightController {
    var palette = Array(repeating: [0.12, 0.18, 0.28], count: 4)
    private var output: AVPlayerItemVideoOutput?
    private weak var item: AVPlayerItem?
    private var task: Task<Void, Never>?
    private let processor = AmbientPaletteProcessor()
    private var rateObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private weak var player: AVPlayer?
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var enabled = false
    private var smoothness = 0.8
    private var lastSampleAt: TimeInterval?
    private var frequency = 3.0
    private var generation = 0

    func connect(player: AVPlayer, window: NSWindow?, enabled: Bool, frequency: Double, smoothness: Double) {
        if self.player !== player {
            disconnect()
            self.player = player
            rateObservation = player.observe(\.rate, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
            itemObservation = player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
            for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                         NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.refresh() }
                })
            }
        }
        self.window = window
        self.enabled = enabled
        self.smoothness = min(3, max(0.1, smoothness))
        self.frequency = min(5, max(2, frequency))
        refresh()
    }

    private func refresh() {
        generation += 1
        let token = generation
        task?.cancel()
        task = nil
        guard enabled, processor.available, let player, let window, NSApp.isActive,
              window.isVisible, !window.isMiniaturized, window.occlusionState.contains(.visible),
              let current = player.currentItem else { detachOutput(); return }
        // A paused player keeps the last palette and performs no sampling.
        guard player.rate != 0 else { detachOutput(); return }
        if item !== current {
            detachOutput()
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ])
            current.add(output)
            self.output = output
            lastSampleAt = nil
            item = current
        }
        task = Task { [weak self] in
            guard let self else { return }
            repeat {
                guard !Task.isCancelled, generation == token, let output else { return }
                let time = output.itemTime(forHostTime: CACurrentMediaTime())
                if output.hasNewPixelBuffer(forItemTime: time),
                   let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil),
                   let colors = await processor.palette(AmbientFrame(buffer: buffer)) {
                    guard !Task.isCancelled, generation == token else { return }
                    // Time-based smoothing behaves consistently at every update frequency.
                    let now = Date.timeIntervalSinceReferenceDate
                    let elapsed = lastSampleAt.map { now - $0 } ?? (1 / frequency)
                    lastSampleAt = now
                    let alpha = 1 - exp(-elapsed / smoothness)
                    let nextPalette = zip(palette, colors).map { previous, next in
                        zip(previous, next).map { $0 * (1 - alpha) + $1 * alpha }
                    }
                    let difference = zip(palette.flatMap { $0 }, nextPalette.flatMap { $0 })
                        .map { abs($0 - $1) }.max() ?? 0
                    // Do not invalidate SwiftUI for visually negligible changes.
                    if difference >= 0.008 { palette = nextPalette }
                }
                do { try await Task.sleep(for: .seconds(1 / frequency)) } catch { return }
            } while !Task.isCancelled
        }
    }
    private func detachOutput() {
        if let output, let item { item.remove(output) }
        output = nil
        item = nil
    }
    func disconnect() {
        generation += 1
        task?.cancel(); task = nil
        rateObservation?.invalidate(); rateObservation = nil
        itemObservation?.invalidate(); itemObservation = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        detachOutput()
        player = nil
        window = nil
    }
}

private struct AmbientWindowReader: NSViewRepresentable {
    var changed: (NSWindow?) -> Void
    func makeNSView(context: Context) -> Reader { Reader(changed: changed) }
    func updateNSView(_ view: Reader, context: Context) { view.changed = changed }
    final class Reader: NSView {
        var changed: (NSWindow?) -> Void
        init(changed: @escaping (NSWindow?) -> Void) { self.changed = changed; super.init(frame: .zero) }
        required init?(coder: NSCoder) { return nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); changed(window) }
    }
}

/// Uses the active player's decoded frames. Include once behind the watch-page content.
struct MacAmbientLightView: View {
    let player: AVPlayer
    var enabled = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AmbientPreference.enabled) private var preferenceEnabled = false
    @AppStorage(AmbientPreference.dynamic) private var dynamic = true
    @AppStorage(AmbientPreference.intensity) private var intensity = 0.35
    @AppStorage(AmbientPreference.spread) private var spread = 0.65
    @AppStorage(AmbientPreference.saturation) private var saturation = 1.0
    @AppStorage(AmbientPreference.frequency) private var frequency = 3.0
    @AppStorage(AmbientPreference.smoothness) private var smoothness = 0.8
    @AppStorage(AmbientPreference.red) private var staticRed = 0.15
    @AppStorage(AmbientPreference.green) private var staticGreen = 0.25
    @AppStorage(AmbientPreference.blue) private var staticBlue = 0.45
    @State private var controller = MacAmbientLightController()
    @State private var window: NSWindow?
    private var active: Bool { enabled && preferenceEnabled && !reduceTransparency }
    private var configuration: String { "\(active)-\(dynamic)-\(reduceMotion)-\(frequency)-\(smoothness)" }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if active {
                    ForEach(0..<4, id: \.self) { index in
                        let rgb = dynamic && !reduceMotion ? controller.palette[index] : [staticRed, staticGreen, staticBlue]
                        RadialGradient(colors: [Color(red: rgb[0], green: rgb[1], blue: rgb[2]), .clear],
                                       center: [UnitPoint.leading, .trailing, .top, .bottom][index],
                                       startRadius: 0,
                                       endRadius: max(geometry.size.width, geometry.size.height) * (0.3 + min(1, max(0, spread))))
                    }
                }
            }
            .saturation(min(2, max(0, saturation)))
            .opacity(min(1, max(0, intensity)))
        }
        .background(AmbientWindowReader { window = $0 })
        .allowsHitTesting(false).accessibilityHidden(true)
        .onAppear { connect() }
        .onChange(of: configuration) { _, _ in connect() }
        .onChange(of: window) { _, _ in connect() }
        .onDisappear { controller.disconnect() }
    }
    private func connect() {
        controller.connect(player: player, window: window, enabled: active && dynamic && !reduceMotion,
                           frequency: frequency, smoothness: smoothness)
    }
}

/// Embed these sections in the existing macOS Settings form.
struct MacAppearanceSettingsView: View {
    @Environment(SettingsStore.self) private var store
    @AppStorage(AmbientPreference.opacity) private var opacity = 0.22
    @AppStorage(AmbientPreference.tint) private var tint = "system"
    @AppStorage(AmbientPreference.enabled) private var ambient = false
    @AppStorage(AmbientPreference.dynamic) private var dynamic = true
    @AppStorage(AmbientPreference.intensity) private var intensity = 0.35
    @AppStorage(AmbientPreference.spread) private var spread = 0.65
    @AppStorage(AmbientPreference.saturation) private var saturation = 1.0
    @AppStorage(AmbientPreference.frequency) private var frequency = 3.0
    @AppStorage(AmbientPreference.smoothness) private var smoothness = 0.8
    @AppStorage(AmbientPreference.red) private var staticRed = 0.15
    @AppStorage(AmbientPreference.green) private var staticGreen = 0.25
    @AppStorage(AmbientPreference.blue) private var staticBlue = 0.45
    var body: some View {
        @Bindable var store = store
        Section("Glass Appearance") {
            Toggle("Glass surfaces", isOn: $store.settings.glassEnabled)
            if store.settings.glassEnabled {
                slider("Glass intensity", value: $store.settings.glassIntensity, range: 0...1)
                slider("Surface opacity", value: $opacity, range: 0...1)
                slider("Tint strength", value: $store.settings.glassTintStrength, range: 0...1)
                Picker("Tint", selection: $tint) {
                    Text("System accent").tag("system")
                    Text("Neutral").tag("neutral")
                    Text("Ocean").tag("ocean")
                    Text("Violet").tag("violet")
                }
            }
        }
        Section("Ambient Light") {
            Toggle("Extend video colors into the background", isOn: $ambient)
            if ambient {
                Picker("Mode", selection: $dynamic) {
                    Text("Dynamic").tag(true)
                    Text("Static").tag(false)
                }
                ColorPicker("Static color", selection: staticColor, supportsOpacity: false)
                slider("Intensity", value: $intensity, range: 0...1)
                slider("Spread", value: $spread, range: 0...1)
                slider("Saturation", value: $saturation, range: 0...2)
                if dynamic {
                    Slider(value: $frequency, in: 2...5, step: 1) {
                        Text("Updates per second: \(Int(frequency))")
                    }
                    Slider(value: $smoothness, in: 0.1...3) {
                        Text("Smoothing: \(smoothness, specifier: "%.1f") seconds")
                    }
                }
                Text("Sampling pauses with playback and when the window is hidden or inactive. Static mode performs no frame sampling. Reduce Motion uses the selected static color; Reduce Transparency disables the glow.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var staticColor: Binding<Color> {
        Binding(get: { Color(red: staticRed, green: staticGreen, blue: staticBlue) }, set: { color in
            guard let rgb = NSColor(color).usingColorSpace(.deviceRGB) else { return }
            staticRed = rgb.redComponent
            staticGreen = rgb.greenComponent
            staticBlue = rgb.blueComponent
        })
    }
    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack { Text(title); Slider(value: value, in: range); Text("\(Int(value.wrappedValue * 100))%").monospacedDigit().frame(width: 48) }
    }
}
#endif
