#if os(macOS)
import AppKit
import Foundation
import Observation
import SmartTubeIOSCore

struct MacOfflinePlaylist: Codable, Identifiable {
    var id = UUID()
    var name: String
    var filePaths: [String] = []
}

@MainActor @Observable
final class MacMediaPlaylistStore {
    static let shared = MacMediaPlaylistStore()
    var playlists: [MacOfflinePlaylist] = [] { didSet { save() } }
    var repeatQueue: Bool { didSet { UserDefaults.standard.set(repeatQueue, forKey: "mactube.queue.repeat") } }
    private let key = "mactube.offline.playlists.v1"
    private init() {
        repeatQueue = UserDefaults.standard.bool(forKey: "mactube.queue.repeat")
        if let data = UserDefaults.standard.data(forKey: key), let saved = try? JSONDecoder().decode([MacOfflinePlaylist].self, from: data) { playlists = saved }
    }
    private func save() { if let data = try? JSONEncoder().encode(playlists) { UserDefaults.standard.set(data, forKey: key) } }
    func create(_ name: String) { playlists.append(MacOfflinePlaylist(name: name.isEmpty ? "New Playlist" : name)) }
    func add(_ entries: [MacMediaEntry], to id: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        for entry in entries where !playlists[index].filePaths.contains(entry.id) { playlists[index].filePaths.append(entry.id) }
    }
    func entries(for playlist: MacOfflinePlaylist) -> [MacMediaEntry] {
        let indexed = Dictionary(MacMediaLibrary.shared.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return playlist.filePaths.map { path in
            if let entry = indexed[path] { return entry }
            return MacMediaEntry(fileURL: URL(fileURLWithPath: path), title: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                channel: "Unavailable local media", duration: 0, isAudio: false, bytes: 0, modified: .distantPast, fingerprint: "missing", available: false)
        }
    }
}

struct MacCustomLibrary: Codable, Identifiable {
    var id = UUID()
    var name: String
    var symbol: String = "folder"
    var folderPaths: [String]
}

@MainActor @Observable
final class MacCustomLibraryStore {
    static let shared = MacCustomLibraryStore()
    private(set) var libraries: [MacCustomLibrary] = [] { didSet { save() } }
    @ObservationIgnored private var removalHandlers: [UUID: @MainActor (UUID) -> Void] = [:]
    func registerRemovalHandler(owner: UUID, handler: @escaping @MainActor (UUID) -> Void) { removalHandlers[owner] = handler }
    func unregisterRemovalHandler(owner: UUID) { removalHandlers.removeValue(forKey: owner) }
    func update(_ id: UUID, name: String? = nil, symbol: String? = nil) {
        guard let index = libraries.firstIndex(where: { $0.id == id }) else { return }
        if let name { libraries[index].name = name }
        if let symbol { libraries[index].symbol = symbol }
    }
    func removeFolder(_ path: String, from id: UUID) {
        guard let index = libraries.firstIndex(where: { $0.id == id }) else { return }
        libraries[index].folderPaths.removeAll { $0 == path }
        MacMediaLibrary.shared.invalidateCollectionWork()
    }
    func remove(_ id: UUID) {
        guard libraries.contains(where: { $0.id == id }) else { return }
        // Synchronous route invalidation precedes mutation; no stale array bindings.
        for handler in Array(removalHandlers.values) { handler(id) }
        libraries.removeAll { $0.id == id }
        MacMediaLibrary.shared.invalidateCollectionWork()
    }
    func move(_ id: UUID, by offset: Int) {
        guard let index = libraries.firstIndex(where: { $0.id == id }), libraries.indices.contains(index + offset) else { return }
        libraries.swapAt(index, index + offset)
    }
    func move(_ source: UUID, before target: UUID) {
        guard source != target, let from = libraries.firstIndex(where: { $0.id == source }), let to = libraries.firstIndex(where: { $0.id == target }) else { return }
        let value = libraries.remove(at: from)
        libraries.insert(value, at: min(to, libraries.count))
    }
    private let key = "mactube.custom.libraries.v1"
    private init() {
        if let data = UserDefaults.standard.data(forKey: key), let saved = try? JSONDecoder().decode([MacCustomLibrary].self, from: data) { libraries = saved }
    }
    private func save() { if let data = try? JSONEncoder().encode(libraries) { UserDefaults.standard.set(data, forKey: key) } }
    func adoptFolder(_ folder: MacMediaFolder) {
        libraries.append(MacCustomLibrary(name: folder.url.lastPathComponent, folderPaths: [folder.url.path]))
    }
    func chooseNewLibrary() async {
        let urls = await chooseFolders()
        guard !urls.isEmpty else { return }
        for url in urls { MacMediaLibrary.shared.addFolder(url) }
        libraries.append(MacCustomLibrary(name: urls[0].lastPathComponent, folderPaths: urls.map(\.path)))
    }
    func addFolders(to id: UUID) async {
        let urls = await chooseFolders()
        guard let index = libraries.firstIndex(where: { $0.id == id }) else { return }
        for url in urls {
            MacMediaLibrary.shared.addFolder(url)
            if !libraries[index].folderPaths.contains(url.path) { libraries[index].folderPaths.append(url.path) }
        }
    }
    private func chooseFolders() async -> [URL] {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        return await panel.begin() == .OK ? panel.urls : []
    }
    func entries(for library: MacCustomLibrary) -> [MacMediaEntry] {
        let roots = library.folderPaths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path }
        return MacMediaLibrary.shared.entries.filter { entry in
            roots.contains { entry.id.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
        }
    }
}

@MainActor
enum MacMediaQueue {
    /// All collection starts commit the queue before routing to the shared player.
    static func start(_ videos: [Video], at index: Int = 0, shuffle: Bool = false,
                      title: String = "Current Queue", configure: (@MainActor () -> Void)? = nil,
                      onPlay: @escaping (Video) -> Void) {
        guard videos.indices.contains(index) else { return }
        Task {
            let context = MacPlaylistQueueContext.shared
            context.reset()
            context.setMetadata(title: title, artworkURL: videos.first?.thumbnailURL)
            configure?()
            let ordered = shuffle ? videos.shuffled() : videos
            if let first = await context.begin(loaded: ordered, at: shuffle ? 0 : index) {
                onPlay(first)
                if let model = MacPlaybackSession.shared.activeModel,
                   model.currentVideoId == first.id, !model.isLoading, !model.isPlaying {
                    model.togglePlayPause()
                }
            }
        }
    }
    static func play(_ videos: [Video], shuffle: Bool = false, title: String = "Current Queue", onPlay: @escaping (Video) -> Void) {
        start(videos, shuffle: shuffle, title: title, onPlay: onPlay)
    }
    static func add(_ video: Video, next: Bool = false) {
        Task {
            if let vm = MacPlaybackSession.shared.activeModel, let current = vm.currentVideo {
                if current.playlistId != CurrentQueueStore.playlistID {
                    MacPlaylistQueueContext.shared.reset()
                    MacPlaylistQueueContext.shared.setMetadata(title: "Current Queue")
                }
                var queued = await CurrentQueueStore.shared.videos
                let index: Int
                if let existing = queued.firstIndex(where: { $0.id == current.id }) {
                    index = existing
                } else {
                    queued.insert(current, at: 0)
                    await CurrentQueueStore.shared.replaceAll(with: queued)
                    index = 0
                }
                // Adopt the queue context without loading a second item or disturbing playback.
                vm.currentVideo?.playlistId = CurrentQueueStore.playlistID
                vm.currentVideo?.playlistIndex = index
                vm.hasPrevious = index > 0
            }
            if next {
                let index = MacPlaybackSession.shared.activeModel?.currentVideo?.playlistIndex ?? -1
                let queued = await CurrentQueueStore.shared.videos
                let existing = queued.firstIndex(where: { $0.id == video.id })
                await CurrentQueueStore.shared.insertNext(video, afterIndex: index)
                if let existing, existing < index {
                    MacPlaybackSession.shared.activeModel?.currentVideo?.playlistIndex = index - 1
                }
            } else { await CurrentQueueStore.shared.append(video) }
            await MacPlaylistQueueContext.shared.refresh()
            if let vm = MacPlaybackSession.shared.activeModel {
                let count = await CurrentQueueStore.shared.videos.count
                let index = vm.currentVideo?.playlistIndex ?? -1
                vm.hasNext = index + 1 < count || MacMediaPlaylistStore.shared.repeatQueue
                vm.hasPrevious = index > 0
            }
        }
    }
}
#endif
