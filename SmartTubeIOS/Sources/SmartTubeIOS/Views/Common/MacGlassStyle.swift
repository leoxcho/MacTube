#if os(macOS)
import AppKit
import SwiftUI

private func macGlassTint(_ selection: String) -> Color {
    switch selection {
    case "neutral": .gray
    case "ocean": .cyan
    case "violet": .indigo
    default: .accentColor
    }
}

struct MacGlassBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("mactube.glass.tint") private var tint = "system"
    @AppStorage("mactube.appearance.palette") private var palette = "glass"
    @Environment(SettingsStore.self) private var store
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            switch palette {
            case "midnight": Color.blue.opacity(0.10)
            case "plum": Color.purple.opacity(0.10)
            case "forest": Color.green.opacity(0.10)
            default: Color.clear
            }
            MacWallpaper()
            if store.settings.glassEnabled && !reduceTransparency {
                LinearGradient(
                    colors: [
                        macGlassTint(tint).opacity(scheme == .dark ? 0.12 : 0.06), .clear,
                        macGlassTint(tint).opacity(scheme == .dark ? 0.16 : 0.08),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .opacity(store.settings.glassTintStrength * store.settings.glassIntensity * 2)
            }
        }.ignoresSafeArea().allowsHitTesting(false)
    }
}

private struct MacGlassSurface: ViewModifier {
    var radius: CGFloat
    var bordered = true
    @AppStorage("mactube.glass.opacity") private var opacity = 0.22
    @AppStorage("mactube.glass.tint") private var tint = "system"
    @Environment(SettingsStore.self) private var store
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content
            .background {
                let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
                if reduceTransparency || !store.settings.glassEnabled {
                    shape.fill(Color(nsColor: .controlBackgroundColor))
                } else {
                    shape.fill(.regularMaterial)
                        .overlay(
                            shape.fill(
                                Color(nsColor: .controlBackgroundColor).opacity(max(min(1, max(0, opacity)), 1 - store.settings.glassIntensity))))
                        .overlay(shape.fill(macGlassTint(tint).opacity(store.settings.glassTintStrength * 0.06)))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(
                                    store.settings.glassEnabled && !reduceTransparency ? 0.12 * store.settings.glassIntensity : 0.06),
                                .white.opacity(0.06),
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: bordered ? 0.45 : 0
                    )
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(store.settings.glassEnabled && !reduceTransparency ? 0.06 : 0.02), radius: 8, x: 0, y: 3)
    }
}

extension View {
    func macGlassSurface(radius: CGFloat = 18, bordered: Bool = true) -> some View { modifier(MacGlassSurface(radius: radius, bordered: bordered)) }
    func macMediaCard() -> some View { modifier(MacMediaCard()) }
    func macWallpaperSurface() -> some View {
        scrollContentBackground(.hidden).background(MacGlassBackdrop())
    }
}

/// Hover is a transient compositor transform: it never changes layout or starts media work.
private struct MacMediaCard: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    func body(content: Content) -> some View {
        content.macGlassSurface(radius: 12)
            .scaleEffect(hovered && !reduceMotion ? 1.035 : 1)
            .zIndex(hovered ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hovered)
            .onHover { hovered = $0 }
            .onDisappear { hovered = false }
    }
}

struct MacGlassButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 9)
            .macGlassSurface(radius: 22)
            .overlay(Capsule().fill(.white.opacity(configuration.isPressed ? 0.14 : 0)))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}
enum MacGlassAccessibility {
    static let enabled = "settings.glass.enabled"
    static let intensity = "settings.glass.intensity"
    static let tint = "settings.glass.tint"
}
#endif
