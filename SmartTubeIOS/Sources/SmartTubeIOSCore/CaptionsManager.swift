import Foundation

// MARK: - CaptionsManager

/// Owns caption state: `availableCaptions`, `selectedCaption`, `currentCaptionCue`,
/// `captionCues`, and `captionFetchTask`. Fully self-contained — no delegate needed.
@MainActor
@Observable
public final class CaptionsManager {

    // MARK: - State

    public var availableCaptions: [CaptionTrack] = []
    public var selectedCaption: CaptionTrack? = nil
    public var currentCaptionCue: CaptionCue? = nil
    public private(set) var isLoading = false
    public private(set) var fetchError: String?
    @ObservationIgnored private var latestTime: TimeInterval = 0

    // Not observed (task handle, not UI state)
    @ObservationIgnored public var captionCues: [CaptionCue] = []
    @ObservationIgnored public var captionFetchTask: Task<Void, Never>? = nil

    // MARK: - Init

    public init() {}

    // MARK: - Interface

    public func reset() {
        isLoading = false
        fetchError = nil
        latestTime = 0
        availableCaptions = []
        selectedCaption = nil
        currentCaptionCue = nil
        captionCues = []
        captionFetchTask?.cancel()
        captionFetchTask = nil
    }

    public func cancel() {
        isLoading = false
        captionFetchTask?.cancel()
        captionFetchTask = nil
    }

    /// Selects a caption track and fetches its VTT cues. Pass `nil` to disable captions.
    /// Cue selection uses the latest observed playback time when the fetch finishes.
    public func selectCaption(_ track: CaptionTrack?, currentTime: TimeInterval = 0) {
        latestTime = currentTime
        fetchError = nil
        isLoading = track != nil
        selectedCaption = track
        currentCaptionCue = nil
        captionCues = []
        captionFetchTask?.cancel()
        captionFetchTask = nil
        guard let track else { return }
        captionFetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let parser = WebVTTParser()
                let cues = try await parser.fetchCues(from: track.baseURL)
                guard !Task.isCancelled else { return }
                guard self.selectedCaption?.id == track.id else { return }
                self.isLoading = false
                self.captionCues = cues
                if cues.isEmpty { self.fetchError = "No accessible caption cues" }
                self.updateCaptionCue(for: self.latestTime)
            } catch {
                guard !Task.isCancelled, self.selectedCaption?.id == track.id else { return }
                self.isLoading = false
                self.fetchError = "Captions could not be loaded. Select a language to retry."
            }
        }
    }

    /// Updates `currentCaptionCue` for the given playback position.
    public func updateCaptionCue(for time: TimeInterval) {
        latestTime = time
        guard !captionCues.isEmpty else {
            currentCaptionCue = nil
            return
        }
        // Binary search the last cue starting before this position; seeking works
        // in either direction without scanning an entire transcript every tick.
        var lower = 0
        var upper = captionCues.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if captionCues[middle].startTime <= time { lower = middle + 1 }
            else { upper = middle }
        }
        guard lower > 0 else { currentCaptionCue = nil; return }
        let cue = captionCues[lower - 1]
        let next = cue.endTime > time ? cue : nil
        if currentCaptionCue?.startTime != next?.startTime || currentCaptionCue?.text != next?.text {
            currentCaptionCue = next
        }
    }
}
