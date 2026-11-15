#if os(macOS)
import AppKit
import SmartTubeIOSCore
import SwiftUI

/// Account writes use the existing authenticated service. No optimistic success
/// state: feedback is shown only after the request completes without an API error.
struct MacAccountActions: View {
    let video: Video
    let api: InnerTubeAPI
    @Environment(AuthService.self) private var auth
    @State private var signIn = false
    @State private var choosePlaylist = false
    @State private var subscriptionHelp = false
    @State private var pending = false
    @State private var message: String?
    @State private var actionTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { perform { try await api.like(videoId: video.id) } } label: { Label("Like", systemImage: "hand.thumbsup") }
                Menu {
                    Button("Dislike") { perform { try await api.dislike(videoId: video.id) } }
                    Button("Remove my rating") { perform { try await api.removeLike(videoId: video.id) } }
                } label: { Label("Dislike", systemImage: "hand.thumbsdown") }
                Menu {
                    Button("Watch Later") { perform { _ = try await api.addToWatchLater(videoId: video.id) } }
                    Button("Choose playlist…") {
                        if auth.isSignedIn { choosePlaylist = true } else { signIn = true }
                    }
                } label: { Label("Save", systemImage: "text.badge.plus") }
                Button("Subscribe…") { subscriptionHelp = true }
                    .popover(isPresented: $subscriptionHelp) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Channel subscriptions").font(.headline)
                            Text("This account connection supports reading subscriptions. Subscription changes require a YouTube web session; the TV sign-in token does not provide a verified subscription-write interface.")
                                .font(.callout).fixedSize(horizontal: false, vertical: true)
                            Link("Subscribe or unsubscribe on YouTube", destination: channelURL)
                        }.padding(20).frame(width: 330)
                    }
                if pending { ProgressView().controlSize(.small) }
            }.disabled(pending)
            if let message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if !auth.isSignedIn { Text("Sign in to sync ratings, Watch Later, and playlists with YouTube.").font(.caption).foregroundStyle(.secondary) }
        }
        .sheet(isPresented: $signIn) { SignInView() }
        .sheet(isPresented: $choosePlaylist) { MacPlaylistPicker(video: video, api: api) }
        .onChange(of: video.id) { _, _ in actionTask?.cancel(); pending = false; message = nil }
        .onDisappear { actionTask?.cancel() }
    }
    private var channelURL: URL {
        if let id = video.channelId { return URL(string: "https://www.youtube.com/channel/\(id)")! }
        return URL(string: "https://www.youtube.com/watch?v=\(video.id)")!
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard auth.isSignedIn else { signIn = true; return }
        actionTask?.cancel(); pending = true; message = nil
        actionTask = Task { @MainActor in
            defer { pending = false }
            do {
                let token = try await auth.validAccessToken()
                await api.setAuthToken(token)
                try Task.checkCancellation()
                try await operation()
                guard !Task.isCancelled else { return }
                message = "YouTube accepted the request. Account feeds may take a moment to update."
            } catch {
                guard !Task.isCancelled else { return }
                message = "YouTube could not complete this action: \(error.localizedDescription)"
            }
        }
    }
}

private struct MacPlaylistPicker: View {
    let video: Video
    let api: InnerTubeAPI
    @Environment(AuthService.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var playlists: [PlaylistInfo] = []
    @State private var loading = true
    @State private var saving = false
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save to playlist").font(.title2.bold())
            if loading { ProgressView() }
            if let message { Text(message).foregroundStyle(.secondary) }
            List(playlists) { playlist in
                Button(playlist.title) {
                    saving = true
                    Task { @MainActor in
                        defer { saving = false }
                        do {
                            await api.setAuthToken(try await auth.validAccessToken())
                            try await api.addToPlaylist(playlistId: playlist.id, videoId: video.id)
                            dismiss()
                        } catch { message = error.localizedDescription }
                    }
                }.disabled(saving)
            }.frame(minHeight: 180)
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }.padding(24).frame(width: 400)
        .task {
            defer { loading = false }
            do {
                await api.setAuthToken(try await auth.validAccessToken())
                playlists = try await api.fetchUserPlaylists()
            } catch { message = error.localizedDescription }
        }
    }
}
#endif
