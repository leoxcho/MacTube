import Foundation
import Observation

// MARK: - LocalWatchHistoryStore (#150, task #346)
//
// SmartTube's sign-in (Google device-code flow) yields no YouTube *web* session cookies, so
// YouTube doesn't reliably credit playback to the account's real history even with the
// account-bound tracking added in PR #152 (see task #293 for alternatives). So the app also
// keeps its own on-device history: every video that starts playing (outside Incognito, with
// Watch History enabled) is recorded here and shown at the top of the History tab.
// Nothing here talks to YouTube.

public struct LocalWatchHistoryEntry: Codable, Equatable, Sendable {
    public let video: Video
    public let watchedAt: Date

    public init(video: Video, watchedAt: Date) {
        self.video = video
        self.watchedAt = watchedAt
    }
}

@Observable
@MainActor
public final class LocalWatchHistoryStore {
    public static let shared = LocalWatchHistoryStore()

    public static let maxEntries = 300
    private static let defaultsKey = "com.smarttube.localWatchHistory"
    private static let localURLsKey = "com.smarttube.localWatchHistory.localFileURLs"

    /// Most recent first, unique by video id.
    public private(set) var entries: [LocalWatchHistoryEntry] = []

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
            let decoded = try? JSONDecoder().decode([LocalWatchHistoryEntry].self, from: data)
        {
            let paths = defaults.dictionary(forKey: Self.localURLsKey) as? [String: String] ?? [:]
            entries = decoded.map { entry in
                var video = entry.video
                if let value = paths[video.id], let url = URL(string: value), url.isFileURL {
                    video.localFileURL = url
                }
                return LocalWatchHistoryEntry(video: video, watchedAt: entry.watchedAt)
            }
        }
    }

    /// Records `video` as watched now, moving it to the front if already present and
    /// evicting the oldest entries beyond `maxEntries`. Only identity/display fields are
    /// kept — per-fetch state like tracking tokens is dropped so stale tokens are never
    /// replayed from disk.
    public func record(_ video: Video, at date: Date = Date()) {
        var slim = Video(
            id: video.id, title: video.title, channelTitle: video.channelTitle,
            channelId: video.channelId, thumbnailURL: video.thumbnailURL,
            duration: video.duration, isLive: video.isLive, isShort: video.isShort)
        if let url = video.localFileURL, url.isFileURL { slim.localFileURL = url }
        // A new watch is a new history event; a prior removal must not hide it.
        if defaults === UserDefaults.standard {
            RecommendationPreferences.shared.restoreHistory(video.id)
        } else {
            var removed = Set(defaults.stringArray(forKey: "MacTube.history.removed") ?? [])
            if removed.remove(video.id) != nil { defaults.set(Array(removed), forKey: "MacTube.history.removed") }
        }
        entries.removeAll { $0.video.id == video.id }
        entries.insert(LocalWatchHistoryEntry(video: slim, watchedAt: date), at: 0)
        if entries.count > Self.maxEntries { entries.removeLast(entries.count - Self.maxEntries) }
        persist()
    }

    public func remove(id: String) {
        entries.removeAll { $0.video.id == id }
        persist()
    }

    public func clear() {
        entries = []
        persist()
    }

    /// Videos in the History tab's shape: local entries first (newest first).
    public var videos: [Video] { entries.map(\.video) }

    private func persist() {
        // Video's Codable intentionally excludes local URLs. Keep file-only
        // locators alongside the existing backwards-compatible history payload.
        var paths: [String: String] = [:]
        for entry in entries {
            if let url = entry.video.localFileURL, url.isFileURL { paths[entry.video.id] = url.absoluteString }
        }
        defaults.set(paths, forKey: Self.localURLsKey)
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
