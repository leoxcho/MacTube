#if os(macOS)
import AppKit
@preconcurrency import AVFoundation
import CoreServices
import CryptoKit
import Foundation
import ImageIO
import Observation
import SmartTubeIOSCore

struct MacMediaFolder: Codable, Identifiable, Sendable {
    var id: String { url.path }
    var url: URL
    var bookmark: Data?
    var recursive: Bool? = true
}
struct MacMediaEntry: Codable, Identifiable, Sendable {
    var id: String { fileURL.path }
    var fileURL: URL
    var title: String
    var channel: String
    var album: String? = nil
    var trackNumber: Int? = nil
    var originalVideoID: String?
    var duration: Double
    var thumbnailURL: URL?
    var isAudio: Bool
    var bytes: Int64
    var modified: Date
    var fingerprint: String
    var available: Bool? = true
    var isAvailable: Bool { available != false }
    var video: Video {
        var value = Video(id: "local-" + fileURL.path, title: title, channelTitle: channel,
                          thumbnailURL: thumbnailURL, duration: duration)
        value.localFileURL = fileURL
        return value
    }
}

/// Folder scopes are owned here for the lifetime of all playback and scanning operations.
@MainActor @Observable
final class MacMediaLibrary {
    static let shared = MacMediaLibrary()
    private(set) var folders: [MacMediaFolder] = []
    @ObservationIgnored private var musicRoots: [MacMediaFolder] = []
    private var scanRoots: [MacMediaFolder] { folders + musicRoots }
    private(set) var entries: [MacMediaEntry] = []
    private(set) var isScanning = false
    var error: String?
    @ObservationIgnored private var scopes: [URL] = []
    @ObservationIgnored private var stream: FSEventStreamRef?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var musicScanTask: Task<Void, Never>?
    @ObservationIgnored private var musicGeneration = UUID()
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var excluded: Set<String> = []
    private static let folderKey = "mactube.library.folders.v1"
    private static let excludedKey = "mactube.library.excluded.v1"
    nonisolated private static var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacTube/MediaLibrary.json")
    }
    private init() {
        // Restore Music roots from its own configuration before the initial scan.
        // Loading this store reads no shared index and cannot infer membership.
        let sources = MacMusicLibraryStore.shared.folders + MacMusicLibraryStore.shared.files
        musicRoots = sources.map { MacMediaFolder(url: $0.url, bookmark: $0.bookmark) }
        for source in sources where source.url.startAccessingSecurityScopedResource() { scopes.append(source.url) }
        excluded = Set(UserDefaults.standard.stringArray(forKey: Self.excludedKey) ?? [])
        if let data = UserDefaults.standard.data(forKey: Self.folderKey),
           let saved = try? JSONDecoder().decode([MacMediaFolder].self, from: data) {
            for var folder in saved {
                if let bookmark = folder.bookmark {
                    var stale = false
                    if let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], bookmarkDataIsStale: &stale) {
                        folder.url = resolved
                        if stale { folder.bookmark = try? resolved.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) }
                    }
                }
                folders.append(folder)
                if folder.url.startAccessingSecurityScopedResource() { scopes.append(folder.url) }
            }
        }
        if let data = try? Data(contentsOf: Self.cacheURL), let saved = try? JSONDecoder().decode([MacMediaEntry].self, from: data) {
            entries = saved.filter { !excluded.contains($0.id) && contains($0.fileURL) }
        }
        // Index only explicit library sources and MacTube download records.
        // A new installation never imports the user's Downloads folder implicitly.
        startWatching(); refresh()
    }
    func contains(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        if DownloadStore.shared.entries.contains(where: { $0.fileURL.resolvingSymlinksInPath().standardizedFileURL.path == path }) { return true }
        return scanRoots.contains {
            let root = $0.url.resolvingSymlinksInPath().standardizedFileURL.path
            return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }
    func chooseFolders() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = "Add to Library"
        if await panel.begin() == .OK { for url in panel.urls { addFolder(url) } }
    }
    func addFolder(_ url: URL) {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        guard !folders.contains(where: { $0.url.resolvingSymlinksInPath().standardizedFileURL == canonical }) else { return }
        let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        if url.startAccessingSecurityScopedResource() { scopes.append(url) }
        folders.append(MacMediaFolder(url: url, bookmark: bookmark))
        persistFolders(); startWatching(); refresh()
    }
    /// Music retains its own persisted configuration and security bookmarks.
    /// Register scan roots without adding them to Manage Libraries.
    func setMusicSources(_ sources: [MacMusicSource]) {
        musicRoots = sources.map { MacMediaFolder(url: $0.url, bookmark: $0.bookmark) }
        startWatching()
        refresh(onlyMusic: true)
    }

    /// Individual imports retain their own bookmark; their parent is not imported.
    func addFile(_ url: URL) { addFolder(url) }

    /// Configuration removal invalidates pending scans without releasing scopes
    /// that can still be used by playback, playlists or another collection.
    func invalidateCollectionWork() {
        debounceTask?.cancel()
        refresh()
    }
    func setRecursive(_ folder: MacMediaFolder, _ recursive: Bool) {
        guard let index = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        folders[index].recursive = recursive; persistFolders(); refresh()
    }
    var primaryFolder: String? { UserDefaults.standard.string(forKey: "mactube.library.primary") }
    func setPrimary(_ folder: MacMediaFolder) {
        UserDefaults.standard.set(folder.id, forKey: "mactube.library.primary")
        VideoDownloadService.shared.useDestination(folder.url)
    }
    func removeFolder(_ folder: MacMediaFolder) {
        folders.removeAll { $0.id == folder.id }
        if let index = scopes.firstIndex(of: folder.url) { scopes.remove(at: index).stopAccessingSecurityScopedResource() }
        entries.removeAll { !contains($0.fileURL) }
        persistFolders(); startWatching(); refresh()
    }
    func isHidden(_ path: String) -> Bool { excluded.contains(path) }
    func hide(_ entry: MacMediaEntry) {
        excluded.insert(entry.id)
        UserDefaults.standard.set(Array(excluded), forKey: Self.excludedKey)
        entries.removeAll { $0.id == entry.id }; saveCache()
    }
    func restoreHidden() {
        excluded.removeAll(); UserDefaults.standard.removeObject(forKey: Self.excludedKey); refresh()
    }
    func delete(_ entry: MacMediaEntry) {
        do {
            guard contains(entry.fileURL) else { return }
            try FileManager.default.trashItem(at: entry.fileURL, resultingItemURL: nil)
            entries.removeAll { $0.id == entry.id }; saveCache()
        } catch { self.error = error.localizedDescription }
    }
    func refresh(onlyMusic: Bool = false) {
        if onlyMusic { musicScanTask?.cancel(); musicGeneration = UUID() }
        else { scanTask?.cancel(); generation = UUID() }
        let token = onlyMusic ? musicGeneration : generation
        let imported = onlyMusic ? [] : DownloadStore.shared.entries
        var roots = onlyMusic ? musicRoots : self.scanRoots
        for download in imported where !roots.contains(where: { $0.url == download.fileURL }) {
            roots.append(MacMediaFolder(url: download.fileURL, bookmark: nil))
        }
        let scanRoots = roots
        let previous = entries, excluded = excluded
        isScanning = true
        let task = Task {
            let worker = Task.detached(priority: .utility) { await Self.scan(roots: scanRoots, previous: previous, excluded: excluded, imported: imported) }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, (onlyMusic ? musicGeneration : generation) == token else { return }
            if onlyMusic {
                // Refresh Music's sources only. Other collections keep their cache.
                let refreshed = Set(result.map(\.id))
                let retained = entries.filter { entry in
                    !refreshed.contains(entry.id) && !scanRoots.contains { root in
                        entry.fileURL == root.url || entry.fileURL.path.hasPrefix(root.url.path + "/")
                    }
                }
                entries = retained + result
            } else {
                // A Music source may have been added while this shared scan ran.
                let indexed = Set(result.map(\.id))
                let addedMusic = entries.filter { entry in
                    !indexed.contains(entry.id) && musicRoots.contains { root in
                        !scanRoots.contains(where: { $0.url == root.url }) &&
                        (entry.fileURL == root.url || entry.fileURL.path.hasPrefix(root.url.path + "/"))
                    }
                }
                entries = result + addedMusic
            }
            isScanning = false; saveCache()
        }
        if onlyMusic { musicScanTask = task } else { scanTask = task }
    }
    private func persistFolders() {
        if let data = try? JSONEncoder().encode(folders) { UserDefaults.standard.set(data, forKey: Self.folderKey) }
    }
    private func saveCache() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: Self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.cacheURL, options: .atomic)
    }
    private func changed() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            self?.refresh()
        }
    }
    private func startWatching() {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil }
        guard !scanRoots.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let library = Unmanaged<MacMediaLibrary>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in library.changed() }
        }
        stream = FSEventStreamCreate(nil, callback, &context, scanRoots.map { $0.url.path } as CFArray,
                                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1,
                                    FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes))
        if let stream {
            FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            if !FSEventStreamStart(stream) { error = "Folder monitoring unavailable. Use Refresh to update the library." }
        }
    }
    @ObservationIgnored private var artworkCache = NSCache<NSURL, NSImage>()
    func artwork(_ url: URL) -> NSImage? {
        if let image = artworkCache.object(forKey: url as NSURL) { return image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 640,
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        artworkCache.totalCostLimit = 32 * 1024 * 1024
        artworkCache.setObject(image, forKey: url as NSURL, cost: cg.bytesPerRow * cg.height)
        return image
    }
    nonisolated private static func videoID(in name: String) -> String? {
        guard let range = name.range(of: "\\[[A-Za-z0-9_-]{11}\\]", options: .regularExpression) else { return nil }
        return String(name[range].dropFirst().dropLast())
    }
    nonisolated private static func files(in root: URL, options: FileManager.DirectoryEnumerationOptions, extensions: Set<String>) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey], options: options) else { return [] }
        var result: [URL] = []
        while let file = walker.nextObject() as? URL {
            if Task.isCancelled { break }
            if extensions.contains(file.pathExtension.lowercased()) { result.append(file) }
        }
        return result
    }
    nonisolated private static func scan(roots: [MacMediaFolder], previous: [MacMediaEntry], excluded: Set<String>, imported: [DownloadedVideo]) async -> [MacMediaEntry] {
        let fm = FileManager.default
        let manifest = Dictionary(imported.map { ($0.fileURL.path, $0) }, uniquingKeysWith: { first, _ in first })
        let audio: Set<String> = ["m4a", "mp3", "aac", "wav", "flac", "aiff", "ogg", "opus"]
        let supported = audio.union(["mp4", "m4v", "mov", "mkv", "webm"])
        let cache = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var found: [String: MacMediaEntry] = [:]
        for folder in roots {
            let root = folder.url
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
                let prefix = root.path + "/"
                for var entry in previous where (entry.fileURL == root || entry.fileURL.path.hasPrefix(prefix)) && !excluded.contains(entry.id) {
                    entry.available = false; found[entry.id] = entry
                }
                continue
            }
            let options: FileManager.DirectoryEnumerationOptions = folder.recursive == false ? [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants] : [.skipsHiddenFiles, .skipsPackageDescendants]
            let files = isDirectory.boolValue ? Self.files(in: root, options: options, extensions: supported) : [root]
            let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
            for file in files {
                let canonicalFile = file.resolvingSymlinksInPath().standardizedFileURL.path
                guard canonicalFile == canonicalRoot || canonicalFile.hasPrefix(canonicalRoot + "/") else { continue }
                if Task.isCancelled { return Array(found.values) }
                guard supported.contains(file.pathExtension.lowercased()), !excluded.contains(file.path),
                      let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]), values.isRegularFile == true else { continue }
                let stem = file.deletingPathExtension()
                let sidecar = stem.appendingPathExtension("info.json")
                let sideDate = (try? sidecar.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
                let modified = values.contentModificationDate ?? .distantPast
                let fingerprint = "metadata2-\(values.fileSize ?? 0)-\(modified.timeIntervalSince1970)-\(sideDate)"
                if var old = cache[file.path], old.fingerprint == fingerprint { old.available = true; found[file.path] = old; continue }
                let fallbackStem = stem.lastPathComponent.replacingOccurrences(of: " \\[(?:[0-9]+p|best|audio)\\]$", with: "", options: .regularExpression)
                let fallbackSidecar = stem.deletingLastPathComponent().appendingPathComponent(fallbackStem).appendingPathExtension("info.json")
                let data = (try? Data(contentsOf: sidecar)) ?? (try? Data(contentsOf: fallbackSidecar))
                let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                let registered = manifest[file.path]
                var duration = (json["duration"] as? Double) ?? registered?.duration ?? 0
                if duration <= 0 {
                    let time = try? await AVURLAsset(url: file).load(.duration)
                    if let seconds = time?.seconds, seconds.isFinite { duration = max(0, seconds) }
                }
                var embeddedTitle: String?, embeddedChannel: String?, embeddedArtwork: URL?, embeddedAlbum: String?
                var embeddedTrack: Int?
                if json["title"] == nil || json["channel"] == nil {
                    let asset = AVURLAsset(url: file)
                    if let metadata = try? await asset.load(.commonMetadata) {
                        for item in metadata {
                            if item.commonKey == .commonKeyTitle { embeddedTitle = try? await item.load(.stringValue) }
                            if item.commonKey == .commonKeyArtist { embeddedChannel = try? await item.load(.stringValue) }
                            if item.commonKey == .commonKeyAlbumName { embeddedAlbum = try? await item.load(.stringValue) }
                            if item.identifier?.rawValue == "id3/TRCK", let text = try? await item.load(.stringValue) { embeddedTrack = Int(text.components(separatedBy: "/")[0]) }
                            if item.commonKey == .commonKeyArtwork, let bytes = try? await item.load(.dataValue) {
                                let key = SHA256.hash(data: Data((file.path + fingerprint).utf8)).map { String(format: "%02x", $0) }.joined()
                                let directory = Self.cacheURL.deletingLastPathComponent().appendingPathComponent("Artwork")
                                try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
                                let url = directory.appendingPathComponent(key).appendingPathExtension("jpg")
                                if (try? bytes.write(to: url, options: .atomic)) != nil { embeddedArtwork = url }
                            }
                        }
                    }
                }
                let thumb = ["jpg", "jpeg", "png", "webp"].map { stem.appendingPathExtension($0) }.first { fm.fileExists(atPath: $0.path) }
                found[file.path] = MacMediaEntry(fileURL: file, title: json["title"] as? String ?? registered?.title ?? embeddedTitle ?? stem.lastPathComponent,
                    channel: json["channel"] as? String ?? json["uploader"] as? String ?? registered?.channelTitle ?? embeddedChannel ?? "Local media",
                    album: json["album"] as? String ?? embeddedAlbum, trackNumber: json["track_number"] as? Int ?? embeddedTrack,
                    originalVideoID: json["id"] as? String ?? registered?.videoId ?? Self.videoID(in: stem.lastPathComponent), duration: duration, thumbnailURL: thumb ?? embeddedArtwork,
                    isAudio: audio.contains(file.pathExtension.lowercased()), bytes: Int64(values.fileSize ?? 0), modified: modified, fingerprint: fingerprint)
            }
        }
        return found.values.sorted { $0.modified > $1.modified }
    }
}
#endif
