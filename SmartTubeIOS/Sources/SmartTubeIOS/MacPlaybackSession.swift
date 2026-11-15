#if os(macOS)
import AVFoundation
import Observation
import SmartTubeIOSCore
import SwiftUI

/// The desktop's single audible session. Navigation owns presentation, never the
/// player: closing or rebuilding a watch view cannot cancel a playing item.
@MainActor @Observable
public final class MacPlaybackSession {
    public static let shared = MacPlaybackSession()
    private var model: PlaybackViewModel?
    private var hasSession = false
    @ObservationIgnored private var preferredAudioVideos: [Video] = []

    func preferAudio(for videos: [Video]) {
        // Bounded session preference; no persisted global playback-setting changes.
        preferredAudioVideos = Array(videos.prefix(500))
        model?.preferAudioOnly(for: preferredAudioVideos)
    }

    private init() {}

    public var currentVideo: Video? { hasSession ? model?.currentVideo : nil }
    public var activeModel: PlaybackViewModel? { hasSession ? model : nil }

    public func vm(for api: InnerTubeAPI) -> PlaybackViewModel {
        if let model { return model }
        let model = PlaybackViewModel(api: api)
        self.model = model
        return model
    }

    public func play(video: Video, api: InnerTubeAPI) {
        let model = vm(for: api)
        // Queue-tagged requests are established by MacMediaQueue before navigation.
        // Ordinary requests explicitly leave that context, without deleting the
        // persisted user queue. Quality/fullscreen changes never enter this action.
        let queued = video.playlistId == CurrentQueueStore.playlistID && video.playlistIndex != nil
        if !queued {
            MacPlaylistQueueContext.shared.reset()
            preferredAudioVideos = []
            model.audioOnlyVideoIDs.removeAll()
        }
        if !preferredAudioVideos.isEmpty { model.preferAudioOnly(for: preferredAudioVideos) }
        // A paused video is still a live session. Returning to its page must not
        // reset position, captions, quality, volume, or the user's pause choice.
        guard !hasSession || model.currentVideoId != video.id else {
            // The same media can be selected from a different context without
            // restarting its decoder or retaining its previous playlist cursor.
            model.currentVideo?.playlistId = queued ? video.playlistId : nil
            model.currentVideo?.playlistIndex = queued ? video.playlistIndex : nil
            model.hasPrevious = queued ? (video.playlistIndex ?? 0) > 0 : !model.history.isEmpty
            model.hasNext = queued || !model.relatedVideos.isEmpty
            return
        }
        if hasSession { model.player.pause() }
        model.relatedVideos = []
        model.hasNext = queued
        model.hasPrevious = queued && (video.playlistIndex ?? 0) > 0
        hasSession = true
        model.load(video: video)
    }

    public func stop() {
        hasSession = false
        model?.stop()
    }
}

/// A second presentation of the same AVPlayer, with no resolver or item of its own.
struct MacMiniPlayer: View {
    let session: MacPlaybackSession
    let returnToWatch: () -> Void

    var body: some View {
        if let vm = session.activeModel, let video = session.currentVideo {
            HStack(spacing: 12) {
                Button(action: returnToWatch) {
                    PlayerNSLayerView(player: vm.player)
                        .frame(width: 160, height: 90)
                        .background(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .allowsHitTesting(false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Return to video")
                .accessibilityIdentifier(MacPlaybackAccessibility.restore)
                VStack(alignment: .leading, spacing: 4) {
                    Text(vm.playerInfo?.video.title ?? video.title)
                        .font(.headline).lineLimit(2)
                    Text(video.channelTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if vm.isLoading { ProgressView().controlSize(.small) }
                }
                .frame(maxWidth: 280, alignment: .leading)
                .contentShape(Rectangle()).onTapGesture(perform: returnToWatch)
                Button(action: returnToWatch) { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 28, height: 28) }.help("Return to video")
                Button { vm.togglePlayPause() } label: {
                    Image(systemName: vm.isPlaying ? AppSymbol.pause : AppSymbol.play)
                        .frame(width: 28, height: 28)
                }
                .accessibilityLabel(vm.isPlaying ? "Pause" : "Play")
                .accessibilityIdentifier(MacPlaybackAccessibility.playPause)
                Button { session.stop() } label: {
                    Image(systemName: AppSymbol.xmark).frame(width: 28, height: 28)
                }
                .accessibilityLabel("Close mini player")
                .accessibilityIdentifier(MacPlaybackAccessibility.close)
            }
            .buttonStyle(.plain)
            .padding(12)
            .macGlassSurface(radius: 16)
            .padding(16)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(MacPlaybackAccessibility.miniPlayer)
        }
    }
}

enum MacPlaybackAccessibility {
    static let miniPlayer = "desktop.miniPlayer"
    static let restore = "desktop.miniPlayer.restore"
    static let playPause = "desktop.miniPlayer.playPause"
    static let close = "desktop.miniPlayer.close"
}
#endif
