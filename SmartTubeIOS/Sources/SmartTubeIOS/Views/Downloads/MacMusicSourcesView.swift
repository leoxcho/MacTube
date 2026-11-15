#if os(macOS)
import AppKit
import SmartTubeIOSCore
import SwiftUI

struct MacMusicSourcesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var music = MacMusicLibraryStore.shared
    @State private var pendingRemoval: MacMusicSource?
    @State private var removingFolder = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Manage Music Folders and Files").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
            }
            HStack {
                Button("Import Music Files…") { Task { await music.importFiles() } }
                Button("Add Music Folder…") { Task { await music.chooseFolders() } }
                Button("Refresh Music Library") { music.refresh() }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Music Folders").font(.headline)
                    if music.folders.isEmpty { Text("No Music folders configured.").foregroundStyle(.secondary) }
                    ForEach(music.folders) { source in sourceRow(source, folder: true) }
                    Text("Individually Imported Files").font(.headline)
                    if music.files.isEmpty { Text("No individual music files imported.").foregroundStyle(.secondary) }
                    ForEach(music.files) { source in sourceRow(source, folder: false) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
            Text("Removing a source changes Music membership only. Original files, playlists, shared metadata and active playback are preserved. Disconnected drives remain configured.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).macWallpaperSurface()
            .confirmationDialog("Remove this Music source?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }), titleVisibility: .visible) {
                Button("Remove from Music", role: .destructive) {
                    guard let source = pendingRemoval else { return }
                    if removingFolder { music.removeFolder(source.id) } else { music.removeFile(source.id) }
                    pendingRemoval = nil
                }
                Button("Cancel", role: .cancel) { pendingRemoval = nil }
            } message: { Text("No files will be deleted or moved.") }
    }
    private func sourceRow(_ source: MacMusicSource, folder: Bool) -> some View {
        HStack(alignment: .top) {
            Image(systemName: folder ? "folder" : "music.note")
            VStack(alignment: .leading, spacing: 4) {
                Text(source.url.lastPathComponent).font(.headline)
                Text(source.url.path).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([source.url]) }
            Button(folder ? "Remove Music Folder" : "Remove Music File", role: .destructive) { removingFolder = folder; pendingRemoval = source }
        }.padding(12).macGlassSurface()
    }
}

/// Reuses offline playlist records, with separate Music playlist membership.
struct MacMusicPlaylistsView: View {
    var onPlay: (Video) -> Void
    @State private var store = MacMediaPlaylistStore.shared
    @State private var music = MacMusicLibraryStore.shared
    @State private var selection: UUID?
    @State private var name = ""
    @State private var pendingDelete: UUID?
    private var playlists: [MacOfflinePlaylist] { store.playlists.filter { music.playlistIDs.contains($0.id) } }
    private var selected: MacOfflinePlaylist? { playlists.first { $0.id == selection } }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    TextField("New music playlist", text: $name)
                    Button("Create") {
                        store.create(name.isEmpty ? "Music Playlist" : name)
                        if let created = store.playlists.last { music.addPlaylist(created.id); selection = created.id }
                        name = ""
                    }
                }
                List(selection: $selection) {
                    ForEach(playlists) { playlist in Text(playlist.name).tag(playlist.id) }
                }.scrollContentBackground(.hidden)
                Button("Remove Playlist", role: .destructive) { pendingDelete = selection }.disabled(selection == nil)
            }.padding().frame(minWidth: 230, idealWidth: 260, maxWidth: 300)
            Divider()
            if let selected {
                VStack(alignment: .leading) {
                    MacCollectionBrowser(title: selected.name, entries: store.entries(for: selected).filter { music.containsPath($0.fileURL) }, onPlay: onPlay, preserveOrder: true)
                    Menu("Add Music to Playlist") {
                        ForEach(MacMediaLibrary.shared.entries.filter { music.contains($0) }) { entry in
                            Button(entry.title) { store.add([entry], to: selected.id) }
                        }
                    }.padding(.horizontal, 24).padding(.bottom, 16)
                }
            } else {
                Text("Create or select a Music playlist. Add imported songs through their context menu or collection selection controls.")
                    .foregroundStyle(.secondary).padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .confirmationDialog("Remove Music playlist?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Remove Playlist", role: .destructive) {
                guard let id = pendingDelete else { return }
                if selection == id { selection = nil }
                music.removePlaylist(id)
                store.playlists.removeAll { $0.id == id }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { Text("Original music files remain on disk.") }
    }
}
#endif
