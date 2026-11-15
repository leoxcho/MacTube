#if os(macOS)
import SmartTubeIOSCore
import SwiftUI

/// Playback context is independent of watch geometry and always uses the shared session.
struct MacWatchPlaybackContext: View {
    let current: Video
    var onPlay: (Video) -> Void
    @Environment(\.macNavigationState) private var navigation
    @State private var context = MacPlaylistQueueContext.shared
    @State private var expanded = true
    @State private var local: [MacMediaEntry] = []
    @State private var playlists = MacMediaPlaylistStore.shared
    @State private var library = MacMediaLibrary.shared

    private var queueActive: Bool { current.playlistId == CurrentQueueStore.playlistID && current.playlistIndex != nil }
    private var contextTaskID: String {
        [current.id, current.playlistId ?? "", String(current.playlistIndex ?? -1), String(library.entries.count)].joined(separator: ":")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if queueActive {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        if let first = context.videos.first {
                            Group {
                                if let path = first.localFileURL?.path {
                                    if let entry = library.entries.first(where: { $0.id == path }) { MacLocalMediaArtwork(entry: entry) }
                                    else { Image(systemName: "music.note.list") }
                                } else if current.localFileURL == nil { MacThumbnailImage(url: context.artworkURL ?? first.thumbnailURL) }
                                else { Image(systemName: "play.rectangle") }
                            }.aspectRatio(16 / 9, contentMode: .fit).frame(width: 60)
                        }
                        VStack(alignment: .leading) {
                            Text(context.title).font(.headline)
                            Text("\((current.playlistIndex ?? 0) + context.windowOffset + 1) of \(context.videos.count + context.windowOffset)\(context.hasMore ? "+" : "")").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.up" : "chevron.down") }.help("Collapse or expand playlist")
                    }
                    HStack {
                        Button("Play All", systemImage: "play.fill") {
                            Task { if let first = await context.restartOrFirst() { onPlay(first) } }
                        }
                        Button("Shuffle", systemImage: "shuffle") {
                            Task { if let first = await context.shuffleAndFirst() { onPlay(first) } }
                        }
                        Toggle("Repeat", isOn: $playlists.repeatQueue).toggleStyle(.checkbox)
                    }.controlSize(.small)
                    if expanded {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 6) {
                                    ForEach(Array(context.videos.enumerated()), id: \.offset) { item in
                                        HStack(alignment: .top, spacing: 7) {
                                            Text(item.offset == current.playlistIndex ? "▶" : String(item.offset + context.windowOffset + 1)).font(.caption).frame(width: 24)
                                            Button {
                                                Task { if let video = await CurrentQueueStore.shared.videoAt(index: item.offset) { onPlay(video) } }
                                            } label: {
                                                HStack(alignment: .top) {
                                                    Group {
                                                        if let path = item.element.localFileURL?.path {
                                                            if let entry = library.entries.first(where: { $0.id == path }) { MacLocalMediaArtwork(entry: entry) }
                                                            else { Image(systemName: "play.rectangle") }
                                                        } else if current.localFileURL == nil { MacThumbnailImage(url: item.element.thumbnailURL) }
                                                        else { Image(systemName: "play.rectangle") }
                                                    }.aspectRatio(16 / 9, contentMode: .fit).frame(width: 80)
                                                    Text(item.element.title).font(.caption).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                                }.contentShape(Rectangle())
                                            }.buttonStyle(.plain)
                                            Button { Task { await context.remove(at: item.offset) } } label: { Image(systemName: "minus.circle") }.help("Remove from queue")
                                        }.padding(6).background(item.offset == current.playlistIndex ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 7)).id(item.offset)
                                    }
                                }
                            }.frame(maxHeight: 340)
                                .onChange(of: current.playlistIndex, initial: true) { _, index in if let index { proxy.scrollTo(index, anchor: .center) } }
                        }
                        if context.hasMore && (current.playlistIndex ?? 0) >= context.videos.count - 100 {
                            Button("Load more playlist items") {
                                Task { _ = await context.next(after: context.videos.count - 1); await context.refresh() }
                            }
                        }
                        if let error = context.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                    }
                }.padding(12).macGlassSurface()
            }
            if current.localFileURL != nil {
                Text("More offline videos").font(.headline)
                if local.isEmpty { Text("No other available local videos in the indexed library.").font(.caption).foregroundStyle(.secondary) }
                ForEach(local) { entry in
                    Button { onPlay(entry.video) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            MacLocalMediaArtwork(entry: entry).aspectRatio(16 / 9, contentMode: .fit).frame(width: 128)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.title).font(.callout.weight(.medium)).lineLimit(2)
                                Text(entry.channel).font(.caption).foregroundStyle(.secondary)
                                MacLocalWatchProgress(videoID: entry.video.id)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).padding(8).macMediaCard().contextMenu { MacMediaItemMenu(entry: entry, onPlay: onPlay) }
                }
            }
        }
        .task(id: contextTaskID) {
            local = []
            if queueActive { await context.refresh() }
            guard let file = current.localFileURL else { local = []; return }
            let entries = MacCollectionOwnership.recommendations(for: current, section: navigation?.route.section)
            let paths = Set(playlists.playlists.filter { $0.filePaths.contains(file.path) }.flatMap(\.filePaths))
            let folders = MacCustomLibraryStore.shared.libraries.filter { library in library.folderPaths.contains { file.path.hasPrefix($0 + "/") } }.flatMap(\.folderPaths)
            let title = current.title
            let creator = current.channelTitle
            let ranked = await Task.detached(priority: .utility) {
                Self.rank(entries: entries, file: file, title: title, creator: creator, playlistPaths: paths, libraryFolders: folders)
            }.value
            guard !Task.isCancelled else { return }
            local = ranked
        }
    }
    nonisolated private static func words(in title: String) -> Set<String> {
        let pieces: [Substring] = title.lowercased().split(whereSeparator: { (character: Character) in !character.isLetter })
        var result = Set<String>()
        for piece in pieces where piece.count > 2 { result.insert(String(piece)) }
        return result
    }

    nonisolated private static func rank(entries: [MacMediaEntry], file: URL, title: String, creator: String,
                                        playlistPaths: Set<String>, libraryFolders: [String]) -> [MacMediaEntry] {
        let terms: Set<String> = words(in: title)
        let parent: URL = file.deletingLastPathComponent()
        var scored: [(entry: MacMediaEntry, score: Int)] = []
        for entry in entries {
            guard entry.isAvailable, !entry.isAudio, entry.fileURL != file else { continue }
            var score: Int = 0
            if playlistPaths.contains(entry.id) { score += 100 }
            if entry.fileURL.deletingLastPathComponent() == parent { score += 70 }
            for folder in libraryFolders {
                if entry.id.hasPrefix(folder + "/") { score += 30; break }
            }
            if !creator.isEmpty && entry.channel == creator { score += 20 }
            let overlap: Set<String> = terms.intersection(words(in: entry.title))
            score += overlap.count * 8
            scored.append((entry: entry, score: score))
        }
        scored.sort { (left: (entry: MacMediaEntry, score: Int), right: (entry: MacMediaEntry, score: Int)) -> Bool in
            if left.score != right.score { return left.score > right.score }
            return left.entry.modified > right.entry.modified
        }
        var result: [MacMediaEntry] = []
        for item in scored.prefix(24) { result.append(item.entry) }
        return result
    }

}
#endif
