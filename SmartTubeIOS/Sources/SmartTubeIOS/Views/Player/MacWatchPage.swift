#if os(macOS)
import AppKit
import AVFoundation
import SmartTubeIOSCore
import SwiftUI

/// Desktop watch page: the player stays at the same structural position during
/// fullscreen, metadata scrolling, and recommendation changes.
struct MacWatchPage: View {
    let video: Video
    let api: InnerTubeAPI
    let vm: PlaybackViewModel
    @Binding var fullscreen: Bool
    let close: () -> Void
    let select: (Video) -> Void
    @State private var expandedDescription = false
    @State private var avatarURL: URL?
    @State private var showDownload = false
    @State private var theater = false
    @State private var sourceAspect: CGFloat = 16 / 9
    @State private var dividerStart: Double?
    @AppStorage("mactube.watch.playerFraction") private var playerFraction = 0.70
    @AppStorage("mactube.nativePlayerControls") private var nativeControls = false
    @Environment(SettingsStore.self) private var store
    @Environment(AuthService.self) private var auth
    @Environment(\.macOpenVideoInTab) private var openInTab
    @Environment(\.macOpenVideoInWindow) private var openInWindow

    private var metadata: Video { vm.playerInfo?.video ?? vm.currentVideo ?? video }
    private var url: URL { video.localFileURL ?? URL(string: "https://www.youtube.com/watch?v=\(metadata.id)")! }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 920 && !theater
            let available = max(1, geometry.size.width)
            let sideWidth = wide && !fullscreen
                ? min(420, max(260, available * (1 - playerFraction))) : 0
            let playerWidth = max(1, available - sideWidth - (wide && !fullscreen ? 12 : 0))
            // Fit both dimensions, then size the *container* to the source frame.
            // Portrait media does not reserve a landscape black rectangle.
            let playerHeight = fullscreen ? geometry.size.height
                : min(max(180, geometry.size.height * (theater ? 0.82 : 0.72)), playerWidth / sourceAspect)
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    PlayerView(video: video, api: api, macVM: vm, fullscreen: $fullscreen, close: close)
                        .frame(width: fullscreen ? available : min(playerWidth, playerHeight * sourceAspect), height: playerHeight)
                        .frame(maxWidth: .infinity)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            details.padding(18).macGlassSurface()
                            if !wide { recommendations }
                            if video.localFileURL == nil { comments.padding(18).macGlassSurface() }
                        }
                        .padding(16)
                    }
                    .frame(height: fullscreen ? 0 : nil)
                    .opacity(fullscreen ? 0 : 1)
                    .accessibilityHidden(fullscreen)
                }
                .frame(width: fullscreen ? available : playerWidth)
                if wide && !fullscreen {
                    playerDivider(available: available)
                    ScrollView { recommendations.padding(12) }
                        .frame(width: sideWidth)
                }
            }
            .background {
                if fullscreen { Color.black }
                else {
                    MacGlassBackdrop()
                    MacAmbientLightView(player: vm.player, enabled: !fullscreen)
                        .allowsHitTesting(false)
                }
            }
        }
        .ignoresSafeArea(.container, edges: fullscreen ? .all : [])
        .background(MacVideoGeometryObserver(player: vm.player) { sourceAspect = $0 })
        .environment(\.macTheaterMode, $theater)
        .background(MacPlaybackKeyboard(vm: vm, fullscreen: $fullscreen, theater: $theater, minimize: {
            fullscreen = false
            close()
        }, setSpeed: { speed in
            store.settings.playbackSpeed = speed
            vm.setPlaybackSpeed(speed)
        }))
        .task(id: video.id) {
            vm.updateSettings(store.settings)
            vm.updateAuthToken(auth.accessToken)
            vm.updateSAPISID(auth.sapisid)
            MacPlaybackSession.shared.play(video: video, api: api)
            expandedDescription = false
            avatarURL = nil
            if video.localFileURL == nil { vm.comments.load(videoId: video.id) }

        }
        .onChange(of: metadata.channelId) { _, channelID in
            // Metadata often arrives after playback starts. The task is owned by
            // SwiftUI below rather than starting an untracked request here.
            if channelID == nil { avatarURL = nil }
        }
        .task(id: metadata.channelId) {
            guard video.localFileURL == nil, let id = metadata.channelId else { return }
            let avatar = try? await api.fetchChannelThumbnailURL(channelId: id)
            guard !Task.isCancelled, metadata.channelId == id else { return }
            avatarURL = avatar
        }
        .sheet(isPresented: $showDownload) {
            MacDownloadSheet(video: metadata, heights: vm.ytdlpDownloadHeights, service: VideoDownloadService.shared)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(metadata.title).font(.title2.bold()).textSelection(.enabled)
                .accessibilityIdentifier(MacWatchAccessibility.title)
            HStack(spacing: 12) {
                AsyncImage(url: avatarURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: AppSymbol.personCircle).resizable().foregroundStyle(.secondary)
                }
                .frame(width: 40, height: 40).clipShape(Circle())
                Text(metadata.channelTitle).font(.headline)

                Spacer()
            }
            ViewThatFits(in: .horizontal) {
                actions
                ScrollView(.horizontal) { actions }
            }
            if video.localFileURL == nil {
                MacAccountActions(video: metadata, api: api)
                    .buttonStyle(MacGlassButtonStyle())
            } else {
                Label("Playing from disk", systemImage: "internaldrive").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if let views = metadata.viewCount { Text("\(views.formatted()) views") }
                    if let published = metadata.publishedTimeText {
                        Text(published)
                    } else if let date = metadata.publishedAt {
                        Text(date, style: .date)
                    }
                    if vm.isLivePlayback { Text("LIVE").foregroundStyle(.red) }
                }.font(.subheadline.bold())
                if let description = metadata.description, !description.isEmpty {
                    Text(description).lineLimit(expandedDescription ? nil : 3).textSelection(.enabled)
                    Button(expandedDescription ? "Show less" : "Show more") { expandedDescription.toggle() }
                        .buttonStyle(.plain).fontWeight(.semibold)
                } else {
                    Text("Description unavailable.").foregroundStyle(.secondary)
                }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .macGlassSurface(radius: 12)
        }
    }
    private var actions: some View {
        HStack(spacing: 12) {
            Button { fullscreen = true; vm.showControls() } label: {
                Label("Fullscreen", systemImage: AppSymbol.enterVideoFullscreen)
            }.accessibilityIdentifier(MacWatchAccessibility.enterFullscreen)
            Button { theater.toggle() } label: {
                Label(theater ? "Default view" : "Theater mode", systemImage: "rectangle")
            }.help("Theater mode (T)")
            Menu {
                Button("Standard") { theater = false; playerFraction = 0.70 }
                Button("Expanded") { theater = false; playerFraction = 0.80 }
                Button("Theater") { theater = true }
                Button("Fullscreen") { fullscreen = true }
                Button("Mini-player") { fullscreen = false; close() }
            } label: { Label("Player size", systemImage: "arrow.left.and.right") }
            Button { nativeControls.toggle() } label: {
                Label(nativeControls ? "Custom controls" : "System controls / PiP", systemImage: "pip")
            }.help("System playback controls include macOS Picture in Picture.")
            ShareLink(item: url) { Label("Share", systemImage: AppSymbol.share) }
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
            if video.localFileURL == nil {
                Button { showDownload = true } label: {
                    Label("Download", systemImage: AppSymbol.download)
                }.accessibilityIdentifier(MacWatchAccessibility.download)
            } else if let file = video.localFileURL {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            }
        }.buttonStyle(MacGlassButtonStyle())
    }
    private var comments: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Comments").font(.title3.bold())
                Spacer()
                Link("Comment on YouTube ↗", destination: url)
                    .help("Posting requires a YouTube web session; this account connection provides read-only comments.")
            }
            Text("Comments are read-only here. Open YouTube to post or reply.")
                .font(.caption).foregroundStyle(.secondary)
            if vm.comments.isLoading {
                ProgressView()
            } else if let message = vm.comments.errorMessage {
                Text(message).foregroundStyle(.secondary)
                Button("Retry comments") { vm.comments.load(videoId: video.id) }
            } else if vm.comments.comments.isEmpty {
                Text("No comments available.").foregroundStyle(.secondary)
            }
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(vm.comments.comments) { CommentRowView(comment: $0) }
            }
        }.accessibilityIdentifier(MacWatchAccessibility.comments)
    }
    private var suggestedVideos: [Video] {
        vm.relatedVideos.filter { $0.id != metadata.id && !RecommendationPreferences.shared.dismissedIDs.contains($0.id) }
    }
    private var recommendations: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            MacWatchPlaybackContext(current: vm.currentVideo ?? video, onPlay: select)
            if video.localFileURL == nil {
            Text("Recommendations").font(.headline)
            if suggestedVideos.isEmpty {
                if vm.isLoading || vm.phase2Task != nil {
                    ProgressView("Loading recommendations…")
                } else {
                    Text("Recommendations unavailable.").foregroundStyle(.secondary)
                    Button("Retry recommendations") { vm.startNativeWatchEnrichment(video: metadata) }
                }
            }
            ForEach(suggestedVideos) { related in
                Button {
                    select(related)
                } label: {
                    recommendationCard(related)
                }.buttonStyle(.plain)
                    .accessibilityIdentifier(MacWatchAccessibility.recommendation(related.id))
                    .contextMenu {
                        Button("Open in New Tab") { openInTab(related) }
                        Button("Open in New Window") { openInWindow(related) }
                    }
            }
            }
        }
    }
    /// Passive cards must not start the legacy stream resolver or webview prewarm
    /// for every visible recommendation while the selected video is starting.
    private func recommendationCard(_ related: Video) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            AsyncImage(url: related.thumbnailURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(.quaternary)
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .bottomTrailing) {
                if related.isLive || !related.formattedDuration.isEmpty {
                    Text(related.isLive ? "LIVE" : related.formattedDuration)
                        .font(.caption.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 3)
                        .background(related.isLive ? Color.red : Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                }
            }
            Text(related.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(related.channelTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
        .macMediaCard()
    }

    private func playerDivider(available: CGFloat) -> some View {
        Capsule().fill(.secondary.opacity(0.25))
            .frame(width: 3).frame(width: 12)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dividerStart == nil { dividerStart = playerFraction }
                    let proposed = (dividerStart ?? playerFraction) + value.translation.width / available
                    playerFraction = min(Double(1 - 260 / available), max(Double(480 / available), proposed))
                }
                .onEnded { _ in dividerStart = nil })
            .accessibilityLabel("Player width")
            .accessibilityAdjustableAction { direction in
                playerFraction = min(0.82, max(0.5, playerFraction + (direction == .increment ? 0.03 : -0.03)))
            }
    }

}

extension Notification.Name {
    static let macWatchVideoRequested = Notification.Name("com.mactube.watchVideo")
}

enum MacWatchAccessibility {
    static let title = "watch.title"
    static let comments = "watch.comments"
    static let download = "watch.download"
    static let fullscreen = "watch.fullscreen"
    static let enterFullscreen = "watch.enterFullscreen"
    static func recommendation(_ id: String) -> String { "watch.recommendation.\(id)" }
}
#endif
