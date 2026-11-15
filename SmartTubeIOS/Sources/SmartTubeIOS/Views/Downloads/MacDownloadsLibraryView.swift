#if os(macOS)
import AppKit
import SwiftUI
import SmartTubeIOSCore

struct MacDownloadsLibraryView: View {
    var onPlay: (Video) -> Void
    @State private var library = MacMediaLibrary.shared
    @State private var query = ""
    @AppStorage("mactube.library.grid") private var grid = true
    @AppStorage("mactube.library.sort") private var sort = "Newest"
    @State private var filter = "All media"
    @State private var deleting: MacMediaEntry?
    @State private var foldersVisible = false
    @State private var jobsVisible = false
    @State private var jobFilter = "All"
    private var filtered: [MacMediaEntry] {
        let result = MacCollectionOwnership.downloads.filter {
            (filter == "All media" || (filter == "Audio" ? $0.isAudio : !$0.isAudio)) &&
            (query.isEmpty || ($0.title + " " + $0.channel + " " + ($0.originalVideoID ?? "")).localizedCaseInsensitiveContains(query))
        }
        return result.sorted {
            switch sort {
            case "Title": return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            case "Channel": return $0.channel.localizedStandardCompare($1.channel) == .orderedAscending
            case "Duration": return $0.duration > $1.duration
            case "Size": return $0.bytes > $1.bytes
            default: return $0.modified > $1.modified
            }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Downloads").font(.largeTitle.bold())
                    Text("Your videos and audio, available offline").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Play All") { MacMediaQueue.play(filtered.filter(\.isAvailable).map(\.video), title: "Downloads", onPlay: onPlay) }
                Button("Shuffle") { MacMediaQueue.play(filtered.filter(\.isAvailable).map(\.video), shuffle: true, title: "Downloads", onPlay: onPlay) }
                if library.isScanning { ProgressView().controlSize(.small).accessibilityLabel("Scanning library") }
                Button { library.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                Button { foldersVisible.toggle() } label: { Label("Folders", systemImage: "folder") }
            }
            HStack {
                TextField("Search titles, channels, or video IDs", text: $query).textFieldStyle(.roundedBorder)
                Picker("Media", selection: $filter) { ForEach(["All media", "Video", "Audio"], id: \.self) { Text($0) } }.frame(width: 140)
                Picker("Sort", selection: $sort) { ForEach(["Newest", "Title", "Channel", "Duration", "Size"], id: \.self) { Text($0) } }.frame(width: 150)
                Toggle(isOn: $grid) { Image(systemName: grid ? "square.grid.2x2" : "list.bullet") }
                    .toggleStyle(.button).accessibilityLabel("Grid layout")
            }
            if VideoDownloadService.shared.state.isActive {
                HStack {
                    switch VideoDownloadService.shared.state {
                    case .downloading(let progress): ProgressView(value: progress).frame(width: 180); Text("Downloading: \(Int(progress * 100))%")
                    case .saving: ProgressView().controlSize(.small); Text("Processing downloaded media…")
                    default: ProgressView().controlSize(.small); Text("Preparing download…")
                    }
                    Spacer()
                    Button("Cancel Download") { VideoDownloadService.shared.cancel() }
                }.font(.caption)
            }
            DisclosureGroup("Download Activity", isExpanded: $jobsVisible) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Status", selection: $jobFilter) {
                        ForEach(["All", "Active", "Completed", "Failed", "Cancelled", "Interrupted"], id: \.self) { Text($0) }
                    }.pickerStyle(.segmented)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(VideoDownloadService.shared.jobs.filter { jobFilter == "All" || $0.status == jobFilter }) { job in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(job.title).lineLimit(1)
                                        Text(job.detail ?? job.status).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if let url = job.fileURL { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                                    Text(job.status).font(.caption)
                                }
                            }
                        }
                    }.frame(maxHeight: 150)
                }.padding(.top, 8)
            }
            if foldersVisible { folderControls }
            if let error = library.error {
                HStack { Text(error).foregroundStyle(.red); Button("Dismiss") { library.error = nil } }
            }
            if filtered.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "arrow.down.to.line.circle").font(.system(size: 44)).foregroundStyle(.secondary)
                    Text(query.isEmpty ? "No local media found" : "No matching media").font(.title2)
                    Text("Media downloaded through MacTube appears here. Import other files in Music or a custom library.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Choose Download Location…") { Task { await VideoDownloadService.shared.chooseDestination() } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    if grid {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 320))], alignment: .leading, spacing: 22) {
                            ForEach(filtered) { entry in mediaItem(entry, compact: false) }
                        }
                    } else {
                        LazyVStack(spacing: 10) { ForEach(filtered) { entry in mediaItem(entry, compact: true) } }
                    }
                }.scrollClipDisabled()
                Text("\(filtered.count) items · \(ByteCountFormatter.string(fromByteCount: filtered.reduce(0) { $0 + $1.bytes }, countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(24).scrollContentBackground(.hidden)
        .alert("Move file to Trash?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Move to Trash", role: .destructive) { if let deleting { library.delete(deleting) }; deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text(deleting?.title ?? "") }
    }
    private var folderControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Download location").font(.headline)
            Text(VideoDownloadService.shared.destination.path).font(.caption).textSelection(.enabled)
            Text("Only MacTube download records appear here. Other indexed folders belong to Music or custom libraries.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Change Download Location…") { Task { await VideoDownloadService.shared.chooseDestination() } }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([VideoDownloadService.shared.destination]) }
                Button("Restore Hidden Downloads") { library.restoreHidden() }
            }
        }.padding(14).macGlassSurface()
    }
    private func mediaItem(_ entry: MacMediaEntry, compact: Bool) -> some View {
        Button { if entry.isAvailable { onPlay(entry.video) } else { library.error = "This library folder is unavailable. Reconnect its volume, then refresh." } } label: {
            Group {
                if compact {
                    HStack(spacing: 14) { artwork(entry).frame(width: 110, height: 64); details(entry); Spacer(); Text(entry.fileURL.pathExtension.uppercased()).font(.caption).foregroundStyle(.secondary) }
                } else {
                    VStack(alignment: .leading, spacing: 10) { artwork(entry).aspectRatio(16 / 9, contentMode: .fit); details(entry) }
                }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).padding(10).macMediaCard()
            .contextMenu {
                Button("Play Offline") { onPlay(entry.video) }.disabled(!entry.isAvailable)
                Button("Play Next") { MacMediaQueue.add(entry.video, next: true) }
                Button("Add to Queue") { MacMediaQueue.add(entry.video) }
                Menu("Add to Offline Playlist") {
                    ForEach(MacMediaPlaylistStore.shared.playlists) { playlist in Button(playlist.name) { MacMediaPlaylistStore.shared.add([entry], to: playlist.id) } }
                }
                if entry.isAudio { Button("Add to Music Library") { MacMusicLibraryStore.shared.addDownloaded(entry) } }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.fileURL]) }
                Button("Remove from Library") { library.hide(entry) }
                Divider()
                Button("Move to Trash…", role: .destructive) { deleting = entry }
            }
            .accessibilityLabel("Play \(entry.title), \(entry.isAudio ? "audio" : "video") offline")
    }
    private func artwork(_ entry: MacMediaEntry) -> some View {
        MacLocalMediaArtwork(entry: entry)
    }
    private func details(_ entry: MacMediaEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.title).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
            MacLocalWatchProgress(videoID: entry.video.id)
            if !entry.isAvailable { Text("Volume unavailable").font(.caption).foregroundStyle(.orange) }
            Text(entry.channel).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            Text("\(entry.isAudio ? "Audio" : "Video") · \(Int(entry.duration) / 60):\(String(format: "%02d", Int(entry.duration) % 60)) · \(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file))")
                .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
