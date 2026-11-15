#if os(macOS)
import AVFoundation
import MediaPlayer
import SmartTubeIOSCore

/// One command registration for the process; commands resolve the current session
/// at execution time instead of retaining a player belonging to a closed tab.
@MainActor
private enum MacMediaCommands {
    static var installed = false
    nonisolated static func perform(_ action: @escaping @MainActor @Sendable (PlaybackViewModel) -> Void) -> MPRemoteCommandHandlerStatus {
        Task { @MainActor in
            guard let model = MacPlaybackSession.shared.activeModel else { return }
            action(model)
            model.updateMacNowPlaying()
        }
        return .success
    }
}

extension PlaybackViewModel {
    func setupMacMediaCommands() {
        guard !MacMediaCommands.installed else { return }
        MacMediaCommands.installed = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { _ in
            MacMediaCommands.perform { model in
                if !model.isPlaying { model.togglePlayPause() }
            }
        }
        center.pauseCommand.addTarget { _ in
            MacMediaCommands.perform { model in
                if model.isPlaying { model.togglePlayPause() }
            }
        }
        center.togglePlayPauseCommand.addTarget { _ in MacMediaCommands.perform { $0.togglePlayPause() } }
        center.nextTrackCommand.addTarget { _ in MacMediaCommands.perform { $0.playNext() } }
        center.previousTrackCommand.addTarget { _ in MacMediaCommands.perform { $0.playPrevious() } }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            return MacMediaCommands.perform { $0.seekRelative(seconds: interval) }
        }
        center.skipBackwardCommand.addTarget { event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            return MacMediaCommands.perform { $0.seekRelative(seconds: -interval) }
        }
        center.changePlaybackPositionCommand.addTarget { event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return .commandFailed }
            return MacMediaCommands.perform { $0.seek(to: position) }
        }
    }

    func updateMacNowPlaying() {
        guard MacPlaybackSession.shared.activeModel === self, let video = currentVideo else { return }
        let center = MPRemoteCommandCenter.shared()
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: playerInfo?.video.title ?? video.title,
            MPMediaItemPropertyArtist: video.channelTitle,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? settings.playbackSpeed : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: settings.playbackSpeed,
            MPNowPlayingInfoPropertyIsLiveStream: isLivePlayback,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        center.nextTrackCommand.isEnabled = hasNext
        center.previousTrackCommand.isEnabled = hasPrevious
        center.changePlaybackPositionCommand.isEnabled = !isLivePlayback && duration > 0
    }

    func clearMacNowPlaying() {
        // A background/old model cannot clear a newer session's metadata.
        guard MacPlaybackSession.shared.activeModel == nil || MacPlaybackSession.shared.activeModel === self else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
}
#endif
