import SmartTubeIOSCore
import SwiftUI

// MARK: - SearchView
//
// Search interface with live suggestions and paginated results.
// Mirrors the Android `SearchTagsActivity`.

public struct SearchView: View {
    #if os(macOS)
    @Environment(\.macOpenVideo) private var macOpenVideo
    @Environment(\.macNavigationState) private var desktopNavigation
    #endif
    @Environment(SearchViewModel.self) private var vm
    @Environment(\.innerTubeAPI) private var api
    @Environment(SettingsStore.self) private var store
    @State private var selectedVideo: Video?
    @State private var channelDestination: ChannelDestination?
    @State private var showFilterSheet = false
    @State private var playlistDestination: SearchPlaylistDestination?
    @FocusState private var isSearchFocused: Bool
    #if os(iOS)
    @Environment(PlayerRouter.self) private var playerRouter
    #endif

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            #if !os(macOS)
            searchBar
            Divider()
            #endif
            HStack {
                Button { showFilterSheet = true } label: {
                    Label("Filters", systemImage: vm.filter.isDefault ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityIdentifier("search.filterButton")
                if !vm.filter.isDefault {
                    Button("Reset filters") { vm.applyFilter(.default) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal).padding(.vertical, 8)
            filterChipsRow
            Group {
                #if os(tvOS)
                if vm.isLoading || !vm.results.isEmpty {
                    resultsView
                } else if vm.query.isEmpty {
                    suggestionsListView
                } else {
                    noResultsView
                }
                #else
                if isSearchFocused {
                    suggestionsListView
                } else if vm.isLoading || !vm.results.isEmpty {
                    resultsView
                } else if !vm.query.isEmpty {
                    noResultsView
                } else {
                    suggestionsListView
                }
                #endif
            }
        }
        #if os(tvOS) || os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        #if os(tvOS)
        .navigationDestination(item: $selectedVideo) { video in
            PlayerView(video: video, api: api)
        }
        #endif

        #if os(macOS)
        .onChange(of: selectedVideo) { _, video in
            guard let video else { return }
            macOpenVideo(video)
            selectedVideo = nil
        }
        #endif
        .navigationDestination(item: $channelDestination) { dest in
            ChannelView(channelId: dest.channelId)
        }
        #if os(macOS)
        .onChange(of: playlistDestination) { _, selection in
            guard let selection else { return }
            desktopNavigation?.showPlaylist(id: selection.id, title: selection.title)
            playlistDestination = nil
        }
        #else
        .navigationDestination(item: $playlistDestination) { destination in
            PlaylistView(playlistId: destination.id, playlistTitle: destination.title, api: api)
        }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .openChannel)) { note in
            guard let channelId = note.userInfo?["channelId"] as? String, !channelId.isEmpty else { return }
            channelDestination = ChannelDestination(channelId: channelId)
        }
        .sheet(isPresented: $showFilterSheet) {
            SearchFilterSheet(current: vm.filter) { newFilter in
                vm.applyFilter(newFilter)
            }
        }
        .onDisappear { vm.cancel() }
        .task(id: vm.query) { await vm.updateSuggestions(for: vm.query) }
        .onChange(of: isSearchFocused) { _, focused in
            if focused { Task { await vm.updateSuggestions(for: vm.query) } }
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        @Bindable var vm = vm
        return HStack(spacing: 8) {
            Image(systemName: AppSymbol.search)
                .foregroundStyle(.secondary)
            TextField("Search YouTube", text: $vm.query)
                .focused($isSearchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .accessibilityIdentifier("search.bar")
                #if os(iOS)
            .textInputAutocapitalization(.never)
                #endif
                .onSubmit {
                    vm.search()
                    isSearchFocused = false
                }
            if !vm.query.isEmpty {
                Button {
                    vm.query = ""
                } label: {
                    Image(systemName: AppSymbol.xmarkCircle)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("search.clearButton")
            }
            Button {
                showFilterSheet = true
            } label: {
                Image(
                    systemName: vm.filter.isDefault
                        ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill"
                )
                .foregroundStyle(vm.filter.isDefault ? .secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("search.filterButton")
        }
        .padding(10)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Active filter chips

    @ViewBuilder
    private var filterChipsRow: some View {
        if !vm.filter.isDefault {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if vm.filter.sortOrder != .relevance {
                        FilterChip(label: LocalizedStringKey(vm.filter.sortOrder.label)) {
                            var f = vm.filter
                            f.sortOrder = .relevance
                            vm.applyFilter(f)
                        }
                    }
                    if vm.filter.uploadDate != .anytime {
                        FilterChip(label: LocalizedStringKey(vm.filter.uploadDate.label)) {
                            var f = vm.filter
                            f.uploadDate = .anytime
                            vm.applyFilter(f)
                        }
                    }
                    if vm.filter.type != .any {
                        FilterChip(label: LocalizedStringKey(vm.filter.type.label)) {
                            var f = vm.filter
                            f.type = .any
                            vm.applyFilter(f)
                        }
                    }
                    if vm.filter.duration != .any {
                        FilterChip(label: LocalizedStringKey(vm.filter.duration.label)) {
                            var f = vm.filter
                            f.duration = .any
                            vm.applyFilter(f)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
            Divider()
        }
    }

    // MARK: - Results

    private var resultsView: some View {
        let hideShorts = store.settings.hideShorts && !vm.filter.shortsOnly
        let hideLiveShorts = store.settings.hideLiveShorts
        let hideVideoPremieres = store.settings.hideVideoPremieres
        let displayResults = vm.results
            .filter { !hideShorts || !$0.isShort }
            .filter { !hideLiveShorts || !($0.isLive && $0.isShort) }
            .filter { !hideVideoPremieres || !$0.isUpcoming }
        return ScrollView {
            if vm.isLoading && vm.results.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding()
            }
            VideoGridSection(
                videos: displayResults,
                onSelect: { video in
                    if vm.filter.type == .channel {
                        channelDestination = ChannelDestination(channelId: video.channelId ?? video.id)
                        return
                    }
                    if vm.filter.type == .playlist {
                        playlistDestination = SearchPlaylistDestination(id: video.playlistId ?? video.id, title: video.title)
                        return
                    }
                    let captured = displayResults
                    Task { @MainActor in
                        await CurrentQueueStore.shared.replaceAll(with: captured)
                        let startIdx = captured.firstIndex(where: { $0.id == video.id }) ?? 0
                        let toPlay = await CurrentQueueStore.shared.videoAt(index: startIdx) ?? video
                        #if os(iOS)
                        playerRouter.open(video: toPlay, api: api)
                        #else
                        selectedVideo = toPlay
                        #endif
                    }
                },
                loadMore: vm.loadMore
            )
            if vm.isLoading && !vm.results.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding()
            }
        }
        #if os(macOS)
        .macRememberScroll("search:\(vm.query)")
        #endif
        .accessibilityIdentifier("search.results")
        #if os(iOS)
        .scrollDismissesKeyboard(.immediately)
        .contentShape(Rectangle())
        .onTapGesture { isSearchFocused = false }
        #endif
    }

    // MARK: - Suggestions list (history + recommended/live)

    private var suggestionsListView: some View {
        let suggestionsHeader = vm.query.isEmpty ? "Recommended" : "Suggestions"
        return List {
            // History section — only shown when there are matching entries
            if !vm.filteredHistory.isEmpty {
                Section(header: Text("Recent").font(.caption).foregroundStyle(.secondary)) {
                    ForEach(vm.filteredHistory) { entry in
                        Button {
                            vm.query = entry.query
                            vm.search()
                            isSearchFocused = false
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "clock")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                                Text(entry.query)
                                    .foregroundStyle(.primary)
                                Spacer()
                                #if !os(tvOS)
                                Button {
                                    vm.removeHistoryEntry(entry.query)
                                } label: {
                                    Image(systemName: AppSymbol.xmark)
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(entry.query) from history")
                                #endif
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("search.history.\(entry.query)")
                    }
                    Button(role: .destructive) {
                        vm.clearHistory()
                    } label: {
                        Text("Clear Search History")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("search.history.clearAll")
                }
            }

            // Suggestions / Recommended section (existing behaviour)
            Section(header: Text(suggestionsHeader).font(.caption).foregroundStyle(.secondary)) {
                ForEach(vm.suggestions, id: \.self) { suggestion in
                    Button {
                        vm.query = suggestion
                        vm.search()
                        isSearchFocused = false
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: AppSymbol.search)
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            Text(suggestion)
                                .foregroundStyle(.primary)
                            Spacer()
                            Button {
                                vm.query = suggestion
                            } label: {
                                Image(systemName: "arrow.up.left")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier("search.suggestionsContainer")
        // Tapping empty list space (outside a row) must dismiss the keyboard.
        // Task #202: the resultsView and noResultsView already had this gesture
        // but suggestionsListView (shown while keyboard is open) was missing it.
        // .contentShape(Rectangle()) makes the transparent empty space tappable.
        .contentShape(Rectangle())
        .onTapGesture { isSearchFocused = false }
    }

    private var placeholderView: some View {
        VStack(spacing: 16) {
            Image(systemName: AppSymbol.search)
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("Search for videos, channels & playlists")
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var noResultsView: some View {
        VStack(spacing: 16) {
            Image(systemName: AppSymbol.questionCircle)
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("No results for \"\(vm.query)\"")
                .font(.headline)
                .foregroundStyle(.secondary)
            if vm.filter.shortsOnly {
                Text("Shorts is a local filter of returned video metadata. More pages may contain matching Shorts.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if vm.hasMoreResults {
                Button("Load more results") { vm.loadMore() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        #if os(iOS)
        .contentShape(Rectangle())
        .onTapGesture { isSearchFocused = false }
        #endif
    }
}

// MARK: - FilterChip

private struct FilterChip: View {
    let label: LocalizedStringKey
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption)
            Button(action: onRemove) {
                Image(systemName: AppSymbol.xmark)
                    .font(.caption2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.tint.opacity(0.15), in: Capsule())
        .foregroundStyle(.tint)
    }
}

// MARK: - SearchFilterSheet

struct SearchFilterSheet: View {
    let current: SearchFilter
    let onApply: (SearchFilter) -> Void

    @State private var draft: SearchFilter
    @Environment(\.dismiss) private var dismiss

    init(current: SearchFilter, onApply: @escaping (SearchFilter) -> Void) {
        self.current = current
        self.onApply = onApply
        _draft = State(initialValue: current)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Sort by") {
                    Picker("Sort", selection: $draft.sortOrder) {
                        ForEach(SearchFilter.SortOrder.allCases, id: \.self) { order in
                            Text(LocalizedStringKey(order.label)).tag(order)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section("Upload date") {
                    Picker("Upload date", selection: $draft.uploadDate) {
                        ForEach(SearchFilter.UploadDate.allCases, id: \.self) { date in
                            Text(LocalizedStringKey(date.label)).tag(date)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section(String(localized: "search.filter.type", bundle: .module)) {
                    Picker(String(localized: "search.filter.type", bundle: .module), selection: $draft.type) {
                        ForEach(SearchFilter.VideoType.allCases.filter { $0 != .movie }, id: \.self) { type in
                            Text(LocalizedStringKey(type.label)).tag(type)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section("Features") {
                    Toggle("Live streams", isOn: $draft.live)
                    Toggle("HD", isOn: $draft.hd)
                    Toggle("4K", isOn: $draft.fourK)
                    Toggle("Captions / subtitles", isOn: $draft.captions)
                    Toggle("Shorts — local metadata filter", isOn: $draft.shortsOnly)
                    Text("Shorts filters the videos returned by YouTube; it is not a dedicated server-side Shorts search. Features apply to video results.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Duration") {
                    Picker("Duration", selection: $draft.duration) {
                        ForEach(SearchFilter.Duration.allCases, id: \.self) { dur in
                            Text(LocalizedStringKey(dur.label)).tag(dur)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            .navigationTitle("Search filters")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    HStack {
                        Button("Cancel") { dismiss() }
                        Button("Reset") { draft = .default }.disabled(draft.isDefault)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        if draft.shortsOnly || draft.live || draft.hd || draft.fourK || draft.captions { draft.type = .video }
                        onApply(draft)
                        dismiss()
                    }
                }
                #if os(iOS)
                ToolbarItem(placement: .bottomBar) {
                    Button("Reset") { draft = .default }
                        .disabled(draft.isDefault)
                }
                #endif
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 600, idealHeight: 720)
        #else
        .presentationDetents([.medium, .large])
        #endif
        .accessibilityIdentifier("search.filterSheet")
    }
}

private struct SearchPlaylistDestination: Hashable, Identifiable {
    let id: String
    let title: String
}
