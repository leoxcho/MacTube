#if os(macOS)
import AppKit
import SmartTubeIOSCore
import SwiftUI

struct MacLocalWatchProgress: View {
    let videoID: String
    @State private var fraction: Double = 0
    var body: some View {
        Group { if fraction > 0 { ProgressView(value: fraction).tint(.red).help("Resume at \(Int(fraction * 100))%") } }
            .task(id: videoID) { fraction = await VideoStateStore.shared.state(for: videoID)?.watchedFraction ?? 0 }
    }
}

struct MacCollectionBrowser: View {
    let title: String
    let entries: [MacMediaEntry]
    var onPlay: (Video) -> Void
    var preserveOrder = false
    @State private var query = ""
    @State private var sort = "Episode / filename"
    @State private var grid = true
    @State private var selected = Set<String>()
    @State private var playlists = MacMediaPlaylistStore.shared
    private var filtered: [MacMediaEntry] {
        let matching = entries.filter { query.isEmpty || ($0.title + " " + $0.channel + " " + ($0.album ?? "") + " " + $0.fileURL.path).localizedCaseInsensitiveContains(query) }
        if preserveOrder && sort == "Episode / filename" { return matching }
        return matching.sorted {
            switch sort {
            case "Artist": return $0.channel.localizedStandardCompare($1.channel) == .orderedAscending
            case "Album":
                if $0.album == $1.album { return ($0.trackNumber ?? 0) < ($1.trackNumber ?? 0) }
                return ($0.album ?? "").localizedStandardCompare($1.album ?? "") == .orderedAscending
            case "Newest": return $0.modified > $1.modified
            case "Title": return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            default: return $0.fileURL.path.localizedStandardCompare($1.fileURL.path) == .orderedAscending
            }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).font(.largeTitle.bold()); Spacer()
                Button("Play All") { play(false) }.disabled(filtered.isEmpty)
                Button("Shuffle") { play(true) }.disabled(filtered.isEmpty)
                Toggle("Repeat playlist", isOn: $playlists.repeatQueue).toggleStyle(.checkbox)
            }
            HStack {
                TextField("Search media, artists, albums or folders", text: $query).textFieldStyle(.roundedBorder)
                Picker("Sort", selection: $sort) { ForEach(["Episode / filename", "Title", "Artist", "Album", "Newest"], id: \.self) { Text($0) } }.frame(width: 190)
                Toggle("Grid", isOn: $grid).toggleStyle(.button)
                Menu("Add Selected to Playlist") {
                    ForEach(playlists.playlists) { playlist in Button(playlist.name) { playlists.add(filtered.filter { selected.contains($0.id) }, to: playlist.id) } }
                }.disabled(selected.isEmpty || playlists.playlists.isEmpty)
            }
            ScrollView {
                LazyVGrid(columns: grid ? [GridItem(.adaptive(minimum: 210, maximum: 310))] : [GridItem(.flexible())], alignment: .leading, spacing: 14) {
                    ForEach(Array(filtered.enumerated()), id: \.offset) { item in
                        let entry = item.element
                        HStack(alignment: .top) {
                            Toggle("Select \(entry.title)", isOn: Binding(get: { selected.contains(entry.id) }, set: { if $0 { selected.insert(entry.id) } else { selected.remove(entry.id) } })).labelsHidden().toggleStyle(.checkbox)
                            Button { if entry.isAvailable { playSelected(at: item.offset) } } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    if grid { MacLocalMediaArtwork(entry: entry).aspectRatio(16 / 9, contentMode: .fit) }
                                    Text(entry.title).font(.headline).lineLimit(2)
                                    MacLocalWatchProgress(videoID: entry.video.id)
                                    Text(entry.channel + (entry.album.map { " · " + $0 } ?? "")).font(.caption).foregroundStyle(.secondary)
                                    Text(entry.isAvailable ? entry.video.formattedDuration : "Storage unavailable").font(.caption).foregroundStyle(entry.isAvailable ? Color.secondary : Color.orange)
                                    if !grid { Text(entry.fileURL.deletingLastPathComponent().path).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain).contextMenu { MacMediaItemMenu(entry: entry, onPlay: onPlay, playSelection: { playSelected(at: item.offset) }) }
                        }.padding(10).macMediaCard()
                    }
                }
            }.scrollClipDisabled()
            Text("\(filtered.count) items · \(selected.count) selected").font(.caption).foregroundStyle(.secondary)
        }.padding(24).scrollContentBackground(.hidden)
    }
    private var playbackEntries: [MacMediaEntry] { preserveOrder ? entries : filtered }
    private func playSelected(at position: Int) {
        let visible = filtered
        guard visible.indices.contains(position) else { return }
        let chosen = visible[position]
        // Searching/sorting a playlist changes its display, not its queue order.
        // Count occurrences so repeated copies of the same file keep their slot.
        let occurrence = visible.prefix(position).filter { $0.id == chosen.id }.count
        let source = playbackEntries
        let matches = source.indices.filter { source[$0].id == chosen.id }
        guard matches.indices.contains(occurrence) else { return }
        let sourcePosition = matches[occurrence]
        let indexed = Array(source.enumerated()).filter { $0.element.isAvailable }
        guard let selectedIndex = indexed.firstIndex(where: { $0.offset == sourcePosition }) else { return }
        MacMediaQueue.start(indexed.map { $0.element.video }, at: selectedIndex, title: title, onPlay: onPlay)
    }
    private func play(_ shuffle: Bool) {
        MacMediaQueue.start(playbackEntries.filter(\.isAvailable).map(\.video), shuffle: shuffle, title: title, onPlay: onPlay)
    }

}

struct MacMediaItemMenu: View {
    let entry: MacMediaEntry
    var onPlay: (Video) -> Void
    var playSelection: (() -> Void)? = nil
    var body: some View {
        Button("Play Offline") {
            if let playSelection { playSelection() }
            else { MacMediaQueue.start([entry.video], title: "Offline Video", onPlay: onPlay) }
        }.disabled(!entry.isAvailable)
        Button("Play Next") { MacMediaQueue.add(entry.video, next: true) }
        Button("Add to Queue") { MacMediaQueue.add(entry.video) }
        Menu("Add to Offline Playlist") {
            ForEach(MacMediaPlaylistStore.shared.playlists) { playlist in Button(playlist.name) { MacMediaPlaylistStore.shared.add([entry], to: playlist.id) } }
        }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.fileURL]) }
    }
}

struct MacCustomLibraryView: View {
    let libraryID: UUID
    var onPlay: (Video) -> Void
    var body: some View {
        if let library = MacCustomLibraryStore.shared.libraries.first(where: { $0.id == libraryID }) {
            MacCollectionBrowser(title: library.name, entries: MacCustomLibraryStore.shared.entries(for: library), onPlay: onPlay)
        } else { Text("Select a media library").frame(maxWidth: .infinity, maxHeight: .infinity) }
    }
}

struct MacOfflinePlaylistsView: View {
    var onPlay: (Video) -> Void
    @State private var store = MacMediaPlaylistStore.shared
    @State private var selection: UUID?
    @State private var name = ""
    var body: some View {
        HStack(spacing: 0) {
            VStack {
                HStack { TextField("New playlist", text: $name); Button("Create") { store.create(name); name = "" } }
                Button("Delete Selected Playlist", role: .destructive) { store.playlists.removeAll { $0.id == selection }; selection = nil }.disabled(selection == nil)
                List(selection: $selection) {
                    ForEach($store.playlists) { $playlist in
                        HStack {
                            if let entry = MacMediaLibrary.shared.entries.first(where: { $0.id == playlist.filePaths.first }) {
                                MacLocalMediaArtwork(entry: entry).frame(width: 48, height: 32).clipped()
                            } else { Image(systemName: "music.note.list").frame(width: 48, height: 32).foregroundStyle(.secondary) }
                            TextField("Playlist name", text: $playlist.name)
                        }.tag(playlist.id).listRowBackground(Color.clear)
                    }
                    .onDelete { store.playlists.remove(atOffsets: $0) }
                }
            }.padding().frame(width: 240).scrollContentBackground(.hidden)
            Divider()
            if let index = store.playlists.firstIndex(where: { $0.id == selection }) {
                VStack {
                    MacCollectionBrowser(title: store.playlists[index].name, entries: store.entries(for: store.playlists[index]), onPlay: onPlay, preserveOrder: true)
                    List {
                        ForEach(Array(store.playlists[index].filePaths.enumerated()), id: \.offset) { item in
                            HStack {
                                Text(URL(fileURLWithPath: item.element).lastPathComponent).lineLimit(1); Spacer()
                                Button("Up") { store.playlists[index].filePaths.swapAt(item.offset, item.offset - 1) }.disabled(item.offset == 0)
                                Button("Down") { store.playlists[index].filePaths.swapAt(item.offset, item.offset + 1) }.disabled(item.offset == store.playlists[index].filePaths.count - 1)
                                Button("Remove") { store.playlists[index].filePaths.remove(at: item.offset) }
                            }
                        }
                        .onMove { store.playlists[index].filePaths.move(fromOffsets: $0, toOffset: $1) }
                        .onDelete { store.playlists[index].filePaths.remove(atOffsets: $0) }
                    }.frame(height: 140).scrollContentBackground(.hidden)
                }
            } else { Text("Create or select an offline playlist. Add media through its context menu or a library’s multi-selection controls.").foregroundStyle(.secondary).padding().frame(maxWidth: .infinity) }
        }.scrollContentBackground(.hidden)
    }
}

struct MacQueuePanel: View {
    var onPlay: (Video) -> Void
    @State private var videos: [Video] = []
    var body: some View {
        VStack {
            HStack { Text("Current Queue").font(.title2); Spacer(); Button("Refresh") { Task { await reload() } }; Button("Clear") { Task { await CurrentQueueStore.shared.clear(); await reload() } } }
            List {
                ForEach(Array(videos.enumerated()), id: \.offset) { item in
                    HStack {
                        Button(item.element.title) { Task { if let video = await CurrentQueueStore.shared.videoAt(index: item.offset) { onPlay(video) } } }.buttonStyle(.plain)
                        Spacer()
                        Button("Up") { Task { await CurrentQueueStore.shared.move(from: IndexSet(integer: item.offset), to: item.offset - 1); await reload() } }.disabled(item.offset == 0)
                        Button("Down") { Task { await CurrentQueueStore.shared.move(from: IndexSet(integer: item.offset), to: item.offset + 2); await reload() } }.disabled(item.offset == videos.count - 1)
                        Button("Remove") { Task { await CurrentQueueStore.shared.remove(at: item.offset); await reload() } }
                    }
                }.onDelete { offsets in Task { for index in offsets.sorted(by: >) { await CurrentQueueStore.shared.remove(at: index) }; await reload() } }
                .onMove { source, destination in Task { await CurrentQueueStore.shared.move(from: source, to: destination); await reload() } }
            }
        }.padding().scrollContentBackground(.hidden).task { await reload() }
    }
    private func reload() async {
        videos = await CurrentQueueStore.shared.videos
        await MacPlaylistQueueContext.shared.refresh()
        if let vm = MacPlaybackSession.shared.activeModel, let current = vm.currentVideo,
           current.playlistId == CurrentQueueStore.playlistID {
            if let index = videos.firstIndex(where: { $0.id == current.id }) {
                vm.currentVideo?.playlistIndex = index
                vm.hasNext = index + 1 < videos.count
                vm.hasPrevious = index > 0
            } else {
                // The removed current item may finish; Next continues at its former successor.
                let cursor = min(max((current.playlistIndex ?? 0) - 1, -1), videos.count - 1)
                vm.currentVideo?.playlistIndex = cursor
                vm.hasNext = cursor + 1 < videos.count
                vm.hasPrevious = cursor >= 0
            }
        }
    }
}
#endif
