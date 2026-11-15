#if os(macOS)
import AppKit
import ImageIO
import Observation
import SmartTubeIOSCore
import SwiftUI
import UniformTypeIdentifiers

/// Static wallpaper is decoded once, bounded to 2560px; there is no animation or timer.
@MainActor @Observable
final class MacPersonalAppearance {
    static let shared = MacPersonalAppearance()
    var image: NSImage?
    var error: String?
    private init() { reload() }
    func chooseWallpaper() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: "mactube.wallpaper.bookmark")
            reload()
        } catch { self.error = error.localizedDescription }
    }
    func reset() {
        UserDefaults.standard.removeObject(forKey: "mactube.wallpaper.bookmark")
        image = nil; error = nil
    }
    private func reload() {
        guard let data = UserDefaults.standard.data(forKey: "mactube.wallpaper.bookmark") else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2560,
                    kCGImageSourceCreateThumbnailWithTransform: true
                ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
            image = NSImage(cgImage: cg, size: .zero); error = nil
            if stale { UserDefaults.standard.set(try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil), forKey: "mactube.wallpaper.bookmark") }
        } catch { self.error = error.localizedDescription }
    }
}

struct MacWallpaper: View {
    @AppStorage("mactube.wallpaper.fill") private var fill = true
    @AppStorage("mactube.wallpaper.dimming") private var dimming = 0.0
    @AppStorage("mactube.wallpaper.opacity") private var opacity = 0.3
    @AppStorage("mactube.wallpaper.blur") private var blur = 0.0
    private let appearance = MacPersonalAppearance.shared
    var body: some View {
        if let image = appearance.image {
            GeometryReader { geometry in
                Image(nsImage: image).resizable()
                    .aspectRatio(contentMode: fill ? .fill : .fit)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .blur(radius: blur, opaque: true)
                    .opacity(opacity)
                    .overlay(Color.black.opacity(dimming))
                    .clipped()
            }.allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

struct MacPersonalAppearanceSettings: View {
    @AppStorage("mactube.appearance.palette") private var palette = "glass"
    @AppStorage("mactube.appearance.customAccent") private var customAccent = false
    @AppStorage("mactube.appearance.red") private var red = 0.4
    @AppStorage("mactube.appearance.green") private var green = 0.5
    @AppStorage("mactube.appearance.blue") private var blue = 1.0
    @AppStorage("mactube.wallpaper.fill") private var fill = true
    @AppStorage("mactube.wallpaper.dimming") private var dimming = 0.0
    @AppStorage("mactube.wallpaper.opacity") private var opacity = 0.3
    @AppStorage("mactube.wallpaper.blur") private var blur = 0.0
    @AppStorage("mactube.ui.refreshRate") private var refreshRate = "60"
    @State private var maximumRefresh = 0
    private let appearance = MacPersonalAppearance.shared
    var body: some View {
        Section("Appearance") {
            Picker("Color theme", selection: $palette) {
                Text("Glass (default)").tag("glass")
                Text("Dark").tag("dark")
                Text("Light").tag("light")
                Text("Midnight blue").tag("midnight")
                Text("Plum").tag("plum")
                Text("Forest").tag("forest")
            }
            Picker("UI refresh preference", selection: $refreshRate) {
                Text("60 Hz — Default").tag("60")
                Text("120 Hz — High Refresh").tag("120")
                Text("Match Display — Adaptive").tag("adaptive")
            }
            if maximumRefresh > 0 {
                Text("Active display capability: up to \(maximumRefresh) Hz. Requested presentation: \(refreshRate == "adaptive" ? maximumRefresh : min(Int(refreshRate) ?? 60, maximumRefresh)) Hz.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Native scrolling and animations synchronize with the active display. macOS controls SwiftUI’s actual cadence; this preference does not force redraws or alter video frame rates.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Custom accent color", isOn: $customAccent)
            if customAccent {
                ColorPicker("Accent", selection: Binding(get: { Color(red: red, green: green, blue: blue) }, set: { value in
                    guard let rgb = NSColor(value).usingColorSpace(.deviceRGB) else { return }
                    red = rgb.redComponent; green = rgb.greenComponent; blue = rgb.blueComponent
                }), supportsOpacity: false)
            }
            Button("Choose wallpaper…") { appearance.chooseWallpaper() }
            if appearance.image != nil {
                Picker("Wallpaper layout", selection: $fill) { Text("Fill").tag(true); Text("Fit").tag(false) }
                Slider(value: $opacity, in: 0...0.6) { Text("Wallpaper opacity") }
                Slider(value: $dimming, in: 0...0.8) { Text("Wallpaper dimming") }
                Slider(value: $blur, in: 0...24) { Text("Wallpaper blur") }
                Button("Reset wallpaper") { appearance.reset() }
            }
            if let error = appearance.error { Text(error).foregroundStyle(.secondary) }
        }
        .background(MacDisplayCapability(maximumRefresh: $maximumRefresh).frame(width: 0, height: 0))
    }
}

struct MacPersonalAppearanceModifier: ViewModifier {
    @Environment(SettingsStore.self) private var settings
    @AppStorage("mactube.appearance.palette") private var palette = "glass"
    @AppStorage("mactube.appearance.customAccent") private var customAccent = false
    @AppStorage("mactube.appearance.red") private var red = 0.4
    @AppStorage("mactube.appearance.green") private var green = 0.5
    @AppStorage("mactube.appearance.blue") private var blue = 1.0
    func body(content: Content) -> some View {
        content
            .preferredColorScheme(palette == "glass" ? nil : palette == "light" ? .light : .dark)
            .tint(accent)
            .accentColor(accent)
    }
    private var accent: Color {
        if customAccent { return Color(red: red, green: green, blue: blue) }
        switch palette {
        case "midnight": return .cyan
        case "plum": return .purple
        case "forest": return .green
        default: return settings.settings.accentColor.color ?? .accentColor
        }
    }
}
#endif
