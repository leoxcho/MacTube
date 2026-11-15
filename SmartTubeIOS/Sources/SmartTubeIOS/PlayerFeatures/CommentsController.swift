import Foundation
import SmartTubeIOSCore

// MARK: - Comments
//
// Shared between PlaybackViewModel (standard player) and TOSPlayerViewModel
// (TOS player) — both fetched top-level comments via InnerTubeAPI with an
// identical "skip if already loaded or in flight" guard. `videoId` is
// supplied per call so each adapter can keep its own video-id resolution
// (`(vm.playerInfo?.video ?? video).id` vs. `self.videoId`).

/// Fetches and caches top-level comments for a video.
@MainActor
@Observable
final class CommentsController {

    private(set) var comments: [Comment] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private var videoID: String?
    private var task: Task<Void, Never>?
    private var request = UUID()

    func cancel() {
        request = UUID()
        task?.cancel()
        task = nil
        isLoading = false
    }

    private let api: InnerTubeAPI
    private let logError: (String) -> Void

    init(api: InnerTubeAPI, logError: @escaping (String) -> Void = { _ in }) {
        self.api = api
        self.logError = logError
    }

    /// Fetches top-level comments for `videoId`. No-op if already loaded or in flight.
    func load(videoId: String) {
        if videoID == videoId, isLoading || (!comments.isEmpty && errorMessage == nil) { return }
        cancel()
        videoID = videoId
        comments = []
        errorMessage = nil
        isLoading = true
        let lease = request
        task = Task { [weak self, api] in
            do {
                let result = try await api.fetchComments(videoId: videoId)
                guard let self, !Task.isCancelled, request == lease else { return }
                comments = result
                isLoading = false
            } catch {
                guard let self, !Task.isCancelled, request == lease else { return }
                errorMessage = "Comments could not be loaded. They may be disabled or unavailable."
                isLoading = false
            }
        }
    }
}
