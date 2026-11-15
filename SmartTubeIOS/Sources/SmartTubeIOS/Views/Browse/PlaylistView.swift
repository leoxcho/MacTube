import SmartTubeIOSCore
import SwiftUI

// MARK: - PlaylistView
//
// Shows the videos inside a user playlist.
// Mirrors the Android `PlaylistFragment`.

public struct PlaylistView: View {
    #if os(macOS)
    @Environment(\.macOpenVideo) private var macOpenVideo
    #endif
    public let playlistId: String
    public let playlistTitle: String

    @Environment(AuthService.self) private var auth
    @Environment(SettingsStore.self) private var store
    @Environment(\.innerTubeAPI) private var api
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isLandscapeLayout) private var isLandscapeLayout
    @State private var vm: PlaylistViewModel
    @State private var selectedVideo: Video?
    @State private var channelDestination: ChannelDestination?
    #if os(iOS)
    @Environment(PlayerRouter.self) private var playerRouter
    #endif

    public init(playlistId: String, playlistTitle: String, api: InnerTubeAPI) {
        self.playlistId = playlistId
        self.playlistTitle = playlistTitle
        _vm = State(initialValue: PlaylistViewModel(api: api))
    }

    public var body: some View {
        Group {
            if vm.isLoading && vm.videos.isEmpty {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.videos.isEmpty {
                emptyState
            } else {
                content
            }
        }
        .navigationTitle(playlistTitle)
        .toolbar {
            #if os(macOS)
            ToolbarItemGroup {
                Button("Play All", systemImage: "play.fill") { playPlaylist(shuffle: false) }
                    .disabled(displayVideos.isEmpty)
                Button("Shuffle", systemImage: "shuffle") { playPlaylist(shuffle: true) }
                    .disabled(displayVideos.isEmpty)
                Toggle("Repeat playlist", isOn: Binding(get: { MacMediaPlaylistStore.shared.repeatQueue }, set: { MacMediaPlaylistStore.shared.repeatQueue = $0 }))
            }
            #endif
            if playlistId == CurrentQueueStore.playlistID {
                #if os(iOS) || os(tvOS)
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        Task {
                            await CurrentQueueStore.shared.clear()
                            dismiss()
                        }
                    } label: {
                        Label("Clear Queue", systemImage: "trash")
                    }
                }
                #else
                ToolbarItem {
                    Button(role: .destructive) {
                        Task {
                            await CurrentQueueStore.shared.clear()
                            dismiss()
                        }
                    } label: {
                        Label("Clear Queue", systemImage: "trash")
                    }
                }
                #endif
            }
        }
        .onAppear {
            vm.load(playlistId: playlistId)
        }
        #if os(tvOS)
        .navigationDestination(item: $selectedVideo) { video in
            PlayerView(video: video, api: api)
        }
        #endif

        .navigationDestination(item: $channelDestination) { dest in
            ChannelView(channelId: dest.channelId)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openChannel)) { note in
            guard let channelId = note.userInfo?["channelId"] as? String, !channelId.isEmpty else { return }
            channelDestination = ChannelDestination(channelId: channelId)
        }
        .alert("Error", isPresented: .constant(vm.error != nil), presenting: vm.error) { _ in
            Button("Retry") { vm.load(playlistId: playlistId) }
            Button("Dismiss", role: .cancel) { vm.error = nil }
        } message: { err in
            Text(err.localizedDescription)
        }
    }

    private var content: some View {
        #if os(macOS)
        desktopContent
        #else
        ScrollView {
            if store.settings.compactThumbnails {

                LazyVStack(spacing: 0) {
                    ForEach(displayVideos) { video in
                        #if os(tvOS)
                        VideoCardView(
                            video: video, compact: true, currentPlaylistId: playlistId,
                            onSelect: {
                                Task { @MainActor in
                                    let captured = displayVideos
                                    await CurrentQueueStore.shared.replaceAll(with: captured)
                                    #if os(macOS)
                                    configurePlaylistContinuation(shuffle: false)
                                    #endif
                                    let startIdx =
                                        video.playlistIndex ?? captured.firstIndex(where: { $0.id == video.id }) ?? 0
                                    selectedVideo = await CurrentQueueStore.shared.videoAt(index: startIdx) ?? video
                                }
                            }
                        )
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                        .accessibilityIdentifier("video.card.\(video.id)")
                        .onAppear { vm.loadMoreIfNeeded(lastVideo: video) }
                        #else
                        VideoCardView(video: video, compact: true, currentPlaylistId: playlistId)
                            .padding(.horizontal)
                            .padding(.vertical, 6)
                            .accessibilityIdentifier("video.card.\(video.id)")
                            .onTapGesture {
                                #if os(iOS)
                                Task { @MainActor in
                                    let captured = displayVideos
                                    await CurrentQueueStore.shared.replaceAll(with: captured)
                                    #if os(macOS)
                                    configurePlaylistContinuation(shuffle: false)
                                    #endif
                                    let startIdx =
                                        video.playlistIndex ?? captured.firstIndex(where: { $0.id == video.id }) ?? 0
                                    let toPlay = await CurrentQueueStore.shared.videoAt(index: startIdx) ?? video
                                    playerRouter.open(video: toPlay, api: api)
                                }
                                #else
                                Task { @MainActor in
                                    let captured = displayVideos
                                    await CurrentQueueStore.shared.replaceAll(with: captured)
                                    #if os(macOS)
                                    configurePlaylistContinuation(shuffle: false)
                                    #endif
                                    let index = captured.firstIndex(where: { $0.id == video.id }) ?? 0
                                    selectedVideo = await CurrentQueueStore.shared.videoAt(index: index) ?? video
                                }
                                #endif
                            }
                            .onAppear { vm.loadMoreIfNeeded(lastVideo: video) }
                        #endif
                        Divider().padding(.horizontal)
                    }
                    if vm.isLoading {
                        ProgressView().frame(maxWidth: .infinity).padding()
                    }
                }
            } else {
                #if os(tvOS)
                let columnCount = 4
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(stride(from: 0, to: displayVideos.count, by: columnCount)), id: \.self) { startIdx in
                        let rowVideos = Array(
                            displayVideos[startIdx..<min(startIdx + columnCount, displayVideos.count)])
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(rowVideos) { video in
                                VideoCardView(
                                    video: video, compact: false, currentPlaylistId: playlistId,
                                    onSelect: {
                                        Task { @MainActor in
                                            let captured = displayVideos
                                            await CurrentQueueStore.shared.replaceAll(with: captured)
                                    #if os(macOS)
                                    configurePlaylistContinuation(shuffle: false)
                                    #endif
                                            let startIdx =
                                                video.playlistIndex ?? captured.firstIndex(where: { $0.id == video.id })
                                                ?? 0
                                            selectedVideo =
                                                await CurrentQueueStore.shared.videoAt(index: startIdx) ?? video
                                        }
                                    }
                                )
                                .frame(maxWidth: .infinity)
                                .accessibilityIdentifier("video.card.\(video.id)")
                            }
                            let remainder = columnCount - rowVideos.count
                            if remainder > 0 {
                                ForEach(0..<remainder, id: \.self) { _ in
                                    Color.clear.frame(maxWidth: .infinity)
                                }
                            }
                        }
                        .onAppear {
                            if let last = rowVideos.last { vm.loadMoreIfNeeded(lastVideo: last) }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                #else
                LazyVGrid(
                    columns: videoGridColumns(store.settings, landscape: isLandscapeLayout),
                    spacing: videoGridRowSpacing
                ) {
                    ForEach(displayVideos) { video in
                        VideoCardView(video: video, compact: false, currentPlaylistId: playlistId)
                            .accessibilityIdentifier("video.card.\(video.id)")
                            .onTapGesture {
                                #if os(iOS)
                                Task { @MainActor in
                                    let captured = displayVideos
                                    await CurrentQueueStore.shared.replaceAll(with: captured)
                                    #if os(macOS)
                                    configurePlaylistContinuation(shuffle: false)
                                    #endif
                                    let startIdx =
                                        video.playlistIndex ?? captured.firstIndex(where: { $0.id == video.id }) ?? 0
                                    let toPlay = await CurrentQueueStore.shared.videoAt(index: startIdx) ?? video
                                    playerRouter.open(video: toPlay, api: api)
                                }
                                #else
                                Task { @MainActor in
                                    let captured = displayVideos
                                    await CurrentQueueStore.shared.replaceAll(with: captured)
                                    #if os(macOS)
                                    configurePlaylistContinuation(shuffle: false)
                                    #endif
                                    let startIdx =
                                        video.playlistIndex ?? captured.firstIndex(where: { $0.id == video.id }) ?? 0
                                    selectedVideo = await CurrentQueueStore.shared.videoAt(index: startIdx) ?? video
                                }
                                #endif
                            }
                            .onAppear { vm.loadMoreIfNeeded(lastVideo: video) }
                    }
                }
                .id(isLandscapeLayout)  // reset on column-count change — see VideoGridSection (#82)
                .padding(.horizontal)
                .padding(.vertical, 8)
                #endif
                if vm.isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
        }
        .accessibilityIdentifier("playlistView.feed")
        .refreshable { vm.load(playlistId: playlistId, refresh: true) }
        #endif
    }

    #if os(macOS)
    private var desktopContent: some View {
        ScrollView {
            if store.settings.compactThumbnails {
                LazyVStack(spacing: 10) {
                    ForEach(Array(displayVideos.enumerated()), id: \.offset) { item in
                        desktopPlaylistCard(item.element, at: item.offset, compact: true)
                    }
                }.padding(16)
            } else {
                LazyVGrid(columns: videoGridColumns(store.settings, landscape: isLandscapeLayout), spacing: videoGridRowSpacing) {
                    ForEach(Array(displayVideos.enumerated()), id: \.offset) { item in
                        desktopPlaylistCard(item.element, at: item.offset, compact: false)
                    }
                }.padding(16)
            }
            if vm.isLoading { ProgressView().padding() }
        }
        .scrollClipDisabled()
        .accessibilityIdentifier("playlistView.feed")
        .refreshable { vm.load(playlistId: playlistId, refresh: true) }
    }
    private func desktopPlaylistCard(_ video: Video, at index: Int, compact: Bool) -> some View {
        Button { startPlaylist(at: index) } label: {
            VideoCardView(video: video, compact: compact, currentPlaylistId: playlistId)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("video.card.\(video.id)")
        .onAppear { vm.loadMoreIfNeeded(lastVideo: video) }
    }
    private func startPlaylist(at index: Int = 0, shuffle: Bool = false) {
        let captured = displayVideos
        let token = vm.nextPageToken
        MacMediaQueue.start(captured, at: index, shuffle: shuffle, title: playlistTitle, configure: {
            MacPlaylistQueueContext.shared.configure(api: api, playlistID: playlistId, continuation: token,
                shuffle: shuffle, title: playlistTitle, artworkURL: captured.first?.thumbnailURL)
        }, onPlay: macOpenVideo)
    }
    private func playPlaylist(shuffle: Bool) { startPlaylist(shuffle: shuffle) }
    #endif
    private var displayVideos: [Video] {
        vm.videos
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: AppSymbol.stackLayers)
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("No videos in this playlist")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
