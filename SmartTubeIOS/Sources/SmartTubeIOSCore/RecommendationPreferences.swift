import Foundation
import Observation

/// Local feed choices. These are deliberately separate from unverified account writes.
@MainActor @Observable
public final class RecommendationPreferences {
    public static let shared = RecommendationPreferences()
    private let defaults: UserDefaults
    public var showWatchedOnHome: Bool { didSet { defaults.set(showWatchedOnHome, forKey: "MacTube.home.showWatched") } }
    public var showShortsOnHome: Bool { didSet { defaults.set(showShortsOnHome, forKey: "MacTube.home.showShorts") } }
    public private(set) var dismissedIDs: Set<String>
    public private(set) var watchedIDs: Set<String>
    public private(set) var removedHistoryIDs: Set<String>
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showWatchedOnHome = defaults.bool(forKey: "MacTube.home.showWatched")
        showShortsOnHome = defaults.bool(forKey: "MacTube.home.showShorts")
        dismissedIDs = Set(defaults.stringArray(forKey: "MacTube.feed.dismissed") ?? [])
        watchedIDs = Set(defaults.stringArray(forKey: "MacTube.feed.watched") ?? [])
        removedHistoryIDs = Set(defaults.stringArray(forKey: "MacTube.history.removed") ?? [])
    }
    public func dismiss(_ id: String) {
        dismissedIDs.insert(id)
        defaults.set(Array(dismissedIDs), forKey: "MacTube.feed.dismissed")
        NotificationCenter.default.post(name: .hideVideoFromFeed, object: nil, userInfo: ["videoId": id])
    }
    public func undoDismissals() {
        dismissedIDs.removeAll()
        defaults.removeObject(forKey: "MacTube.feed.dismissed")
    }
    public func recordPlayback(videoID: String, position: Double, duration: Double) {
        guard position.isFinite, position >= 30 || (duration.isFinite && duration > 0 && position / duration >= 0.5),
              watchedIDs.insert(videoID).inserted else { return }
        defaults.set(Array(watchedIDs), forKey: "MacTube.feed.watched")
    }
    public func restoreHistory(_ id: String) {
        guard removedHistoryIDs.remove(id) != nil else { return }
        defaults.set(Array(removedHistoryIDs), forKey: "MacTube.history.removed")
    }
    public func removeHistory(_ id: String) {
        removedHistoryIDs.insert(id)
        defaults.set(Array(removedHistoryIDs), forKey: "MacTube.history.removed")
        LocalWatchHistoryStore.shared.remove(id: id)
        NotificationCenter.default.post(name: .localHistoryItemRemoved, object: nil, userInfo: ["videoId": id])
    }
    public func allowsHome(_ video: Video) -> Bool {
        !dismissedIDs.contains(video.id)
            && (showShortsOnHome || !video.isShort)
            && (showWatchedOnHome || (!watchedIDs.contains(video.id) && !video.isWatched(threshold: 0.5)))
    }
}

public extension Notification.Name {
    static let localHistoryItemRemoved = Notification.Name("MacTube.localHistoryItemRemoved")
}
