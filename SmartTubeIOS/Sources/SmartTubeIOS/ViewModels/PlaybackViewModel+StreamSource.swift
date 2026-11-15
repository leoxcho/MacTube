@preconcurrency import AVFoundation
import SmartTubeIOSCore
import os

#if os(macOS)
/// The result stays on MainActor; the wrapper permits a cancellable MainActor task.
private struct NativePlaybackOutcome: @unchecked Sendable {
    let stream: YTDLPStreamResolver.Stream
    let started: YTDLPPlaybackAsset.Started
}
#endif

private let streamSourceLog = Logger(subsystem: "com.mactube.app", category: "StreamSource")

extension PlaybackViewModel {
    /// Native resolution, candidate traversal and one fresh-resolution pass precede legacy sources.
    func exhaustiveRetry(
        video: Video, originalError: Error?, playerInfo: PlayerInfo? = nil, cached: CachedVideoData? = nil
    ) async {
        #if os(macOS)
        let request = sessionLease.token
        guard !Task.isCancelled, sessionLease.isCurrent(request), currentVideo?.id == video.id else { return }
        if !ytdlpAttempted, StreamMethodProbeSupport.forcedStreamMethod == nil {
            ytdlpAttempted = true
            do {
                nativeOperationID = UUID()
                isLoading = true
                isSwappingItem = true
                error = nil
                itemObserverTask?.cancel()
                let result = try await startNativePlayback(
                    video: video, preferredHeight: settings.preferredQuality.maxHeight,
                    startPosition: savedPositionToRestore, request: request)
                try Task.checkCancellation()
                guard sessionLease.isCurrent(request), currentVideo?.id == video.id else { return }
                installYTDLPCatalog(result.stream)
                nativeActiveFormatID = result.started.format.id
                isAudioOnlyMode = settings.audioOnlyMode || !result.started.format.hasVideo
                startNativeWatchEnrichment(video: video)
                let item = result.started.item
                savedPositionToRestore = nil
                needsQuickStartup = false
                isLoading = false
                isSwappingItem = false
                error = nil
                retryStatusMessage = ""
                lastSuccessfulStreamType = result.started.format.isHLS ? "yt-dlp/HLS" : "yt-dlp/MP4"
                timeToPlayMs = Int(Date().timeIntervalSince(videoLoadStartedAt) * 1000)
                duration = result.stream.isLive ? 0 : (result.stream.duration ?? 0)
                currentTime = max(0, player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0)
                loadAudioTracks(from: item)
                player.rate = Float(settings.playbackSpeed)
                isPlaying = true
                monitorYTDLPItem(item, video: video)
                streamSourceLog.notice("Native playback verified format=\(result.started.format.id, privacy: .public) startupMs=\(self.timeToPlayMs)")
                return
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, sessionLease.isCurrent(request), currentVideo?.id == video.id else { return }
                isSwappingItem = false
                if NativePlaybackRecoveryPolicy.classify(error) == .unavailable {
                    self.error = error
                    isLoading = false
                    isPlaying = false
                    retryStatusMessage = ""
                    return
                }
                streamSourceLog.error("Native sequence exhausted classification=\(NativePlaybackRecoveryPolicy.classify(error).rawValue, privacy: .public)")
                retryStatusMessage = "Trying another playback source…"
            }
        }
        guard !Task.isCancelled, sessionLease.isCurrent(request), currentVideo?.id == video.id else { return }
        #endif
        await legacyExhaustiveRetry(video: video, originalError: originalError, playerInfo: playerInfo, cached: cached)
        #if os(macOS)
        if !Task.isCancelled, sessionLease.isCurrent(request), currentVideo?.id == video.id,
            player.currentItem?.status == .readyToPlay, !isLoading {
            error = nil
            retryStatusMessage = ""
        }
        #endif
    }

    #if os(macOS)
    /// Centralized bounded startup used for initial playback and interrupted playback.
    /// Re-resolution is useful only if it changes rejected delivery URLs or formats.
    func startNativePlayback(
        video: Video, preferredHeight: Int?, startPosition: Double?, request: UUID,
        initialStream: YTDLPStreamResolver.Stream? = nil, excluding rejectedURLs: Set<String> = [],
        playbackRate: Float? = nil
    ) async throws -> (stream: YTDLPStreamResolver.Stream, started: YTDLPPlaybackAsset.Started) {
        let operation = nativeOperationID
        let deadline = ContinuousClock.now + NativePlaybackRecoveryPolicy.sequenceTimeout
        let work = Task { @MainActor in
            try await self.performNativePlayback(
                video: video, preferredHeight: preferredHeight, startPosition: startPosition,
                request: request, initialStream: initialStream, excluding: rejectedURLs,
                playbackRate: playbackRate, operation: operation, deadline: deadline)
        }
        let watchdog = Task { @MainActor [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) }
            catch { return }
            work.cancel()
            guard let self, sessionLease.isCurrent(request), nativeOperationID == operation else { return }
            player.pause()
            player.currentItem?.cancelPendingSeeks()
            player.currentItem?.asset.cancelLoading()
        }
        defer { watchdog.cancel() }
        do {
            let outcome = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: { work.cancel() }
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw YTDLPStreamResolver.Failure.timeout }
            return (outcome.stream, outcome.started)
        } catch {
            if !Task.isCancelled, ContinuousClock.now >= deadline { throw YTDLPStreamResolver.Failure.timeout }
            throw error
        }
    }

    private func performNativePlayback(
        video: Video, preferredHeight: Int?, startPosition: Double?, request: UUID,
        initialStream: YTDLPStreamResolver.Stream?, excluding rejectedURLs: Set<String>,
        playbackRate: Float?, operation: UUID, deadline: ContinuousClock.Instant
    ) async throws -> NativePlaybackOutcome {
        var rejected = rejectedURLs
        var lastError: Error = YTDLPStreamResolver.Failure.noStreams
        for pass in 0..<NativePlaybackRecoveryPolicy.resolutionPasses {
            try Task.checkCancellation()
            guard sessionLease.isCurrent(request), nativeOperationID == operation, currentVideo?.id == video.id else { throw CancellationError() }
            guard ContinuousClock.now < deadline else { throw YTDLPStreamResolver.Failure.timeout }
            retryStatusMessage = pass == 0 ? "Resolving video…" : "Refreshing rejected stream URLs…"
            do {
                let stream: YTDLPStreamResolver.Stream
                if pass == 0, let initialStream { stream = initialStream }
                else { stream = try await YTDLPStreamResolver().resolve(videoID: video.id) }
                try Task.checkCancellation()
                guard sessionLease.isCurrent(request), nativeOperationID == operation, currentVideo?.id == video.id else { throw CancellationError() }
                let started = try await YTDLPPlaybackAsset.start(
                    stream: stream, player: player, preferredHeight: preferredHeight,
                    excludedURLs: rejected,
                    preferAudioOnly: settings.audioOnlyMode || audioOnlyVideoIDs.contains(video.id),
                    startPosition: startPosition,
                    playbackRate: playbackRate ?? Float(settings.playbackSpeed),
                    sequenceDeadline: deadline,
                    onRejected: { format, failure in
                        if let url = NativePlaybackRecoveryPolicy.failedMediaURL(failure) ?? format.url {
                            rejected.insert(url)
                        }
                        streamSourceLog.notice("Native rejection format=\(format.id, privacy: .public) classification=\(NativePlaybackRecoveryPolicy.classify(failure, url: format.url).rawValue, privacy: .public)")
                    },
                    isCurrent: { self.sessionLease.isCurrent(request) && self.nativeOperationID == operation && self.currentVideo?.id == video.id })
                return NativePlaybackOutcome(stream: stream, started: started)
            } catch is CancellationError { throw CancellationError() } catch {
                lastError = error
                guard NativePlaybackRecoveryPolicy.shouldRefresh(after: error) else { throw error }
            }
        }
        throw lastError
    }

    /// Item and generation scoped. Pauses, seeks and quality swaps cannot launch recovery.
    func monitorYTDLPItem(_ item: AVPlayerItem, video: Video, recoveryAttempt: Int = 0) {
        itemObserverTask?.cancel()
        let request = sessionLease.token
        itemObserverTask = Task { [weak self, weak item] in
            var lastPosition = item?.currentTime().seconds ?? 0
            var lastAdvancedAt = Date()
            while !Task.isCancelled {
                guard let self, let item, player.currentItem === item,
                    sessionLease.isCurrent(request), currentVideo?.id == video.id else { return }
                let live = ytdlpStream?.isLive == true
                if live, let range = item.seekableTimeRanges.last?.timeRangeValue {
                    let end = CMTimeRangeGetEnd(range).seconds
                    if end.isFinite { duration = end }
                } else if !live, item.duration.seconds.isFinite, item.duration.seconds > 0 {
                    duration = item.duration.seconds
                }
                let position = item.currentTime().seconds
                let nearEnd = !live && duration > 0 && position >= duration - 1
                let shouldAdvance = isPlaying && !isScrubbing && !isQualityChangePending && !isSwappingItem && !nearEnd
                if !shouldAdvance || (position.isFinite && abs(position - lastPosition) > NativePlaybackRecoveryPolicy.minimumAdvancement) {
                    lastAdvancedAt = Date()
                }
                lastPosition = position
                let interrupted = shouldAdvance && Date().timeIntervalSince(lastAdvancedAt) >= NativePlaybackRecoveryPolicy.stalledPlaybackInterval
                if item.status == .failed || interrupted {
                    guard !isQualityChangePending, !isSwappingItem else { return }
                    guard recoveryAttempt < NativePlaybackRecoveryPolicy.interruptionRecoveries else {
                        error = NSError(domain: "MacTube.Stream", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Playback stopped after bounded stream recovery. Check connectivity or try another quality."])
                        isPlaying = false
                        isLoading = false
                        return
                    }
                    let resumePlaying = isPlaying
                    let resumePosition = position.isFinite ? max(0, position) : max(0, currentTime)
                    let preferredHeight = selectedFormat?.height ?? settings.preferredQuality.maxHeight
                    // Exclude the active failed signed URL as well as failed startup candidates.
                    let activeURL = ytdlpStream?.formats.first { $0.id == nativeActiveFormatID }?.url
                    let excluded = Set([activeURL].compactMap { $0 })
                    nativeOperationID = UUID()
                    isLoading = true
                    isSwappingItem = true
                    do {
                        let result = try await startNativePlayback(
                            video: video, preferredHeight: preferredHeight, startPosition: resumePosition,
                            request: request, excluding: excluded,
                            playbackRate: resumePlaying ? Float(settings.playbackSpeed) : 0)
                        try Task.checkCancellation()
                        guard sessionLease.isCurrent(request), currentVideo?.id == video.id else { return }
                        installYTDLPCatalog(result.stream)
                        nativeActiveFormatID = result.started.format.id
                        isAudioOnlyMode = settings.audioOnlyMode || !result.started.format.hasVideo
                        isSwappingItem = false
                        isLoading = false
                        error = nil
                        retryStatusMessage = ""
                        loadAudioTracks(from: result.started.item)
                        player.rate = resumePlaying ? Float(settings.playbackSpeed) : 0
                        isPlaying = resumePlaying
                        monitorYTDLPItem(result.started.item, video: video, recoveryAttempt: recoveryAttempt + 1)
                    } catch is CancellationError { return } catch {
                        guard !Task.isCancelled, sessionLease.isCurrent(request), currentVideo?.id == video.id else { return }
                        isSwappingItem = false
                        isPlaying = false
                        isLoading = false
                        self.error = NSError(domain: "MacTube.Stream", code: 3,
                            userInfo: [NSLocalizedDescriptionKey: "Stream recovery exhausted compatible candidates. Check connectivity or reopen this video."])
                        streamSourceLog.error("Recovery failed classification=\(NativePlaybackRecoveryPolicy.classify(error).rawValue, privacy: .public)")
                    }
                    return
                }
                do { try await Task.sleep(for: NativePlaybackRecoveryPolicy.monitorInterval) }
                catch { return }
            }
        }
        Task { [weak self, weak item] in
            guard let self, let item else { return }
            await configureNativeCaptions(for: item)
        }
        // End notifications must follow every replacement item (initial, recovery and quality).
        endObserverTask?.cancel()
        endObserverTask = Task { [weak self, weak item] in
            guard let item else { return }
            for await _ in NotificationCenter.default.notifications(named: AVPlayerItem.didPlayToEndTimeNotification, object: item) {
                guard let self, !Task.isCancelled, sessionLease.isCurrent(request), player.currentItem === item else { return }
                handlePlaybackEnd()
            }
        }
    }
    #endif
}
