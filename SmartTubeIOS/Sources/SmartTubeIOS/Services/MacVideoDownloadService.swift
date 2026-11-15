#if os(macOS)
import AppKit
import Foundation
import Observation
import SmartTubeIOSCore

struct MacDownloadRecord: Codable, Identifiable {
    var id: UUID
    var title: String
    var status: String
    var progress: Double
    var date: Date
    var fileURL: URL?
    var detail: String?
}

/// macOS backend for the existing player download service interface.
@MainActor @Observable
public final class VideoDownloadService {
    static let shared = VideoDownloadService()
    public enum DownloadState: Equatable {
        case idle, fetching, downloading(progress: Double), saving, done, failed(String)
        public var isActive: Bool {
            switch self {
            case .fetching, .downloading, .saving: return true
            default: return false
            }
        }
    }
    private(set) var jobs: [MacDownloadRecord] = []
    public private(set) var state: DownloadState = .idle
    var completedURL: URL?
    var destination =
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var pending = Data()
    public init(api: InnerTubeAPI = InnerTubeAPI()) {
        if let data = UserDefaults.standard.data(forKey: "mactube.download.jobs"), let saved = try? JSONDecoder().decode([MacDownloadRecord].self, from: data) {
            jobs = saved.map { value in
                var value = value
                if value.status == "Active" { value.status = "Interrupted"; value.detail = "Retry the download in the same folder to resume." }
                return value
            }
        }
        if let bookmark = UserDefaults.standard.data(forKey: "mactube.download.destination") {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], bookmarkDataIsStale: &stale) {
                destination = url
            }
        }
    }

    func chooseDestination() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = destination
        if await panel.begin() == .OK, let url = panel.url {
            useDestination(url)
        }
    }
    func useDestination(_ url: URL) {
        destination = url
        if let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: "mactube.download.destination")
        }
    }
    private func updateJob(_ id: UUID, status: String, progress: Double? = nil, url: URL? = nil, detail: String? = nil, persist: Bool = true) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].status = status
        if let progress { jobs[index].progress = progress }
        if let url { jobs[index].fileURL = url }
        jobs[index].detail = detail
        if persist, let data = try? JSONEncoder().encode(jobs) { UserDefaults.standard.set(data, forKey: "mactube.download.jobs") }
    }
    func download(video: Video, height: Int?, audioOnly: Bool) {
        guard !state.isActive else { return }
        generation = UUID()
        let job = generation
        jobs.insert(MacDownloadRecord(id: job, title: video.title, status: "Active", progress: 0, date: Date()), at: 0)
        if jobs.count > 50 { jobs = Array(jobs.prefix(50)) }
        updateJob(job, status: "Active")
        let request = YTDLPDownloadRequest(
            videoID: video.id, height: height, audioOnly: audioOnly, destination: destination)
        state = .fetching
        completedURL = nil
        pending = Data()
        downloadTask = Task { [self] in
            let access = request.destination.startAccessingSecurityScopedResource()
            defer { if access { request.destination.stopAccessingSecurityScopedResource() } }
            do {
                let args = try request.arguments()
                let output = try await YTDLPProcessRunner().run(arguments: args, timeout: .seconds(21_600)) {
                    [weak self] chunk in
                    await self?.receive(chunk, job: job)
                }
                try Task.checkCancellation()
                let url = try YTDLPDownloadRequest.result(in: output, destination: request.destination)
                guard generation == job else { return }
                completedURL = url
                DownloadStore.shared.add(
                        DownloadedVideo(
                            videoId: video.id, title: video.title,
                            channelTitle: video.channelTitle, thumbnailURL: video.thumbnailURL,
                            duration: video.duration ?? 0,
                            fileURL: url, downloadedAt: Date()))
                MacMediaLibrary.shared.refresh()
                updateJob(job, status: "Completed", progress: 1, url: url)
                state = .done
            } catch is CancellationError {
                guard generation == job else { return }
                updateJob(job, status: "Cancelled", detail: "Retry in the same folder to resume partial files.")
                state = .failed("Cancelled. Retry in the same folder to resume partial files.")
            } catch {
                guard generation == job else { return }
                let message =
                    (error as? YTDLPStreamResolver.Failure)?.rawValue
                    ?? (error as? LocalizedError)?.errorDescription
                    ?? "Download failed. Check folder permissions and free space."
                updateJob(job, status: "Failed", detail: message)
                state = .failed(message + " Retry in the same folder to resume partial files.")
            }
        }
    }
    private func receive(_ chunk: Data, job: UUID) {
        guard generation == job else { return }
        pending.append(chunk)
        while let end = pending.firstIndex(of: 10) {
            let line = pending.prefix(upTo: end)
            if let progress = YTDLPDownloadRequest.progress(in: Data(line)) {
                updateJob(job, status: "Active", progress: progress, persist: false)
                state = progress >= 1 ? .saving : .downloading(progress: progress)
            }
            pending.removeSubrange(...end)
        }
    }
    public func reset() {
        generation = UUID()
        downloadTask?.cancel()
        downloadTask = nil
        state = .idle
    }
    func cancel() { downloadTask?.cancel() }
}
#endif
