#if os(macOS)
import Foundation
import SmartTubeIOSCore

/// Collection membership is separate from the shared metadata/security-scope index.
/// Existing file IDs and bookmarks are never rewritten or removed by this filter.
@MainActor enum MacCollectionOwnership {
    static var downloads: [MacMediaEntry] {
        let library = MacMediaLibrary.shared
        let indexed = Dictionary(library.entries.map { ($0.fileURL.standardizedFileURL.path, $0) }, uniquingKeysWith: { first, _ in first })
        return DownloadStore.shared.entries.compactMap { record in
            guard !library.isHidden(record.fileURL.path) else { return nil }
            if let entry = indexed[record.fileURL.standardizedFileURL.path] { return entry }
            let audio = ["mp3", "m4a", "aac", "flac", "wav", "aiff", "ogg", "opus"].contains(record.fileURL.pathExtension.lowercased())
            return MacMediaEntry(fileURL: record.fileURL, title: record.title, channel: record.channelTitle,
                originalVideoID: record.videoId, duration: record.duration, thumbnailURL: nil,
                isAudio: audio, bytes: 0, modified: record.downloadedAt, fingerprint: "download-record", available: false)
        }
    }
    static func recommendations(for video: Video, section: String?) -> [MacMediaEntry] {
        let all = MacMediaLibrary.shared.entries
        guard let url = video.localFileURL else { return [] }
        if let section, section.hasPrefix("local:"), let id = UUID(uuidString: String(section.dropFirst(6))),
           let library = MacCustomLibraryStore.shared.libraries.first(where: { $0.id == id }) {
            return MacCustomLibraryStore.shared.entries(for: library)
        }
        if section == "music" { return all.filter { MacMusicLibraryStore.shared.contains($0) } }
        if section == "downloads" { return downloads }
        // Restored/queued playback without a browsing origin stays in its known
        // explicit collection, falling back only to the current file's folder.
        let libraries = MacCustomLibraryStore.shared.libraries.filter { item in
            item.folderPaths.contains { url.path.hasPrefix($0 + "/") }
        }
        if let library = libraries.first { return MacCustomLibraryStore.shared.entries(for: library) }
        if let entry = all.first(where: { $0.fileURL == url }), MacMusicLibraryStore.shared.contains(entry) {
            return all.filter { MacMusicLibraryStore.shared.contains($0) }
        }
        if DownloadStore.shared.entries.contains(where: { $0.fileURL == url }) { return downloads }
        return all.filter { $0.fileURL.deletingLastPathComponent() == url.deletingLastPathComponent() }
    }
}
#endif
