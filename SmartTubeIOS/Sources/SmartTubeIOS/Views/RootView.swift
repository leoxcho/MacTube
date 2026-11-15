import OSLog
import SmartTubeIOSCore
import SwiftUI

private let rootLog = Logger(subsystem: "com.void.smarttube.app", category: "RootView")

// MARK: - RootView
//
// Entry point that decides whether to show the main tab UI or the
// sign-in screen.  On macOS it uses a sidebar-based navigation.

public struct RootView: View {
    @Environment(AuthService.self) private var auth
    @Environment(SettingsStore.self) private var store
    @Environment(BrowseViewModel.self) private var browseVM
    @Environment(\.innerTubeAPI) private var api
    /// Shared download service — observed here so the completion alert is shown
    /// at a stable level unaffected by context menu dismiss animations on cards.
    #if ENABLE_DOWNLOADS
    @Environment(VideoDownloadService.self) private var cardDownloadService
    #endif
    @State private var cardDownloadAlertItem: DownloadAlertItem?
    @State private var isLandscapeLayout = false

    private var initialDesktopVideo: Video?
    public init(initialDesktopVideo: Video? = nil) { self.initialDesktopVideo = initialDesktopVideo }

    public var body: some View {
        @Bindable var browseVM = browseVM
        // Explicitly read cardDownloadService.state in body so SwiftUI's
        // @Observable tracking engine registers this view as a subscriber.
        // Without this, onChange(of: cardDownloadService.state) may not fire
        // when the state changes on an environment-injected @Observable object.
        #if ENABLE_DOWNLOADS
        let _ = cardDownloadService.state
        #endif
        Group {
            #if os(tvOS)
            MainTVTabView()
            #elseif os(macOS)
            MacDesktopWindowView(initialVideo: initialDesktopVideo)
            #else
            MainTabView()
            #endif
        }
        .environment(\.isLandscapeLayout, isLandscapeLayout)
        .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: { isLandscapeLayout = $0 }
        .tint(store.settings.accentColor.color)
        .preferredColorScheme(store.settings.themeName.colorScheme)
        #if os(macOS)
        .modifier(MacPersonalAppearanceModifier())
        #endif
        #if !os(tvOS) && ENABLE_DOWNLOADS
        .onChange(of: cardDownloadService.state) { _, newState in
            switch newState {
            case .done:
                cardDownloadAlertItem = DownloadAlertItem(
                    title: String(localized: "Saved to Gallery", bundle: .module),
                    message: String(localized: "Video has been saved to your Photos library.", bundle: .module)
                )
                cardDownloadService.reset()
            case .failed(let reason):
                cardDownloadAlertItem = DownloadAlertItem(
                    title: String(localized: "Download Failed", bundle: .module),
                    message: reason
                )
                cardDownloadService.reset()
            default:
                break
            }
        }
        .alert(
            cardDownloadAlertItem?.title ?? "",
            isPresented: Binding(
                get: { cardDownloadAlertItem != nil },
                set: { if !$0 { cardDownloadAlertItem = nil } }
            ),
            presenting: cardDownloadAlertItem
        ) { _ in
            Button("OK") { cardDownloadAlertItem = nil }
        } message: { item in
            Text(item.message)
        }
        #endif
        .sheet(isPresented: .constant(!auth.isSignedIn && requiresAuth)) {
            // Sign-in prompt is shown as a dismissible sheet so users
            // can still browse without being signed in.
            SignInView()
        }
        #if os(iOS)
        // Deep link is handled by MainTabView.onChange(of: browseVM.deepLinkedVideo)
        // which calls playerRouter.open(video:api:). No landscapePlayerCover needed here.
        #elseif !os(macOS) && !os(tvOS)
        .fullScreenCover(item: $browseVM.deepLinkedVideo) { video in
            PlayerView(video: video, api: api)
                .environment(store)
                .environment(auth)
        }
        #endif
    }

    private var requiresAuth: Bool { false }  // guest browsing is allowed
}

// MARK: - AppSection

enum AppSection: String, CaseIterable, Identifiable {
    case home = "Home"
    case search = "Search"
    case library = "Library"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .home: return AppSymbol.home
        case .search: return AppSymbol.search
        case .library: return AppSymbol.library
        case .settings: return AppSymbol.settings
        }
    }

    @MainActor @ViewBuilder
    func destination(api: InnerTubeAPI) -> some View {
        switch self {
        case .home: HomeView(api: api)
        case .search: SearchView()
        case .library: LibraryView()
        case .settings: SettingsView()
        }
    }
}

// MARK: - MainTabView  (iOS / iPadOS)

// Propagates the bottom safe-area inset (tab bar + home indicator) from inside a
// NavigationStack tab to the enclosing MainTabView so the mini player overlay can
// be positioned exactly at the top of the tab bar without hard-coding its height.
private struct TabBarBottomInsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct MainTabView: View {
    @State private var searchVM = SearchViewModel()
    @State private var selectedTab: AppSection = .home
    @State private var tabBarBottomInset: CGFloat = 0
    @Environment(\.innerTubeAPI) private var api
    @Environment(SettingsStore.self) private var store
    #if os(iOS)
    @Environment(PlayerStateStore.self) private var playerState
    @Environment(TOSPlayerStateStore.self) private var tosState
    @Environment(PlayerRouter.self) private var playerRouter
    @Environment(BrowseViewModel.self) private var browseVM
    @State private var showSrcSwapSpike = false
    #endif

    var body: some View {
        #if os(iOS)
        // Read these in body so SwiftUI's @Observable tracker registers the dependency.
        // If only accessed inside the Binding.get closure, changes won't trigger a body re-render
        // and updateUIViewController won't be called, so the cover never dismisses.
        let fullScreenVideo: Video? = playerState.presentation == .fullScreen ? playerState.currentVideo : nil
        let _ = rootLog.notice(
            "[MainTabView] body re-render — presentation=\(String(describing: playerState.presentation)) fullScreenVideo=\(fullScreenVideo?.id ?? "nil")"
        )
        let fullScreenBinding = Binding<Video?>(
            get: { fullScreenVideo },
            set: { newValue in
                // Only transition to mini player when the cover is dismissed while
                // presentation is still .fullScreen. If stop() already moved us to
                // .hidden, the async onDismiss callback must not resurrect the mini
                // player by calling minimize() — that is the race condition that
                // caused the mini-player X button to unexpectedly restore fullscreen.
                guard newValue == nil, playerState.presentation == .fullScreen else { return }
                playerState.minimize()
            }
        )
        // TOS full-screen cover binding — mirrors the AVPlayer binding above.
        // When the user swipes down or the system dismisses the cover while TOS is
        // still in .fullScreen, this setter calls minimize() so audio continues in
        // TOSMiniPlayerView. If tosState.stop() already moved us to .hidden the
        // setter is a no-op (guard prevents spurious minimize).
        let tosFullScreenVideo: Video? = tosState.presentation == .fullScreen ? tosState.currentVideo : nil
        let tosFullScreenBinding = Binding<Video?>(
            get: { tosFullScreenVideo },
            set: { newValue in
                guard newValue == nil, tosState.presentation == .fullScreen else { return }
                tosState.minimize()
            }
        )
        #endif
        TabView(selection: $selectedTab) {
            ForEach(AppSection.allCases) { section in
                NavigationStack { section.destination(api: api) }
                    // Capture the bottom safe-area inset as seen from inside the tab
                    // (UITabBarController sets this to tab-bar height + home-indicator).
                    // The value is propagated up to tabBarBottomInset via PreferenceKey
                    // so the mini-player overlay can be positioned above the tab bar.
                    .background {
                        GeometryReader { geo in
                            Color.clear
                                .preference(
                                    key: TabBarBottomInsetKey.self,
                                    value: geo.safeAreaInsets.bottom
                                )
                        }
                    }
                    .tabItem { Label(section.rawValue, systemImage: section.icon) }
                    .tag(section)
                    .accessibilityIdentifier("tab.\(section.rawValue.lowercased())")
            }
        }
        .onPreferenceChange(TabBarBottomInsetKey.self) { tabBarBottomInset = $0 }
        #if os(iOS)
        .background(TabBarLiquidGlassConfigurator(disableLiquidGlass: store.settings.disableLiquidGlass))
        #endif
        .environment(searchVM)
        .onReceive(NotificationCenter.default.publisher(for: .navigateToSearch)) { _ in
            selectedTab = .search
        }
        .onReceive(NotificationCenter.default.publisher(for: .activeChannelDidChange)) { _ in
            selectedTab = .home
        }
        #if os(iOS)
        // App Intents / Spotlight (see AppEntry.handleOpenURL).
        .onReceive(NotificationCenter.default.publisher(for: .smartTubeOpenSearch)) { note in
            guard let query = note.userInfo?["query"] as? String else { return }
            selectedTab = .search
            searchVM.query = query
            searchVM.search()
        }
        // HomeView picks the section itself (it owns the chip selection).
        .onReceive(NotificationCenter.default.publisher(for: .smartTubeOpenSection)) { _ in
            selectedTab = .home
        }
        // Reserve vertical space so scrollable tab content is not hidden under the
        // mini player. Uses a transparent placeholder rather than the real MiniPlayerView
        // to avoid duplicating the PersistentPlayerHostView UIKit layer across tabs.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Reserve vertical space for whichever mini-player is visible so
            // scrollable content is not obscured (only one can be active at a time).
            if playerState.presentation == .miniPlayer || tosState.presentation == .miniPlayer {
                Color.clear.frame(height: 62)
            }
        }
        // Render the single visible MiniPlayerView above the tab bar.
        // tabBarBottomInset = tab-bar height + home-indicator (e.g. 83 pt on Face ID
        // iPhones), read from inside the NavigationStack where UITabBarController has
        // already baked it into the safe area. The transparent passthrough spacer below
        // the mini player ensures tab-bar items remain tappable.
        .overlay(alignment: .bottom) {
            // Only one mini-player can be active at a time: AVPlayer and TOS are
            // mutually exclusive (onChange stops the other before starting the new one).
            if playerState.presentation == .miniPlayer {
                VStack(spacing: 0) {
                    MiniPlayerView()
                    Color.clear
                    .frame(height: tabBarBottomInset)
                    .allowsHitTesting(false)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.2), value: playerState.presentation)
            } else if tosState.presentation == .miniPlayer {
                VStack(spacing: 0) {
                    TOSMiniPlayerView()
                    Color.clear
                    .frame(height: tabBarBottomInset)
                    .allowsHitTesting(false)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.2), value: tosState.presentation)
            }
        }
        .landscapePlayerCover(item: fullScreenBinding, dismissStore: playerState) { video in
            PlayerView(video: video, api: api)
        }
        // TOS player full-screen cover — presented when tosState.presentation == .fullScreen.
        // TOSPlayerView reads tosState from the environment (injected via AppEntry) so the
        // WKWebView that was created by TOSPlayerStateStore.play(video:api:) is reused here.
        //
        // onFallback (2026-07-12): AVPlayer is disabled on iOS — the AVPlayer branch in
        // PlayerRouter is gone, so calling playerRouter.open() from here would either
        // re-enter TOS (the same embed that just failed) or be a no-op. Either way it
        // hides the error from the user. Just log; the YouTube IFrame renders its own
        // error UI inside the WKWebView. The user closes the player manually (back button
        // → tosState.minimize) and re-taps the video to retry the embed.
        //
        // TEST-ONLY: when `--uitesting-inline-tos` is in launch args, the helper
        // uses a direct SwiftUI `.overlay` instead of `landscapePlayerCover`'s UIKit
        // modal. The cover-present animation hides the WKWebView in the test
        // simulator long enough that YouTube's 5s player-config check times out
        // (error 153). The inline path is full-bleed and the WKWebView is visible
        // from frame 1.
        .landscapePlayerCover(item: tosFullScreenBinding, dismissStore: tosState) { video in
            TOSPlayerView(video: video, api: api) {
                // #158: YouTube's bot check asks to sign in inside the embed, which can't
                // work there. The standard player plays with the app's own sign-in, so
                // this one error still falls back to it on iOS.
                if tosState.vm?.playerError == .signInRequired {
                    rootLog.notice("[RootView] TOS sign-in required for videoId=\(video.id) — opening the standard player")
                    tosState.markFallback(videoId: video.id)
                    playerRouter.open(video: video, api: api)
                    return
                }
                rootLog.notice(
                    "[RootView] TOS onFallback for videoId=\(video.id) — AVPlayer disabled, not routing away. User must close + re-tap to retry."
                )
            }
        }
        .onChange(of: browseVM.deepLinkedVideo) { _, video in
            guard let video else { return }
            playerRouter.open(video: video, api: api)
            browseVM.deepLinkedVideo = nil
        }
        // UI-testing only: invisible button that re-opens the deeplink video in the
        // same session after stop() so testSecondOpenAfterStopPlays can verify the fix.
        // Uses the same browseVM.deepLinkedVideo path as the production deeplink, so
        // the full playerRouter.open() code path is exercised.
        .overlay(alignment: .bottomLeading) {
            let isUITesting = ProcessInfo.processInfo.arguments.contains("--uitesting")
            let deeplinkArg = ProcessInfo.processInfo.arguments
            .first(where: { $0.hasPrefix("--uitesting-deeplink-video=") })
            let deeplinkID: String? =
                deeplinkArg.map {
                    let id = String($0.dropFirst("--uitesting-deeplink-video=".count))
                    return id.isEmpty ? nil : id
                } ?? nil
            if isUITesting, let id = deeplinkID,
                playerState.presentation == .hidden, tosState.presentation == .hidden
            {
                Button {
                    browseVM.deepLinkedVideo = Video(id: id, title: "", channelTitle: "")
                } label: {
                    Color.clear.frame(width: 44, height: 44)
                }
                .accessibilityIdentifier("uitesting.reopenDeeplinkVideoButton")
            }
        }
        .fullScreenCover(isPresented: $showSrcSwapSpike) {
            ShortsEmbedSrcSwapSpikeView()
        }
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--uitesting-shorts-srcswap-spike") {
                showSrcSwapSpike = true
            }
        }
        #endif
    }
}

// MARK: - MainTVTabView  (tvOS)
// Top-bar TabView is the Apple-recommended navigation pattern for Apple TV.
// Each tab contains a NavigationStack so drill-down is available within each section.

#if os(tvOS)
struct MainTVTabView: View {
    @State private var searchVM = SearchViewModel()
    @State private var selectedTab: AppSection = .home
    @Environment(\.innerTubeAPI) private var api

    var body: some View {
        TabView(selection: $selectedTab) {
            ForEach(AppSection.allCases) { section in
                NavigationStack { section.destination(api: api) }
                    .tabItem {
                        Label(section.rawValue, systemImage: section.icon)
                    }
                    .tag(section)
            }
        }
        .environment(searchVM)
        .onReceive(NotificationCenter.default.publisher(for: .activeChannelDidChange)) { _ in
            selectedTab = .home
        }
    }
}
#endif

// MARK: - MainSidebarView  (macOS)

#if os(macOS)
struct MainSidebarView: View {
    let tab: MacDesktopTabState
    @Environment(AuthService.self) private var auth
    @Environment(SettingsStore.self) private var store
    @Environment(\.innerTubeAPI) private var api
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var videoFullscreen = false
    @State private var searchText = ""
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    @State private var savedSidebarVisibility: NavigationSplitViewVisibility = .all
    @State private var showLibraryManagement = false
    @State private var editingLibraryID: UUID?
    @State private var removingLibrary: MacCustomLibrary?
    @State private var draggedLibraryID: UUID?
    private let customLibraries = MacCustomLibraryStore.shared
    @State private var homeSection = BrowseSection(type: .home)
    @State private var showSignIn = false
    @FocusState private var searchFocused: Bool
    private let session = MacPlaybackSession.shared
    private let sections: [(String, String, String)] = [
        ("home", "Home", "house"), ("shorts", "Shorts", "play.rectangle"),
        ("subscriptions", "Subscriptions", "rectangle.stack"), ("history", "History", "clock"),
        ("watchLater", "Watch Later", "bookmark"), ("liked", "Liked Videos", "hand.thumbsup"),
        ("downloads", "Downloads", "arrow.down.circle"), ("music", "Music", "music.note"),
        ("offlinePlaylists", "Offline Playlists", "folder.badge.plus"), ("queue", "Queue", "list.bullet"),
        ("playlists", "Playlists", "music.note.list"),
        ("settings", "Settings", "gearshape")
    ]
    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            List {
                ForEach(sections, id: \.0) { section in
                    Button {
                        tab.navigate(MacNavigationRoute(section: section.0))
                    } label: {
                        Label(section.1, systemImage: section.2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                            .foregroundStyle(tab.route.section == section.0 && tab.route.video == nil ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("sidebar.browse.\(section.0)")
                }
                Section("Media Libraries") {
                    ForEach(customLibraries.libraries) { library in
                        Button {
                            tab.navigate(MacNavigationRoute(section: "local:" + library.id.uuidString))
                        } label: {
                            Label(library.name, systemImage: library.symbol)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundStyle(tab.route.section == "local:" + library.id.uuidString ? Color.accentColor : Color.primary)
                        }.buttonStyle(.plain)
                        .contextMenu {
                            MacCustomLibraryContextMenu(library: library, edit: {
                                editingLibraryID = library.id; showLibraryManagement = true
                            }, remove: { removingLibrary = library })
                        }
                        .onDrag { draggedLibraryID = library.id; return NSItemProvider(object: library.id.uuidString as NSString) }
                        .onDrop(of: ["public.text"], isTargeted: nil) { _ in
                            guard let source = draggedLibraryID else { return false }
                            customLibraries.move(source, before: library.id)
                            draggedLibraryID = nil
                            return true
                        }
                    }
                    Button("Add media library…", systemImage: "folder.badge.plus") {
                        Task { await customLibraries.chooseNewLibrary() }
                    }
                    Button("Manage libraries…", systemImage: "slider.horizontal.3") { editingLibraryID = nil; showLibraryManagement = true }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .navigationTitle("MacTube")
            .navigationSplitViewColumnWidth(min: 170, ideal: 195, max: 240)
            .safeAreaInset(edge: .bottom) {
                Button { showSignIn = true } label: {
                    Label(auth.isSignedIn ? (auth.accountName ?? "Account") : "Sign In", systemImage: "person.crop.circle")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }.buttonStyle(.plain)
            }
            .macGlassSurface(radius: 0, bordered: false)
        } detail: {
            VStack(spacing: 0) {
                if !videoFullscreen { navigationBar }
                NavigationStack(path: Binding(get: { tab.navigationPath }, set: { tab.navigationPath = $0 })) {
                    desktopDestination(tab.routes[0])
                        .navigationDestination(for: MacNavigationRoute.self) { route in
                            desktopDestination(route)
                        }
                }
                .environment(\.macOpenVideo, { open($0) })
                .environment(\.macNavigationState, tab)
            }.background(MacGlassBackdrop())
        }
        .environment(tab.search)
        .environment(\.macHomeSection, $homeSection)
        .environment(\.macOpenVideo, { open($0) })
        .sheet(isPresented: $showSignIn) { SignInView() }
        .sheet(isPresented: $showLibraryManagement) { MacCustomLibraryManagementView(initialSelection: editingLibraryID) }
        .confirmationDialog("Remove Library?", isPresented: Binding(get: { removingLibrary != nil }, set: { if !$0 { removingLibrary = nil } }), titleVisibility: .visible) {
            Button("Remove Library", role: .destructive) { if let id = removingLibrary?.id { customLibraries.remove(id) }; removingLibrary = nil }
            Button("Cancel", role: .cancel) { removingLibrary = nil }
        } message: { Text("Remove only the MacTube configuration for “\(removingLibrary?.name ?? "")”? Files on disk will be kept.") }
        .onAppear { synchronizeRoute() }
        .onChange(of: tab.route) { previous, route in
            if route.section != "search" || route.video != nil { tab.search.cancel() }
            tab.browse.cancel()
            synchronizeRoute(resetFullscreen: previous.video == nil || route.video == nil)
        }
        .onDisappear { tab.search.cancel(); tab.browse.cancel() }
        .onChange(of: videoFullscreen) { _, fullscreen in
            if fullscreen {
                savedSidebarVisibility = sidebarVisibility
                sidebarVisibility = .detailOnly
            } else { sidebarVisibility = savedSidebarVisibility }
        }
        .onChange(of: tab.search.query) { _, query in
            if tab.route.section == "search", !searchFocused {
                searchText = query
                tab.updateSearchQuery(query)
            }
        }
        .onChange(of: tab.browse.deepLinkedVideo) { _, video in
            if let video { open(video); tab.browse.deepLinkedVideo = nil }
        }
        .preference(key: MacDesktopFullscreenKey.self, value: videoFullscreen)
        .background(MacVideoFullscreenHost(fullscreen: $videoFullscreen))
        .background(MacInputHost(handle: handleNavigationInput, navigationOnly: true, preserveFeedKeys: tab.route.section == "shorts" && tab.route.video == nil).frame(width: 0, height: 0))
        .task(id: controlActiveState == .key) {
            guard controlActiveState == .key else { return }
            for await notification in NotificationCenter.default.notifications(named: .macWatchVideoRequested) {
                guard !Task.isCancelled else { return }
                if let video = notification.object as? Video { open(video) }
            }
        }
    }
    private var navigationBar: some View {
        HStack(spacing: 12) {
            Button { tab.move(-1) } label: { Image(systemName: "chevron.left") }
                .disabled(tab.cursor == 0).help("Back").accessibilityLabel("Back")

            Button { tab.move(1) } label: { Image(systemName: "chevron.right") }
                .disabled(tab.cursor + 1 >= tab.routes.count).help("Forward").accessibilityLabel("Forward")

            Spacer(minLength: 20)
            VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search YouTube", text: $searchText)
                    .textFieldStyle(.plain).focused($searchFocused)
                    .onSubmit { submitSearch() }
                    .accessibilityIdentifier("search.bar")
                if !searchText.isEmpty {
                    Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .accessibilityLabel("Clear search")
                }
            }.padding(.horizontal, 12).padding(.vertical, 9)
                .frame(maxWidth: 560).macGlassSurface(radius: 18)
            if searchFocused {
                MacSearchHistoryMenu(query: searchText, suggestions: tab.search.suggestions) { query in
                    searchText = query; submitSearch()
                }
            }
            }.frame(maxWidth: 560)
                .task(id: searchText) {
                    guard searchFocused else { return }
                    tab.search.query = searchText
                    await tab.search.updateSuggestions(for: searchText)
                }
            Spacer(minLength: 20)
            Button { searchFocused = true } label: { Image(systemName: "magnifyingglass") }
                .help("Focus search")
                .accessibilityLabel("Focus search")
        }.buttonStyle(.plain).padding(.horizontal, 20).padding(.vertical, 10)
    }
    @ViewBuilder private func desktopDestination(_ route: MacNavigationRoute) -> some View {
        Group {
            if route.video != nil { watchContent(route) }
            else if let playlistID = route.playlistID {
                PlaylistView(playlistId: playlistID, playlistTitle: route.playlistTitle ?? "Playlist", api: api)
            } else { browseContent(route) }
        }
        .navigationBarBackButtonHidden(true)
    }
    @ViewBuilder private func watchContent(_ route: MacNavigationRoute) -> some View {
        if let video = route.video {
            let vm = session.vm(for: api)
            if session.currentVideo?.id == video.id {
                MacWatchPage(video: video, api: api, vm: vm, fullscreen: $videoFullscreen,
                    close: {
                        videoFullscreen = false
                        if tab.cursor > 0 { tab.move(-1) } else { tab.navigate(MacNavigationRoute()) }
                    }, select: { open($0) })
            } else {
                VStack(spacing: 18) {
                    Text(video.title).font(.title2).multilineTextAlignment(.center)
                    Text("Resume this video when you are ready.").foregroundStyle(.secondary)
                    Button("Resume Video") { open(video) }.buttonStyle(.borderedProminent)
                }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    @ViewBuilder private func browseContent(_ route: MacNavigationRoute) -> some View {
            switch route.section {
            case "search": SearchView()
            case "settings": SettingsView()
            case "downloads": MacDownloadsLibraryView(onPlay: { open($0) })
            case "music": MacMusicLibraryView(onPlay: { open($0) })
            case "offlinePlaylists": MacOfflinePlaylistsView(onPlay: { open($0) })
            case "queue": MacQueuePanel(onPlay: { open($0) })
            case "liked": PlaylistView(playlistId: "LL", playlistTitle: "Liked Videos", api: api)
            default:
                if route.section.hasPrefix("local:"), let id = UUID(uuidString: String(route.section.dropFirst(6))) {
                    MacCustomLibraryView(libraryID: id, onPlay: { open($0) })
                } else { HomeView(api: api) }
            }
    }
    private func handleNavigationInput(_ action: MacInputAction) -> Bool {
        switch action {
        case .back: tab.move(-1)
        case .forward: tab.move(1)
        case .home: tab.navigate(MacNavigationRoute(section: "home"))
        case .subscriptions: tab.navigate(MacNavigationRoute(section: "subscriptions"))
        case .history: tab.navigate(MacNavigationRoute(section: "history"))
        case .downloads: tab.navigate(MacNavigationRoute(section: "downloads"))
        case .music: tab.navigate(MacNavigationRoute(section: "music"))
        case .searchFocus: searchFocused = true
        case .toggleSidebar: sidebarVisibility = sidebarVisibility == .detailOnly ? .all : .detailOnly
        default: return false
        }
        return true
    }
    private func submitSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        tab.search.query = query
        tab.search.search()
        tab.navigate(MacNavigationRoute(section: "search", query: query))
        searchFocused = false
    }
    private func synchronizeRoute(resetFullscreen: Bool = true) {
        if resetFullscreen { videoFullscreen = false }
        searchText = tab.route.query
        homeSection = BrowseSection(type: BrowseSection.SectionType(rawValue: tab.route.section) ?? .home)
        if tab.route.section == "search", tab.search.query != tab.route.query {
            tab.search.query = tab.route.query
            if !tab.route.query.isEmpty { tab.search.search() }
        }
        // Restoring navigation never starts a decoder. Playback starts on a user action.
    }
    private func open(_ video: Video) {
        let vm = session.vm(for: api)
        vm.updateSettings(store.settings)
        vm.updateAuthToken(auth.accessToken)
        vm.updateSAPISID(auth.sapisid)
        session.play(video: video, api: api)
        tab.showWatch(video)
    }
}

#endif
