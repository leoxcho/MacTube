#if os(macOS)
import AppKit
import Observation
import SmartTubeIOSCore
import SwiftUI

/// Navigation and presentation callbacks resolve against the event's own window.
enum MacInputAction: String, CaseIterable, Codable, Identifiable {
    case back, forward, home, subscriptions, searchFocus, history, downloads, music
    case previousTab, nextTab, newTab, closeTab, toggleSidebar
    case playPause, seekBackward, seekForward, seekBackwardSmall, seekForwardSmall
    case volumeUp, volumeDown, mute, previousVideo, nextVideo, captions
    case speedUp, speedDown, fullscreen, exitFullscreen, theater, miniPlayer, loop
    case seek0, seek1, seek2, seek3, seek4, seek5, seek6, seek7, seek8, seek9
    var id: String { rawValue }
    var title: String {
        switch self {
        case .back: "Back"
        case .forward: "Forward"
        case .home: "Home"
        case .subscriptions: "Subscriptions"
        case .searchFocus: "Focus Search"
        case .history: "History"
        case .downloads: "Downloads"
        case .music: "Music"
        case .previousTab: "Previous Tab"
        case .nextTab: "Next Tab"
        case .newTab: "New Tab"
        case .closeTab: "Close Tab"
        case .toggleSidebar: "Toggle Sidebar"
        case .playPause: "Play / Pause"
        case .seekBackward: "Seek Backward 10 Seconds"
        case .seekForward: "Seek Forward 10 Seconds"
        case .seekBackwardSmall: "Seek Backward 5 Seconds"
        case .seekForwardSmall: "Seek Forward 5 Seconds"
        case .volumeUp: "Volume Up"
        case .volumeDown: "Volume Down"
        case .mute: "Mute"
        case .previousVideo: "Previous Video"
        case .nextVideo: "Next Video"
        case .captions: "Toggle Captions"
        case .speedUp: "Playback Speed Up"
        case .speedDown: "Playback Speed Down"
        case .fullscreen: "Toggle Fullscreen"
        case .exitFullscreen: "Exit Fullscreen"
        case .theater: "Theater Mode"
        case .miniPlayer: "Mini-player"
        case .loop: "Loop Current Video"
        default: "Seek to \(rawValue.replacingOccurrences(of: "seek", with: ""))0%"
        }
    }
}

struct MacInputBinding: Codable, Equatable {
    var mouse: Bool
    var code: Int
    var modifiers: UInt
    var label: String
    static func key(_ code: Int, _ label: String, _ flags: NSEvent.ModifierFlags = []) -> Self {
        Self(mouse: false, code: code, modifiers: flags.rawValue, label: label)
    }
    static func button(_ code: Int) -> Self { Self(mouse: true, code: code, modifiers: 0, label: "Mouse Button \(code + 1)") }
    var display: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        return (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + label
    }
    func matches(_ other: Self) -> Bool { mouse == other.mouse && code == other.code && modifiers == other.modifiers }
    init(event: NSEvent) {
        mouse = event.type == .otherMouseDown
        code = mouse ? event.buttonNumber : Int(event.keyCode)
        modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift]).rawValue
        let names = [49: "Space", 53: "Escape", 123: "←", 124: "→", 125: "↓", 126: "↑", 48: "Tab", 36: "Return", 51: "Delete"]
        label = mouse ? "Mouse Button \(code + 1)" : names[code] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(code)"
    }
    init(mouse: Bool, code: Int, modifiers: UInt, label: String) {
        self.mouse = mouse; self.code = code; self.modifiers = modifiers; self.label = label
    }
}

@MainActor @Observable
final class MacInputBindings {
    static let shared = MacInputBindings()
    private(set) var bindings: [String: [MacInputBinding]]
    var recording: MacInputAction?
    var pending: MacInputBinding?
    var message: String?
    private static let storageKey = "mactube.controls.bindings.v1"
    static var defaults: [String: [MacInputBinding]] {
        var result: [String: [MacInputBinding]] = [
            "back": [.key(33, "[", .command), .button(3)], "forward": [.key(30, "]", .command), .button(4)],
            "searchFocus": [.key(3, "F", .command), .key(37, "L", .command)], "newTab": [.key(17, "T", .command)],
            "closeTab": [.key(13, "W", .command)], "previousTab": [.key(123, "←", [.command, .option]), .key(33, "[", [.command, .shift]), .key(48, "Tab", [.control, .shift])],
            "nextTab": [.key(124, "→", [.command, .option]), .key(30, "]", [.command, .shift]), .key(48, "Tab", .control)], "toggleSidebar": [.key(1, "S", [.command, .control])],
            "playPause": [.key(40, "K"), .key(49, "Space")], "seekBackward": [.key(38, "J")], "seekForward": [.key(37, "L")],
            "seekBackwardSmall": [.key(123, "←")], "seekForwardSmall": [.key(124, "→")],
            "volumeDown": [.key(125, "↓")], "volumeUp": [.key(126, "↑")], "mute": [.key(46, "M")],
            "previousVideo": [.key(35, "P", .shift)], "nextVideo": [.key(45, "N", .shift)],
            "captions": [.key(8, "C")], "speedDown": [.key(43, ","), .key(43, ",", .shift)],
            "speedUp": [.key(47, "."), .key(47, ".", .shift)], "fullscreen": [.key(3, "F")],
            "exitFullscreen": [.key(53, "Escape")], "theater": [.key(17, "T")], "miniPlayer": [.key(34, "I")]
        ]
        for (digit, code) in [29,18,19,20,21,23,22,26,28,25].enumerated() { result["seek\(digit)"] = [.key(code, String(digit))] }
        return result
    }
    private init() {
        bindings = UserDefaults.standard.data(forKey: Self.storageKey).flatMap { try? JSONDecoder().decode([String: [MacInputBinding]].self, from: $0) } ?? Self.defaults
    }
    func assigned(_ action: MacInputAction) -> [MacInputBinding] { bindings[action.rawValue] ?? [] }
    func action(for binding: MacInputBinding) -> MacInputAction? {
        MacInputAction.allCases.first { assigned($0).contains { $0.matches(binding) } }
    }
    func begin(_ action: MacInputAction) { recording = action; pending = nil; message = nil }
    func cancel() { recording = nil; pending = nil; message = nil }
    func capture(_ binding: MacInputBinding) {
        pending = binding
        message = reservation(binding)
        if message == nil, let conflict = action(for: binding), conflict != recording { message = "Already assigned to \(conflict.title). Clear that binding or choose Replace Conflict." }
    }
    func save(replacing: Bool = false) {
        guard let action = recording, let pending, reservation(pending) == nil else { return }
        let conflicts = MacInputAction.allCases.filter { $0 != action && assigned($0).contains { $0.matches(pending) } }
        guard replacing || conflicts.isEmpty else { return }
        for conflict in conflicts { bindings[conflict.rawValue]?.removeAll { $0.matches(pending) } }
        // Keyboard and mouse are independent bindings for the same action.
        bindings[action.rawValue] = assigned(action).filter { $0.mouse != pending.mouse } + [pending]
        persist(); cancel()
    }
    func clear(_ binding: MacInputBinding, for action: MacInputAction) {
        bindings[action.rawValue]?.removeAll { $0.matches(binding) }; persist()
    }
    func clear(_ action: MacInputAction) { bindings[action.rawValue] = []; persist() }
    func restore(_ action: MacInputAction) {
        let defaults = Self.defaults[action.rawValue] ?? []
        if let conflict = MacInputAction.allCases.first(where: { other in other != action && assigned(other).contains { binding in defaults.contains { $0.matches(binding) } } }) {
            message = "Clear the conflicting binding on \(conflict.title) before restoring this default."; return
        }
        bindings[action.rawValue] = defaults; persist(); message = nil
    }
    func reset() { bindings = Self.defaults; persist(); cancel() }
    private func persist() { if let data = try? JSONEncoder().encode(bindings) { UserDefaults.standard.set(data, forKey: Self.storageKey) } }
    func reservation(_ binding: MacInputBinding) -> String? {
        guard !binding.mouse else { return binding.code < 2 ? "Left and right clicks are reserved for normal interaction." : nil }
        let flags = NSEvent.ModifierFlags(rawValue: binding.modifiers)
        if flags.contains(.command), [12,4,46,49].contains(binding.code) { return "This combination is reserved by macOS (Quit, Hide, Minimize or Spotlight)." }
        if flags.contains(.control), binding.code == 49 { return "This combination is reserved for macOS input sources." }
        if flags.contains([.command, .option]), binding.code == 53 { return "Force Quit is reserved by macOS." }
        if flags.contains(.command), [0,6,7,8,9].contains(binding.code) { return "Standard editing shortcuts remain reserved for editing." }
        return nil
    }
}

@MainActor
final class MacInputDispatcher {
    static let shared = MacInputDispatcher()
    private var monitor: Any?
    private var handlers: [ObjectIdentifier: (MacInputAction) -> Bool] = [:]
    private var presentations: [ObjectIdentifier: (MacInputAction) -> Bool] = [:]
    private var pendingPresentation: [ObjectIdentifier: MacInputAction] = [:]
    func requestPresentation(_ action: MacInputAction, window: NSWindow?) {
        if let window { pendingPresentation[ObjectIdentifier(window)] = action }
    }
    private var feedWindows = Set<ObjectIdentifier>()
    func setFeedNavigation(window: NSWindow, enabled: Bool) {
        if enabled { feedWindows.insert(ObjectIdentifier(window)) } else { feedWindows.remove(ObjectIdentifier(window)) }
    }
    private var navigationHandlers: [ObjectIdentifier: (MacInputAction) -> Bool] = [:]
    func navigation(window: NSWindow, handle: @escaping (MacInputAction) -> Bool) { navigationHandlers[ObjectIdentifier(window)] = handle }
    func removeNavigation(window: NSWindow) { navigationHandlers.removeValue(forKey: ObjectIdentifier(window)); feedWindows.remove(ObjectIdentifier(window)) }
    func register(window: NSWindow, handle: @escaping (MacInputAction) -> Bool) {
        handlers[ObjectIdentifier(window)] = handle
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .otherMouseDown]) { [weak self] event in
                guard let self else { return event }
                return self.handle(event) ? nil : event
            }
        }
    }
    func unregister(window: NSWindow) {
        handlers.removeValue(forKey: ObjectIdentifier(window))
        pendingPresentation.removeValue(forKey: ObjectIdentifier(window))
    }
    func presentation(window: NSWindow, handle: @escaping (MacInputAction) -> Bool) {
        presentations[ObjectIdentifier(window)] = handle
        if let pending = pendingPresentation.removeValue(forKey: ObjectIdentifier(window)) {
            let key = ObjectIdentifier(window)
            Task { @MainActor [weak self, weak window] in
                guard let self, window?.isKeyWindow == true else { return }
                _ = self.presentations[key]?(pending)
            }
        }
    }
    func removePresentation(window: NSWindow) { presentations.removeValue(forKey: ObjectIdentifier(window)) }
    private func handle(_ event: NSEvent) -> Bool {
        guard NSApp.isActive, let window = event.window ?? NSApp.keyWindow, window.isKeyWindow else { return false }
        if event.type == .otherMouseDown, event.buttonNumber < 2 { return false }
        let store = MacInputBindings.shared
        if store.recording != nil { store.capture(MacInputBinding(event: event)); return true }
        guard window.attachedSheet == nil, let action = store.action(for: MacInputBinding(event: event)) else { return false }
        // Preserve native Shorts paging when these keys still have their
        // original defaults; an explicitly rebound action takes precedence.
        if feedWindows.contains(ObjectIdentifier(window)), event.type == .keyDown,
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           [125, 126, 49].contains(Int(event.keyCode)),
           MacInputBindings.defaults[action.rawValue]?.contains(where: { $0.matches(MacInputBinding(event: event)) }) == true {
            return false
        }
        let editing = (window.firstResponder as? NSTextView)?.isEditable == true || (window.firstResponder as? NSTextField)?.isEditable == true
        if editing {
            let commands: Set<MacInputAction> = [.back, .forward, .searchFocus, .newTab, .closeTab, .previousTab, .nextTab]
            guard event.modifierFlags.contains(.command), commands.contains(action) else { return false }
        }
        return dispatch(action, window: window)
    }
    @discardableResult func dispatch(_ action: MacInputAction, window: NSWindow? = NSApp.keyWindow) -> Bool {
        guard let window, let handle = handlers[ObjectIdentifier(window)] else { return false }
        if handle(action) { return true }
        if navigationHandlers[ObjectIdentifier(window)]?(action) == true { return true }
        if presentations[ObjectIdentifier(window)]?(action) == true { return true }
        return performPlayback(action)
    }
    @discardableResult func performPlayback(_ action: MacInputAction) -> Bool {
        guard let vm = MacPlaybackSession.shared.activeModel, vm.currentVideo != nil else { return false }
        switch action {
        case .playPause: vm.togglePlayPause()
        case .seekBackward: vm.seekRelative(seconds: -10)
        case .seekForward: vm.seekRelative(seconds: 10)
        case .seekBackwardSmall: vm.seekRelative(seconds: -5)
        case .seekForwardSmall: vm.seekRelative(seconds: 5)
        case .volumeUp: vm.player.volume = min(1, vm.player.volume + 0.05); vm.player.isMuted = false
        case .volumeDown: vm.player.volume = max(0, vm.player.volume - 0.05)
        case .mute: vm.player.isMuted.toggle()
        case .previousVideo: vm.playPrevious()
        case .nextVideo: vm.playNext()
        case .captions: vm.selectCaption(vm.selectedCaption == nil ? vm.availableCaptions.first : nil)
        case .speedUp, .speedDown:
            let speed = min(2, max(0.25, vm.settings.playbackSpeed + (action == .speedUp ? 0.25 : -0.25)))
            vm.setPlaybackSpeed(speed)
        case .loop: vm.setCurrentVideoLooping(!vm.isCurrentVideoLooping)
        default:
            guard action.rawValue.hasPrefix("seek"), let digit = Int(action.rawValue.dropFirst(4)), vm.duration > 0, !vm.isLivePlayback else { return false }
            vm.seek(to: vm.duration * Double(digit) / 10)
        }
        vm.showControls(); return true
    }
}

/// The sole monitor lives in the dispatcher; each window registers only a callback.
struct MacInputHost: NSViewRepresentable {
    let handle: (MacInputAction) -> Bool
    var navigationOnly = false
    var preserveFeedKeys = false
    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ view: Host, context: Context) { view.handle = handle; view.navigationOnly = navigationOnly; view.preserveFeedKeys = preserveFeedKeys; view.register() }
    static func dismantleNSView(_ view: Host, coordinator: ()) { view.stop() }
    @MainActor final class Host: NSView {
        var handle: ((MacInputAction) -> Bool)?
        var navigationOnly = false
        var preserveFeedKeys = false
        weak var registeredWindow: NSWindow?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); stop(); register() }
        func register() {
            guard let window else { return }
            registeredWindow = window
            if navigationOnly {
                MacInputDispatcher.shared.setFeedNavigation(window: window, enabled: preserveFeedKeys)
                MacInputDispatcher.shared.navigation(window: window) { [weak self] in self?.handle?($0) ?? false }
            } else {
                MacInputDispatcher.shared.register(window: window) { [weak self] in self?.handle?($0) ?? false }
            }
        }
        func stop() {
            if let registeredWindow {
                if navigationOnly { MacInputDispatcher.shared.removeNavigation(window: registeredWindow) }
                else { MacInputDispatcher.shared.unregister(window: registeredWindow) }
            }
            registeredWindow = nil
        }
    }
}
#endif
