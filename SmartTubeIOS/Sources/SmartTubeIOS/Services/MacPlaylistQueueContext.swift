#if os(macOS)
import Foundation
import Observation
import SmartTubeIOSCore

/// A playlist queue fetches one continuation page only when its loaded tail is reached.
@MainActor @Observable
final class MacPlaylistQueueContext {
    static let shared = MacPlaylistQueueContext()
    private(set) var title = UserDefaults.standard.string(forKey: "mactube.queue.title") ?? "Current Queue"
    private(set) var artworkURL: URL?
    private(set) var videos: [Video] = []
    private(set) var windowOffset = 0
    private(set) var playlistID: String?
    private(set) var continuation: String?
    private(set) var error: String?
    private var api: InnerTubeAPI?
    private var shuffled = false
    private var explicitOrderedContext = false
    private var initialContinuation: String?
    @ObservationIgnored private var loadedSnapshot: [Video] = []
    @ObservationIgnored private var bufferedTail: ArraySlice<Video> = []
    private var generation = UUID()
    @ObservationIgnored private var pending: Task<VideoGroup, Error>?
    var hasMore: Bool { !bufferedTail.isEmpty || continuation != nil }
    var isActive: Bool { explicitOrderedContext || playlistID != nil }

    func reset() {
        generation = UUID(); pending?.cancel(); pending = nil
        playlistID = nil; continuation = nil; api = nil; error = nil; windowOffset = 0
        title = "Current Queue"; artworkURL = nil; videos = []
        loadedSnapshot = []; bufferedTail = []; explicitOrderedContext = false; initialContinuation = nil; shuffled = false
    }
    func configure(api: InnerTubeAPI, playlistID: String, continuation: String?, shuffle: Bool, title: String = "Current Queue", artworkURL: URL? = nil) {
        reset()
        setMetadata(title: title, artworkURL: artworkURL)
        guard playlistID != CurrentQueueStore.playlistID else { return }
        self.api = api; self.playlistID = playlistID; self.continuation = continuation; initialContinuation = continuation; shuffled = shuffle
    }
    func setMetadata(title: String, artworkURL: URL? = nil) {
        self.title = title; self.artworkURL = artworkURL
        UserDefaults.standard.set(title, forKey: "mactube.queue.title")
    }
    func refresh() async { videos = await CurrentQueueStore.shared.videos }
    /// Keep the active persisted queue bounded without losing selected or later items.
    func begin(loaded: [Video], at index: Int) async -> Video? {
        guard loaded.indices.contains(index) else { return nil }
        let lease = generation
        explicitOrderedContext = true
        loadedSnapshot = loaded
        windowOffset = index < 500 ? 0 : max(0, index - 100)
        let end = min(loaded.count, windowOffset + 500)
        bufferedTail = loaded[end...]
        await CurrentQueueStore.shared.replaceAll(with: Array(loaded[windowOffset..<end]))
        guard generation == lease else { return nil }
        await refresh()
        guard generation == lease else { return nil }
        return await CurrentQueueStore.shared.videoAt(index: index - windowOffset)
    }
    func shuffleAndFirst() async -> Video? {
        shuffled = true
        // Local playlists retain their source order for a complete reshuffle;
        // online queues keep the bounded loaded window and its matching token.
        let remaining = api == nil && !loadedSnapshot.isEmpty ? loadedSnapshot : videos + Array(bufferedTail)
        initialContinuation = continuation
        return await begin(loaded: remaining.shuffled(), at: 0)
    }
    func remove(at index: Int) async {
        await CurrentQueueStore.shared.remove(at: index)
        if let vm = MacPlaybackSession.shared.activeModel, vm.currentVideo?.playlistId == CurrentQueueStore.playlistID,
           let cursor = vm.currentVideo?.playlistIndex {
            if index < cursor { vm.currentVideo?.playlistIndex = cursor - 1 }
            else if index == cursor { vm.currentVideo?.playlistIndex = cursor - 1 }
        }
        await refresh()
        if let vm = MacPlaybackSession.shared.activeModel {
            let cursor = vm.currentVideo?.playlistIndex ?? -1
            vm.hasPrevious = cursor > 0
            vm.hasNext = cursor + 1 < videos.count || hasMore || MacMediaPlaylistStore.shared.repeatQueue
        }
    }
    func restartOrFirst() async -> Video? {
        if !loadedSnapshot.isEmpty {
            continuation = initialContinuation
            return await begin(loaded: loadedSnapshot, at: 0)
        }
        return await CurrentQueueStore.shared.videoAt(index: 0)
    }
    func next(after index: Int) async -> Video? {
        if let queued = await CurrentQueueStore.shared.videoAt(index: index + 1) { return queued }
        if !bufferedTail.isEmpty {
            return await appendBuffered(after: index)
        }
        guard let token = continuation, let api, let playlistID else { return nil }
        let lease = generation
        let task: Task<VideoGroup, Error>
        if let pending { task = pending }
        else {
            task = Task { try await api.fetchPlaylistVideos(playlistId: playlistID, continuationToken: token) }
            pending = task
        }
        do {
            let page = try await task.value
            guard generation == lease else { return nil }
            // Only one awaiting caller appends a given page.
            if continuation == token {
                continuation = page.nextPageToken == token ? nil : page.nextPageToken
                pending = nil; error = nil
                let addition = shuffled ? page.videos.shuffled() : page.videos
                bufferedTail = addition[...]
                return await appendBuffered(after: index)
            }
            let current = MacPlaybackSession.shared.activeModel?.currentVideo?.playlistIndex ?? index
            return await CurrentQueueStore.shared.videoAt(index: current + 1)
        } catch {
            guard generation == lease else { return nil }
            pending = nil; self.error = error.localizedDescription
            MacPlaybackSession.shared.activeModel?.toastMessage = "Could not load the next playlist page. Use Next to retry."
            return nil
        }
    }
    private func appendBuffered(after index: Int) async -> Video? {
        var queued = await CurrentQueueStore.shared.videos
        let active = MacPlaybackSession.shared.activeModel?.currentVideo
        let currentCursor = active?.playlistId == CurrentQueueStore.playlistID ? (active?.playlistIndex ?? index) : index
        let required = max(0, queued.count + bufferedTail.count - 500)
        let drop = max(0, min(currentCursor - 100, required))
        if drop > 0 { queued.removeFirst(drop); windowOffset += drop }
        let room = max(0, 500 - queued.count)
        let addition = bufferedTail.prefix(room)
        queued.append(contentsOf: addition)
        bufferedTail = bufferedTail.dropFirst(addition.count)
        await CurrentQueueStore.shared.replaceAll(with: queued)
        await refresh()
        if drop > 0, active?.playlistId == CurrentQueueStore.playlistID {
            MacPlaybackSession.shared.activeModel?.currentVideo?.playlistIndex = currentCursor - drop
        }
        return await CurrentQueueStore.shared.videoAt(index: index - drop + 1)
    }

}
#endif
