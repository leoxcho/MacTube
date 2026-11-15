#if os(macOS)
import SmartTubeIOSCore
import SwiftUI

/// Paged portrait presentation. Only the selected Short mounts the shared player.
struct MacShortsFeed: View {
    let videos: [Video]
    let loadMore: () -> Void
    @Environment(\.innerTubeAPI) private var api
    @Environment(AuthService.self) private var auth
    @Environment(SettingsStore.self) private var settings
    @Environment(\.macOpenVideo) private var openWatch
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @SceneStorage("mactube.shorts.selected") private var selectedID: String?
    @State private var showComments = false
    @State private var actionMessage: String?
    @State private var actionPending = false
    private let session = MacPlaybackSession.shared

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 16) {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(videos) { video in
                            shortPage(video, size: geometry.size)
                                .frame(maxWidth: .infinity)
                                .frame(height: geometry.size.height)
                                .id(video.id)
                        }
                    }.scrollTargetLayout()
                }
                .focusable()
                .focusEffectDisabled()
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $selectedID)
                if showComments {
                    commentsPanel.frame(width: min(340, geometry.size.width * 0.35))
                }
            }
            .onAppear {
                if !videos.contains(where: { $0.id == selectedID }) { selectedID = videos.first?.id }
                activateSelected()
            }
            .onDisappear { session.activeModel?.onPlaybackEnded = nil }
            .onChange(of: selectedID) { _, _ in activateSelected() }
            .onChange(of: videos.count) { _, _ in
                if selectedID == nil { selectedID = videos.first?.id }
                installEndHandler()
            }
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(.downArrow) { move(1); return .handled }
            .onKeyPress(.space) { session.activeModel?.togglePlayPause(); return .handled }
        }
    }

    private func shortPage(_ video: Video, size: CGSize) -> some View {
        let commentWidth = showComments ? min(340, size.width * 0.35) + 16 : 0
        let height = max(160, min(size.height - 24, (size.width - commentWidth - 140) * 16 / 9))
        return HStack(alignment: .bottom, spacing: 16) {
            ZStack {
                Color.black
                if selectedID == video.id, let vm = session.activeModel {
                    PlayerNSLayerView(player: vm.player)
                        .contentShape(Rectangle())
                        .onTapGesture { vm.togglePlayPause() }
                    VStack {
                        HStack {
                            Button { vm.togglePlayPause() } label: {
                                Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                            }.help("Play / Pause (Space)")
                            Spacer()
                            Button { vm.player.isMuted.toggle() } label: {
                                Image(systemName: vm.player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            }.help("Mute")
                            Slider(value: Binding(get: { Double(vm.player.volume) }, set: { vm.player.volume = Float($0) }), in: 0...1)
                                .frame(width: 65).accessibilityLabel("Volume")
                            MacCaptionControls(vm: vm)
                        }
                        Spacer()
                        if let cue = vm.currentCaptionCue {
                            Text(cue.text).font(.headline).multilineTextAlignment(.center)
                                .padding(8).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Text(video.channelTitle).font(.headline)
                            Text(video.title).font(.subheadline).lineLimit(3)
                            Slider(value: Binding(get: { min(max(0, vm.currentTime), max(1, vm.duration)) }, set: { vm.seek(to: $0) }), in: 0...max(1, vm.duration))
                                .accessibilityLabel("Short progress")
                        }
                    }
                    .foregroundStyle(.white).padding(16)
                    .background(alignment: .bottom) {
                        LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                            .allowsHitTesting(false)
                    }
                    .buttonStyle(.plain)
                } else {
                    AsyncImage(url: video.thumbnailURL) { image in image.resizable().scaledToFit() }
                        placeholder: { Color.black }
                        .accessibilityHidden(true)
                }
            }
            .frame(width: height * 9 / 16, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            actionRail(video).frame(width: 64)
        }
        .padding(.vertical, 12)
    }

    private func actionRail(_ video: Video) -> some View {
        VStack(spacing: 18) {
            Button { move(-1) } label: { Image(systemName: "chevron.up") }.help("Previous Short (↑)")
            Spacer(minLength: 0)
            Button { rate(video, dislike: false) } label: { Label("Like", systemImage: "hand.thumbsup") }
                .disabled(actionPending)
            Button { rate(video, dislike: true) } label: { Label("Dislike", systemImage: "hand.thumbsdown") }
                .disabled(actionPending)
            Button {
                showComments.toggle()
                if showComments { session.activeModel?.comments.load(videoId: video.id) }
            } label: { Label("Comments", systemImage: "text.bubble") }
            ShareLink(item: video.shareURL ?? URL(string: "https://www.youtube.com/shorts/\(video.id)")!) {
                Label("Share", systemImage: "arrowshape.turn.up.right")
            }
            Menu {
                Button("Open watch page") { openWatch(video) }
                if let actionMessage { Text(actionMessage) }
                if !auth.isSignedIn { Text("Sign in in Account to rate on YouTube.") }
            } label: { Label("More", systemImage: "ellipsis") }
            Button { move(1) } label: { Image(systemName: "chevron.down") }.help("Next Short (↓)")
        }
        .labelStyle(.iconOnly)
        .font(.title2)
        .buttonStyle(MacGlassButtonStyle())
        .padding(.vertical, 16)
        .frame(maxHeight: 600)
        .overlay(alignment: .top) {
            if let actionMessage { Text(actionMessage).font(.caption).frame(width: 140).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private var commentsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Comments").font(.headline); Spacer(); Button { showComments = false } label: { Image(systemName: "xmark") } }
            Text("Read-only. Open the watch page to comment on YouTube.").font(.caption).foregroundStyle(.secondary)
            if let vm = session.activeModel {
                if vm.comments.isLoading { ProgressView() }
                if let error = vm.comments.errorMessage { Text(error).foregroundStyle(.secondary) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(vm.comments.comments) { CommentRowView(comment: $0) }
                    }
                }
            }
        }.padding(16).macGlassSurface()
    }
    private func activateSelected() {
        guard let video = videos.first(where: { $0.id == selectedID }) else { return }
        let vm = session.vm(for: api)
        vm.updateSettings(settings.settings)
        vm.updateAuthToken(auth.accessToken)
        vm.updateSAPISID(auth.sapisid)
        session.play(video: video, api: api)
        installEndHandler()
        actionMessage = nil
        if showComments { vm.comments.load(videoId: video.id) }
        if videos.suffix(3).contains(where: { $0.id == video.id }) { loadMore() }
    }
    private func installEndHandler() {
        session.vm(for: api).onPlaybackEnded = {
            guard let vm = session.activeModel else { return }
            vm.seek(to: 0)
            vm.player.rate = Float(vm.settings.playbackSpeed)
        }
    }
    private func move(_ offset: Int) {
        guard let index = videos.firstIndex(where: { $0.id == selectedID }), videos.indices.contains(index + offset) else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { selectedID = videos[index + offset].id }
    }
    private func rate(_ video: Video, dislike: Bool) {
        guard auth.isSignedIn else { actionMessage = "Sign in in Account to rate on YouTube."; return }
        actionPending = true
        Task { @MainActor in
            defer { actionPending = false }
            do {
                let token = try await auth.validAccessToken()
                await api.setAuthToken(token)
                if dislike { try await api.dislike(videoId: video.id) }
                else { try await api.like(videoId: video.id) }
                actionMessage = "YouTube accepted the rating."
            } catch { actionMessage = "Rating failed: \(error.localizedDescription)" }
        }
    }
}
#endif
