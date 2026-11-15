#if os(macOS)
import AppKit
import Foundation
import Observation
import SmartTubeIOSCore
import UniformTypeIdentifiers

struct MacMusicSource: Codable, Identifiable {
    var id: String { url.path }
    var url: URL
    var bookmark: Data?
    // Only selections made through Music establish membership.
    var ownership: String? = "music"
}

/// Music owns membership; the shared library owns metadata indexing and playback scopes.
@MainActor @Observable
final class MacMusicLibraryStore {
    static let shared = MacMusicLibraryStore()
    private(set) var folders: [MacMusicSource] = []
    private(set) var files: [MacMusicSource] = []
    private(set) var playlistIDs: Set<UUID> = []
    var error: String?
    @ObservationIgnored private var prepared = false
    @ObservationIgnored private var scopes: [String: URL] = [:]
    private let folderKey = "mactube.music.folders.v1"
    private let fileKey = "mactube.music.files.v1"
    private let migrationKey = "mactube.music.membership.migrated.v1"
    private let playlistKey = "mactube.music.playlists.v1"

    private init() {
        folders = Self.loadSources("mactube.music.folders.v1")
        files = Self.loadSources("mactube.music.files.v1")
        playlistIDs = Set((UserDefaults.standard.stringArray(forKey: playlistKey) ?? []).compactMap(UUID.init(uuidString:)))
    }
    private static func loadSources(_ key: String) -> [MacMusicSource] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode([MacMusicSource].self, from: data) else { return [] }
        return saved.map { source in
            var value = source
            if let bookmark = source.bookmark {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], bookmarkDataIsStale: &stale) {
                    value.url = url
                    if stale { value.bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) }
                }
            }
            return value
        }
    }
    func prepareIfNeeded() {
        guard !prepared else { return }
        prepared = true
        // The v1 migration inferred Music ownership from unassigned shared roots.
        // A metadata index is not proof of membership; never adopt those roots.
        UserDefaults.standard.set(true, forKey: migrationKey)
        for source in folders + files { retainScope(source) }
        syncIndexSources()
        save()
    }
    private func syncIndexSources() {
        MacMediaLibrary.shared.setMusicSources(folders + files)
    }
    func contains(_ entry: MacMediaEntry) -> Bool {
        guard entry.isAudio else { return false }
        return containsPath(entry.fileURL)
    }
    func containsPath(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if files.contains(where: { $0.url.standardizedFileURL.path == path }) { return true }
        return folders.contains { source in
            let root = source.url.standardizedFileURL.path
            return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }
    func addDownloaded(_ entry: MacMediaEntry) {
        guard entry.isAudio else { return }
        addFile(entry.fileURL)
    }
    func importFiles() async {
        let panel = NSOpenPanel()
        panel.title = "Import Music Files"
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio]
        guard await panel.begin() == .OK else { return }
        for url in panel.urls { addFile(url) }
    }
    func chooseFolders() async {
        let panel = NSOpenPanel()
        panel.title = "Add Music Folders"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        guard await panel.begin() == .OK else { return }
        for url in panel.urls { addFolder(url) }
    }
    func addFile(_ url: URL) {
        prepareIfNeeded()
        guard !files.contains(where: { $0.id == url.path }) else { return }
        let source = makeSource(url)
        files.append(source); retainScope(source); save()
        syncIndexSources()
    }
    func addFolder(_ url: URL) {
        prepareIfNeeded()
        guard !folders.contains(where: { $0.id == url.path }) else { return }
        let source = makeSource(url)
        folders.append(source); retainScope(source); save()
        syncIndexSources()
    }
    func removeFolder(_ id: String) { folders.removeAll { $0.id == id }; save(); syncIndexSources() }
    func removeFile(_ id: String) { files.removeAll { $0.id == id }; save(); syncIndexSources() }
    func refresh() { prepareIfNeeded(); MacMediaLibrary.shared.refresh(onlyMusic: true) }
    func addPlaylist(_ id: UUID) { playlistIDs.insert(id); save() }
    func removePlaylist(_ id: UUID) { playlistIDs.remove(id); save() }
    func adoptLegacyPlaylists() {
        let key = "mactube.music.playlists.migrated.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        for playlist in MacMediaPlaylistStore.shared.playlists where !playlist.filePaths.isEmpty {
            let entries = MacMediaPlaylistStore.shared.entries(for: playlist)
            if !entries.isEmpty && entries.allSatisfy({ contains($0) }) { playlistIDs.insert(playlist.id) }
        }
        UserDefaults.standard.set(true, forKey: key)
        save()
    }
    private func makeSource(_ url: URL) -> MacMusicSource {
        do { return MacMusicSource(url: url, bookmark: try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)) }
        catch { self.error = "Could not preserve access to \(url.lastPathComponent): \(error.localizedDescription)"; return MacMusicSource(url: url) }
    }
    private func retainScope(_ source: MacMusicSource) {
        guard scopes[source.id] == nil else { return }
        if source.url.startAccessingSecurityScopedResource() { scopes[source.id] = source.url }
    }
    // Keep granted scopes alive for active playback and existing playlist items.
    // Removing a source changes membership, never an in-flight playback lease.
    private func save() {
        if let data = try? JSONEncoder().encode(folders) { UserDefaults.standard.set(data, forKey: folderKey) }
        if let data = try? JSONEncoder().encode(files) { UserDefaults.standard.set(data, forKey: fileKey) }
        UserDefaults.standard.set(playlistIDs.map(\.uuidString), forKey: playlistKey)
    }
}
#endif
