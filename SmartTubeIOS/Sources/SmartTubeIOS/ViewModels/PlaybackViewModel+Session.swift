import AVFoundation
import SmartTubeIOSCore

extension PlaybackViewModel {
    var reusableStreamResolvedAt: Date? {
        #if os(macOS)
        return ytdlpStream == nil ? nil : ytdlpResolvedAt
        #else
        return nil
        #endif
    }
    var reusableStreamURLs: [URL] {
        #if os(macOS)
        return [lastAttemptedStreamURL].compactMap { $0 }
            + (ytdlpStream?.formats.compactMap { $0.url.flatMap(URL.init(string:)) } ?? [])
        #else
        return [lastAttemptedStreamURL].compactMap { $0 }
        #endif
    }
    func restoreReusedItemObservers() {
        guard let item = player.currentItem, let video = currentVideo else { return }
        let request = sessionLease.token
        endObserverTask?.cancel()
        endObserverTask = Task { [weak self, weak item] in
            guard let item else { return }
            for await _ in NotificationCenter.default.notifications(
                named: AVPlayerItem.didPlayToEndTimeNotification, object: item)
            {
                guard let self, !Task.isCancelled, sessionLease.isCurrent(request), player.currentItem === item else {
                    return
                }
                handlePlaybackEnd()
            }
        }
        #if os(macOS)
        if ytdlpStream != nil { monitorYTDLPItem(item, video: video) }
        #endif
    }
}
