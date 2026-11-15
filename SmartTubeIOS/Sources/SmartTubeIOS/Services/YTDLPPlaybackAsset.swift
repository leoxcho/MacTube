#if os(macOS)
@preconcurrency import AVFoundation
import Foundation
import os

/// A single synchronized AVAsset; independent URLs never become independent players.
enum YTDLPPlaybackAsset {
    struct Started {
        let item: AVPlayerItem
        let format: YTDLPStreamResolver.Format
        let transport: String
        /// Decoded/presented height, never the synthetic master's maximum advertised height.
        let effectiveHeight: Int
    }
    @MainActor
    static func start(
        stream: YTDLPStreamResolver.Stream, player: AVPlayer,
        preferredHeight: Int? = nil, excludedURLs: Set<String> = [],
        preferAudioOnly: Bool = false,
        startPosition: Double? = nil, playbackRate: Float = 1,
        sequenceDeadline: ContinuousClock.Instant? = nil,
        onRejected: ((YTDLPStreamResolver.Format, Error) -> Void)? = nil,
        isCurrent: () -> Bool = { true }
    ) async throws -> Started {
        let log = Logger(subsystem: "com.mactube.app", category: "NativeStreamStartup")
        var lastError: Error = YTDLPStreamResolver.Failure.noStreams
        let formats = YTDLPStreamResolver.startupFormats(stream, preferredHeight: preferredHeight)
            .filter { !excludedURLs.contains($0.url ?? "") }
        let audioFormats = YTDLPStreamResolver.audioFormats(stream).filter { !excludedURLs.contains($0.url ?? "") }
        var attempts: [(YTDLPStreamResolver.Format, YTDLPStreamResolver.Format?, Bool)] = []
        let firstAudio = audioFormats.first
        let alternative = firstAudio.flatMap { selected in
            audioFormats.dropFirst().first { $0.language == selected.language }
        }
        for format in formats where format.hasAudio || !audioFormats.isEmpty {
            attempts.append((format, format.hasAudio ? nil : firstAudio, false))
            if !format.isHLS { attempts.append((format, format.hasAudio ? nil : firstAudio, true)) }
        }
        if let alternative, let separate = formats.first(where: { !$0.hasAudio }) {
            attempts.insert((separate, alternative, false), at: min(4, attempts.count))
        }
        if preferAudioOnly {
            // Try the existing AAC/M4A catalogue first, using the same player and
            // signed URLs. Unsupported audio delivery falls back to video candidates.
            let audioAttempts = audioFormats.prefix(1).flatMap { format in
                [(format, Optional<YTDLPStreamResolver.Format>.none, false),
                 (format, Optional<YTDLPStreamResolver.Format>.none, true)]
            }
            attempts.insert(contentsOf: audioAttempts, at: 0)
        }
        for (format, audioFormat, nativeDirect) in attempts.prefix(YTDLPStreamResolver.startupCandidateLimit) {
            try Task.checkCancellation()
            if let sequenceDeadline, ContinuousClock.now >= sequenceDeadline { throw YTDLPStreamResolver.Failure.timeout }
            guard isCurrent() else { throw CancellationError() }
            do {
                let candidateTimeout: Duration = format.hasVideo ? YTDLPStreamResolver.startupTimeout : .seconds(8)
                let deadline = min(ContinuousClock.now + candidateTimeout,
                                   sequenceDeadline ?? .now.advanced(by: YTDLPStreamResolver.startupTimeout))
                let item = try await makeItem(format: format, stream: stream, audioFormat: audioFormat,
                                              preparationTimeout: ContinuousClock.now.duration(to: deadline), nativeDirect: nativeDirect)
                try Task.checkCancellation()
                guard isCurrent() else { throw CancellationError() }
                if format.isHLS, let preferredHeight {
                    guard let maximum = maximumResolution(stream: stream, preferredHeight: preferredHeight) else {
                        throw YTDLPStreamResolver.Failure.unsupported
                    }
                    item.preferredMaximumResolution = maximum
                }
                let output = format.hasVideo ? AVPlayerItemVideoOutput(pixelBufferAttributes: nil) : nil
                if let output { item.add(output) }
                defer { if let output { item.remove(output) } }
                player.replaceCurrentItem(with: item)
                while item.status == .unknown {
                    try Task.checkCancellation()
                    guard isCurrent() else { throw CancellationError() }
                    guard ContinuousClock.now < deadline else { throw YTDLPStreamResolver.Failure.timeout }
                    try await Task.sleep(for: .milliseconds(100))
                }
                try Task.checkCancellation()
                guard isCurrent(), player.currentItem === item else { throw CancellationError() }
                guard item.status == .readyToPlay else {
                    throw item.error ?? YTDLPStreamResolver.Failure.unsupported
                }
                if format.isHLS, let language = YTDLPStreamResolver.audioFormats(stream).first?.language,
                   let group = try await item.asset.loadMediaSelectionGroup(for: .audible) {
                    let normalized = language.lowercased()
                    if let option = group.options.first(where: { $0.extendedLanguageTag?.lowercased() == normalized }) {
                        item.select(option, in: group)
                    }
                }
                // HLS exposes dynamic audio renditions through media selection rather than static AVAsset tracks.
                if !format.isHLS {
                    guard try await !item.asset.loadTracks(withMediaType: .audio).isEmpty else {
                        throw YTDLPStreamResolver.Failure.unsupported
                    }
                }
                if let position = startPosition, position.isFinite, position > 0 {
                    var target = position
                    if !stream.isLive, let duration = stream.duration, duration.isFinite {
                        target = min(target, max(0, duration - 1))
                    }
                    if stream.isLive {
                        if let range = item.seekableTimeRanges.last?.timeRangeValue {
                            target = min(max(position, range.start.seconds), max(range.start.seconds, CMTimeRangeGetEnd(range).seconds - 1))
                        } else { target = .nan }
                    }
                    if target.isFinite {
                        guard await player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                                                toleranceBefore: .zero, toleranceAfter: .zero)
                        else { throw YTDLPStreamResolver.Failure.unsupported }
                    }
                }
                try Task.checkCancellation()
                guard isCurrent(), player.currentItem === item else { throw CancellationError() }
                let initial = player.currentTime().seconds
                let muteLease = playbackRate <= 0 ? NativePlaybackTemporaryMuteLease(player: player) : nil
                defer {
                    if playbackRate <= 0, player.currentItem === item { player.pause() }
                    muteLease?.release()
                }
                var decodedFrame = false
                var decodedHeight = 0
                player.playImmediately(atRate: playbackRate > 0 ? playbackRate : 1)
                while true {
                    try Task.checkCancellation()
                    guard isCurrent(), player.currentItem === item else { throw CancellationError() }
                    if item.status == .failed { throw item.error ?? YTDLPStreamResolver.Failure.unsupported }
                    let time = player.currentTime()
                    if let frame = output?.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                        decodedFrame = true
                        decodedHeight = CVPixelBufferGetHeight(frame)
                    }
                    let baseline = initial.isFinite ? initial : 0
                    if (decodedFrame || !format.hasVideo), time.seconds.isFinite, time.seconds - baseline >= 0.25 { break }
                    guard ContinuousClock.now < deadline else { throw YTDLPStreamResolver.Failure.timeout }
                    try await Task.sleep(for: .milliseconds(50))
                }
                if playbackRate <= 0 { player.pause() }
                log.notice("Native candidate decoded and advancing format=\(format.id, privacy: .public) audio=\(audioFormat?.id ?? "combined", privacy: .public) transport=\(nativeDirect ? "direct" : (format.isHLS ? "hls" : "range"), privacy: .public)")
                let displayed = item.presentationSize.height
                let effectiveHeight = displayed.isFinite && displayed > 0 ? Int(displayed.rounded()) : decodedHeight
                return Started(item: item, format: format,
                               transport: nativeDirect ? "direct" : (format.isHLS ? "hls" : "range"),
                               effectiveHeight: effectiveHeight)
            } catch is CancellationError { throw CancellationError() } catch {
                try Task.checkCancellation()
                guard isCurrent() else { throw CancellationError() }
                player.pause()
                player.replaceCurrentItem(with: nil)
                onRejected?(format, error)
                lastError = error
                let failure = error as NSError
                let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError
                log.error(
                    "Candidate rejected format=\(format.id, privacy: .public) domain=\(failure.domain, privacy: .public) code=\(failure.code) underlying=\(underlying?.code ?? 0)"
                )
            }
        }
        throw lastError
    }
    /// Preserve portrait dimensions and use actual renditions rather than inferring a 16:9 ceiling.
    static func maximumResolution(stream: YTDLPStreamResolver.Stream, preferredHeight: Int) -> CGSize? {
        let dimensions = stream.formats.filter {
            $0.nativeVideo && ($0.width ?? 0) > 0 && ($0.height ?? 0) > 0 && ($0.height ?? 0) <= preferredHeight
        }
        guard let selected = dimensions.max(by: { ($0.height ?? 0) < ($1.height ?? 0) }),
              let width = selected.width, let height = selected.height else { return nil }
        return CGSize(width: width, height: height)
    }
    private struct PreparedAsset: @unchecked Sendable { let asset: AVAsset }
    @MainActor
    static func makeItem(
        format: YTDLPStreamResolver.Format, stream: YTDLPStreamResolver.Stream,
        audioFormat selectedAudio: YTDLPStreamResolver.Format? = nil,
        preparationTimeout: Duration = YTDLPStreamResolver.startupTimeout, nativeDirect: Bool = false
    ) async throws -> AVPlayerItem {
        guard let raw = format.url else { throw YTDLPStreamResolver.Failure.invalidOutput }
        let headers = stream.headers.merging(format.http_headers ?? [:], uniquingKeysWith: { _, new in new })
        let url = try YTDLPStreamResolver.validate(url: raw, headers: headers)
        let video: AVURLAsset
        if format.isHLS || nativeDirect {
            video = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        } else {
            video = YTDLPRangeAsset(mediaURL: url, headers: headers, audioOnly: !format.hasVideo)
        }
        if !format.hasVideo, format.nativeAudio { return AVPlayerItem(asset: video) }
        guard format.nativeVideo else { throw YTDLPStreamResolver.Failure.unsupported }
        if format.nativeAudio { return AVPlayerItem(asset: video) }
        guard !stream.isLive, format.directMedia, !format.hasAudio else {
            throw YTDLPStreamResolver.Failure.unsupported
        }
        guard let audioFormat = selectedAudio ?? YTDLPStreamResolver.audioFormats(stream).first,
              let audioRaw = audioFormat.url else { throw YTDLPStreamResolver.Failure.unsupported }
        let audioHeaders = stream.headers.merging(audioFormat.http_headers ?? [:], uniquingKeysWith: { _, new in new })
        let audioURL = try YTDLPStreamResolver.validate(url: audioRaw, headers: audioHeaders)
        let audio: AVURLAsset = nativeDirect
            ? AVURLAsset(url: audioURL, options: ["AVURLAssetHTTPHeaderFieldsKey": audioHeaders])
            : YTDLPRangeAsset(mediaURL: audioURL, headers: audioHeaders, audioOnly: true)
        let prepared = try await withThrowingTaskGroup(of: PreparedAsset.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    guard let videoTrack = try await video.loadTracks(withMediaType: .video).first,
                        let audioTrack = try await audio.loadTracks(withMediaType: .audio).first
                    else { throw YTDLPStreamResolver.Failure.unsupported }
                    let videoDuration = try await video.load(.duration)
                    let audioDuration = try await audio.load(.duration)
                    let duration = videoDuration
                    guard duration.isNumeric, duration.seconds > 0 else {
                        throw YTDLPStreamResolver.Failure.unsupported
                    }
                    let composition = AVMutableComposition()
                    guard
                        let v = composition.addMutableTrack(
                            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                        let a = composition.addMutableTrack(
                            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                    else { throw YTDLPStreamResolver.Failure.unsupported }
                    let range = CMTimeRange(start: .zero, duration: duration)
                    try v.insertTimeRange(range, of: videoTrack, at: .zero)
                    try a.insertTimeRange(
                        CMTimeRange(start: .zero, duration: CMTimeMinimum(videoDuration, audioDuration)),
                        of: audioTrack, at: .zero)
                    v.preferredTransform = try await videoTrack.load(.preferredTransform)
                    return PreparedAsset(asset: composition)
                } onCancel: {
                    video.cancelLoading()
                    audio.cancelLoading()
                }
            }
            group.addTask {
                try await Task.sleep(for: preparationTimeout)
                video.cancelLoading()
                audio.cancelLoading()
                throw YTDLPStreamResolver.Failure.timeout
            }
            defer { group.cancelAll() }
            guard let item = try await group.next() else { throw CancellationError() }
            return item
        }
        return YTDLPRetainedPlayerItem(asset: prepared.asset, sourceAssets: [video, audio])
    }
}
/// Overlapping paused validations share the original global mute state.
/// A superseded item still releases its mute claim without pausing a newer item.
@MainActor
private final class NativePlaybackTemporaryMuteLease {
    private struct State { let original: Bool; var count: Int }
    private static var states: [ObjectIdentifier: State] = [:]
    private let player: AVPlayer
    private var released = false
    init(player: AVPlayer) {
        self.player = player
        let key = ObjectIdentifier(player)
        if var state = Self.states[key] {
            state.count += 1
            Self.states[key] = state
        } else {
            Self.states[key] = State(original: player.isMuted, count: 1)
        }
        player.isMuted = true
    }
    func release() {
        guard !released else { return }
        released = true
        let key = ObjectIdentifier(player)
        guard var state = Self.states[key] else { return }
        state.count -= 1
        if state.count == 0 {
            Self.states.removeValue(forKey: key)
            player.isMuted = state.original
        } else { Self.states[key] = state }
    }
}
/// Composition references need the original resource loaders throughout playback.
private final class YTDLPRetainedPlayerItem: AVPlayerItem, @unchecked Sendable {
    private let sourceAssets: [AVAsset]
    init(asset: AVAsset, sourceAssets: [AVAsset]) {
        self.sourceAssets = sourceAssets
        super.init(asset: asset, automaticallyLoadedAssetKeys: nil)
    }
}
#endif
