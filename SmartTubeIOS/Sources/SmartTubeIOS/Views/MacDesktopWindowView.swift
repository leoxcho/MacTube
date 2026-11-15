#if os(macOS)
import AppKit
import Observation
import SmartTubeIOSCore
import SwiftUI

public struct MacDesktopWindowRequest: Codable, Hashable {
    public var id: UUID
    public var video: Video?
    public init(video: Video? = nil) { id = UUID(); self.video = video }
}

private struct MacHomeSectionKey: EnvironmentKey {
    static let defaultValue: Binding<BrowseSection>? = nil
}
extension EnvironmentValues {
    var macHomeSection: Binding<BrowseSection>? {
        get { self[MacHomeSectionKey.self] }
        set { self[MacHomeSectionKey.self] = newValue }
    }
}

private struct MacOpenVideoKey: EnvironmentKey {
    static let defaultValue: @MainActor (Video) -> Void = { _ in }
}
extension EnvironmentValues {
    var macOpenVideo: @MainActor (Video) -> Void {
        get { self[MacOpenVideoKey.self] }
        set { self[MacOpenVideoKey.self] = newValue }
    }
}
private struct MacOpenVideoInTabKey: EnvironmentKey {
    static let defaultValue: @MainActor (Video) -> Void = { _ in }
}
private struct MacOpenVideoInWindowKey: EnvironmentKey {
    static let defaultValue: @MainActor (Video) -> Void = { _ in }
}
extension EnvironmentValues {
    var macOpenVideoInTab: @MainActor (Video) -> Void {
        get { self[MacOpenVideoInTabKey.self] }
        set { self[MacOpenVideoInTabKey.self] = newValue }
    }
    var macOpenVideoInWindow: @MainActor (Video) -> Void {
        get { self[MacOpenVideoInWindowKey.self] }
        set { self[MacOpenVideoInWindowKey.self] = newValue }
    }
}

struct MacDesktopFullscreenKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

struct MacNavigationRoute: Codable, Equatable, Hashable {
    var section: String = "home"
    var query: String = ""
    var video: Video?
    var localFileURL: URL?
    var playlistID: String?
    var playlistTitle: String?
    init(section: String = "home", query: String = "", video: Video? = nil) {
        self.section = section; self.query = query; self.video = video
        localFileURL = video?.localFileURL
    }
    private enum CodingKeys: String, CodingKey { case section, query, video, localFileURL, playlistID, playlistTitle }
    func hash(into hasher: inout Hasher) {
        hasher.combine(section); hasher.combine(query); hasher.combine(video?.id)
        hasher.combine(localFileURL); hasher.combine(playlistID); hasher.combine(playlistTitle)
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        section = try values.decode(String.self, forKey: .section)
        query = try values.decode(String.self, forKey: .query)
        video = try values.decodeIfPresent(Video.self, forKey: .video)
        localFileURL = try values.decodeIfPresent(URL.self, forKey: .localFileURL)
        video?.localFileURL = localFileURL
        playlistID = try values.decodeIfPresent(String.self, forKey: .playlistID)
        playlistTitle = try values.decodeIfPresent(String.self, forKey: .playlistTitle)
    }
}

/// Navigation descriptors survive view teardown; inactive tabs own no view tree.
@MainActor @Observable
final class MacDesktopTabState: Identifiable {
    let id: UUID
    var routes: [MacNavigationRoute]
    var cursor: Int
    var scrollAnchors: [String: String] = [:]
    let search: SearchViewModel
    let browse: BrowseViewModel
    var route: MacNavigationRoute { routes[cursor] }
    var title: String {
        if let video = route.video { return video.title }
        if let playlistTitle = route.playlistTitle { return playlistTitle }
        if route.section.hasPrefix("local:"), let id = UUID(uuidString: String(route.section.dropFirst(6))) {
            return MacCustomLibraryStore.shared.libraries.first { $0.id == id }?.name ?? "Media Library"
        }
        switch route.section {
        case "search": return route.query
        case "watchLater": return "Watch Later"
        case "offlinePlaylists": return "Offline Playlists"
        default: return route.section.capitalized
        }
    }
    init(api: InnerTubeAPI, snapshot: MacTabSnapshot? = nil, video: Video? = nil) {
        id = snapshot?.id ?? UUID()
        let initialRoutes = snapshot?.routes.isEmpty == false ? snapshot!.routes : [MacNavigationRoute(video: video)]
        routes = initialRoutes
        cursor = min(max(snapshot?.cursor ?? 0, 0), initialRoutes.count - 1)
        scrollAnchors = snapshot?.scrollAnchors ?? [:]
        search = SearchViewModel(api: api)
        browse = BrowseViewModel(api: api)
        search.query = route.query
    }
    func navigate(_ route: MacNavigationRoute) {
        guard route != self.route else { return }
        routes = Array(routes.prefix(cursor + 1))
        routes.append(route)
        if routes.count > 60 { routes.removeFirst() }
        cursor = routes.count - 1
    }
    /// This is the actual SwiftUI stack path, not a second presentation flag.
    var navigationPath: [MacNavigationRoute] {
        get { Array(routes.prefix(cursor + 1).dropFirst()) }
        set {
            let visible = navigationPath
            guard newValue != visible else { return }
            if newValue.count <= visible.count, Array(visible.prefix(newValue.count)) == newValue {
                cursor = newValue.count // Native Back preserves forward history.
            } else {
                routes = [routes[0]] + newValue
                cursor = routes.count - 1
            }
        }
    }
    func showPlaylist(id: String, title: String) {
        var next = MacNavigationRoute(section: route.section, query: route.query)
        next.playlistID = id; next.playlistTitle = title
        navigate(next)
    }
    func showWatch(_ video: Video) {
        var next = route
        next.video = video; next.localFileURL = video.localFileURL
        if route.video != nil { routes[cursor] = next }
        else { navigate(next) }
    }
    func invalidateLibrary(_ id: UUID) {
        let section = "local:" + id.uuidString
        // Keep an active watch route and shared playback; remove only its stale
        // browsing origin. Sanitizing history also protects inactive/restored tabs.
        routes = routes.map { route in
            guard route.section == section else { return route }
            var valid = route; valid.section = "home"
            return valid
        }
        scrollAnchors.removeValue(forKey: section)
    }
    func updateSearchQuery(_ query: String) {
        guard route.section == "search", route.video == nil else { return }
        routes[cursor].query = query
    }
    func move(_ offset: Int) {
        cursor = min(max(cursor + offset, 0), routes.count - 1)
        search.query = route.query
        if route.section == "search", !route.query.isEmpty { search.search() }
    }
    var snapshot: MacTabSnapshot { MacTabSnapshot(id: id, routes: routes, cursor: cursor, scrollAnchors: scrollAnchors) }
}
struct MacTabSnapshot: Codable {
    var id: UUID
    var routes: [MacNavigationRoute]
    var cursor: Int
    var scrollAnchors: [String: String]
}
private struct MacWindowSnapshot: Codable {
    var tabs: [MacTabSnapshot]
    var selected: UUID?
}
private struct MacNavigationStateKey: EnvironmentKey {
    static let defaultValue: MacDesktopTabState? = nil
}
extension EnvironmentValues {
    var macNavigationState: MacDesktopTabState? {
        get { self[MacNavigationStateKey.self] }
        set { self[MacNavigationStateKey.self] = newValue }
    }
}
private struct DesktopActions {
    var newTab: () -> Void
    var closeTab: () -> Void
    var switchTab: (Int) -> Void
    var selectTab: (Int) -> Void
}
private struct DesktopActionsKey: FocusedValueKey { typealias Value = DesktopActions }
private extension FocusedValues {
    var desktopActions: DesktopActions? {
        get { self[DesktopActionsKey.self] }
        set { self[DesktopActionsKey.self] = newValue }
    }
}

public struct MacDesktopCommands: Commands {
    @FocusedValue(\.desktopActions) private var actions
    @Environment(\.openWindow) private var openWindow
    public init() {}
    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") { openWindow(id: "main", value: MacDesktopWindowRequest()) }
                .keyboardShortcut("n")
            Button("New Tab") { actions?.newTab() }.disabled(actions == nil)
        }
        CommandGroup(replacing: .windowArrangement) {
            Button("Close Tab") { actions?.closeTab() }.disabled(actions == nil)
            Button("Next Tab") { actions?.switchTab(1) }
            Button("Previous Tab") { actions?.switchTab(-1) }
            ForEach(1...9, id: \.self) { index in
                Button("Select Tab \(index)") { actions?.selectTab(index - 1) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index))))
            }
        }
    }
}

@MainActor
enum MacDesktopLifetime {
    static var windows: Set<UUID> = []
    static var hasOpenWindows: Bool { !windows.isEmpty }
}

struct MacDesktopWindowView: View {
    let initialVideo: Video?
    @Environment(\.innerTubeAPI) private var api
    @Environment(\.openWindow) private var openWindow
    @Environment(BrowseViewModel.self) private var appBrowse
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(AuthService.self) private var auth
    @Environment(SettingsStore.self) private var settings
    @State private var tabs: [MacDesktopTabState] = []
    @SceneStorage("MacTube.desktop.navigation.v1") private var savedNavigation = ""
    @State private var selectedID: UUID?
    @State private var draggedID: UUID?
    @State private var videoFullscreen = false
    @State private var windowID = UUID()
    private let session = MacPlaybackSession.shared
    private var selected: MacDesktopTabState? { tabs.first { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            if !videoFullscreen && tabs.count > 1 {
            HStack(spacing: 4) {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(tabs) { tab in
                            HStack(spacing: 8) {
                                Button { selectedID = tab.id } label: {
                                    Text(tab.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain)
                                Button { close(tab.id) } label: { Image(systemName: "xmark").font(.caption) }
                                    .buttonStyle(.plain).help("Close tab")
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8).frame(width: 210)
                            .background(selectedID == tab.id ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                            .onDrag { draggedID = tab.id; return NSItemProvider(object: tab.id.uuidString as NSString) }
                            .onDrop(of: [.text], isTargeted: nil) { _ in
                                guard let source = draggedID, source != tab.id,
                                      let from = tabs.firstIndex(where: { $0.id == source }),
                                      let to = tabs.firstIndex(where: { $0.id == tab.id }) else { return false }
                                tabs.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
                                draggedID = nil
                                return true
                            }
                        }
                    }
                }
                Button { add() } label: { Image(systemName: "plus") }.buttonStyle(.plain).padding(10).help("New tab (⌘T)")
            }.padding(6)
            Divider()
            }
            ZStack(alignment: .bottomTrailing) {
                if let tab = selected {
                    MainSidebarView(tab: tab)
                        .id(tab.id)
                        .environment(tab.browse)
                        .environment(\.macNavigationState, tab)
                        .task {
                            tab.browse.configureSections(settings.settings.enabledSections)
                            tab.browse.updateHistoryEnabled(settings.settings.historyState == .enabled)
                            await tab.browse.updateAuthToken(auth.accessToken)
                        }
                }
                if session.currentVideo != nil, selected?.route.section != "shorts", selected?.route.video?.id != session.currentVideo?.id {
                    MacMiniPlayer(session: session) {
                        if let video = session.currentVideo { selected?.showWatch(video) }
                    }.padding(16)
                }
            }
        }
        .task(id: controlActiveState == .key) {
            guard controlActiveState == .key else { return }
            for await notification in NotificationCenter.default.notifications(named: .macRestoreNativePictureInPicture) {
                guard !Task.isCancelled else { return }
                guard let video = session.currentVideo else { continue }
                selected?.showWatch(video)
            }
        }
        .onChange(of: session.currentVideo?.id) { _, _ in
            // Queue changes replace the watch route without building a second
            // session or moving a browsing tab away from its current destination.
            guard controlActiveState == .key, let tab = selected,
                  tab.route.video != nil, let video = session.currentVideo else { return }
            var route = tab.route
            route.video = video
            route.localFileURL = video.localFileURL
            tab.routes[tab.cursor] = route
        }
        .onPreferenceChange(MacDesktopFullscreenKey.self) { videoFullscreen = $0 }
        .toolbar(videoFullscreen ? .hidden : .visible, for: .windowToolbar)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .background(MacWindowGlassChrome())
        .background(MacInputHost(handle: handleInput).frame(width: 0, height: 0))
        .environment(\.macOpenVideoInTab, { video in add(video: video) })
        .environment(\.macOpenVideoInWindow, { video in openWindow(id: "main", value: MacDesktopWindowRequest(video: video)) })
        .focusedSceneValue(\.desktopActions, DesktopActions(newTab: { add() }, closeTab: {
            if let selectedID { close(selectedID) }
        }, switchTab: switchTab, selectTab: { index in
            guard !tabs.isEmpty else { return }
            selectedID = tabs[min(index, tabs.count - 1)].id
        }))
        .navigationTitle(selected?.title ?? "MacTube")
        .onAppear {
            MacDesktopLifetime.windows.insert(windowID)
            MacYTDLPUpdateLifecycle.start()
            MacMusicLibraryStore.shared.prepareIfNeeded()
            MacCustomLibraryStore.shared.registerRemovalHandler(owner: windowID) { id in
                for tab in tabs { tab.invalidateLibrary(id) }
            }
            if tabs.isEmpty {
                if initialVideo == nil, appBrowse.deepLinkedVideo == nil,
                   let data = savedNavigation.data(using: .utf8),
                   let snapshot = try? JSONDecoder().decode(MacWindowSnapshot.self, from: data) {
                    tabs = snapshot.tabs.prefix(12).map { MacDesktopTabState(api: api, snapshot: $0) }
                    selectedID = tabs.contains(where: { $0.id == snapshot.selected }) ? snapshot.selected : tabs.first?.id
                }
                if tabs.isEmpty { add(video: initialVideo ?? appBrowse.deepLinkedVideo) }
                if initialVideo == nil { appBrowse.deepLinkedVideo = nil }
            }
        }
        .onChange(of: snapshotData) { _, data in savedNavigation = data }
        .onDisappear {
            savedNavigation = snapshotData
            MacDesktopLifetime.windows.remove(windowID)
            MacCustomLibraryStore.shared.unregisterRemovalHandler(owner: windowID)
            if MacDesktopLifetime.windows.isEmpty && !MacNativePlayerView.isPictureInPictureActive { session.stop() }
        }
        .onChange(of: appBrowse.deepLinkedVideo?.id) { _, _ in
            guard controlActiveState == .key, let video = appBrowse.deepLinkedVideo else { return }
            beginPlayback(video)
            selected?.showWatch(video)
            appBrowse.deepLinkedVideo = nil
        }
    }
    private func handleInput(_ action: MacInputAction) -> Bool {
        switch action {
        case .newTab: add()
        case .closeTab: if let selectedID { close(selectedID) }
        case .nextTab: switchTab(1)
        case .previousTab: switchTab(-1)
        case .fullscreen, .theater:
            // A mini-player can restore its watch route using the same session.
            guard selected?.route.video == nil, let video = session.currentVideo else { return false }
            MacInputDispatcher.shared.requestPresentation(action, window: NSApp.keyWindow)
            selected?.showWatch(video)
        case .speedUp, .speedDown:
            guard selected?.route.video == nil, let vm = session.activeModel else { return false }
            let speed = min(2, max(0.25, vm.settings.playbackSpeed + (action == .speedUp ? 0.25 : -0.25)))
            settings.settings.playbackSpeed = speed
            vm.setPlaybackSpeed(speed)
        default: return false
        }
        return true
    }
    private var snapshotData: String {
        guard let data = try? JSONEncoder().encode(MacWindowSnapshot(tabs: tabs.map(\.snapshot), selected: selectedID)) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    private func beginPlayback(_ video: Video) {
        let vm = session.vm(for: api)
        vm.updateSettings(settings.settings)
        vm.updateAuthToken(auth.accessToken)
        vm.updateSAPISID(auth.sapisid)
        session.play(video: video, api: api)
    }
    private func add(video: Video? = nil) {
        if let video { beginPlayback(video) }
        let tab = MacDesktopTabState(api: api, video: video)
        tabs.append(tab); selectedID = tab.id
    }
    private func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs.count == 1 { NSApp.keyWindow?.performClose(nil); return }
        tabs.remove(at: index)
        if selectedID == id { selectedID = tabs[min(index, tabs.count - 1)].id }
    }
    private func switchTab(_ offset: Int) {
        guard !tabs.isEmpty, let index = tabs.firstIndex(where: { $0.id == selectedID }) else { return }
        selectedID = tabs[(index + offset + tabs.count) % tabs.count].id
    }
}
#endif
