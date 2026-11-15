#if os(macOS)
import SmartTubeIOSCore
import SwiftUI

struct MacMusicLibraryView: View {
    var onPlay: (Video) -> Void
    @Environment(\.innerTubeAPI) private var api
    @State private var library = MacMediaLibrary.shared
    @State private var section = "Offline Music"
    @State private var music = MacMusicLibraryStore.shared
    @State private var managingFolders = false
    @State private var grouping: String?
    @State private var query = ""
    @State private var online: [Video] = []
    @State private var token: String?
    @State private var busy = false
    @State private var error: String?
    private var audio: [MacMediaEntry] { library.entries.filter { music.contains($0) } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Music", selection: $section) { ForEach(["Online Music", "Offline Music", "Songs", "Artists", "Albums", "Music Playlists"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
                Menu("Import Music") {
                    Button("Import Music Files…") { Task { await music.importFiles() } }
                    Button("Add Music Folder…") { Task { await music.chooseFolders() } }
                    Button("Manage Music Folders…") { managingFolders = true }
                    Button("Refresh Music Library") { music.refresh() }
                }
            }.padding()
            switch section {
            case "Music Playlists": MacMusicPlaylistsView(onPlay: onPlay)
            case "Artists", "Albums":
                HStack {
                    List(selection: $grouping) {
                        ForEach(Array(Set(audio.map { section == "Artists" ? $0.channel : ($0.album ?? "Unknown Album") })).sorted(), id: \.self) { Text($0).tag($0) }
                    }.scrollContentBackground(.hidden).frame(width: 220)
                    MacCollectionBrowser(title: grouping ?? section, entries: audio.filter { grouping == nil || (section == "Artists" ? $0.channel : ($0.album ?? "Unknown Album")) == grouping }, onPlay: onPlay)
                }
            case "Online Music": onlineView
            default:
                VStack(alignment: .leading, spacing: 0) {
                    if audio.isEmpty {
                        Text("Import music files or add a Music folder. Custom video libraries and Downloads remain separate.")
                            .foregroundStyle(.secondary).padding(.horizontal, 24).padding(.top, 12)
                    }
                    MacCollectionBrowser(title: section == "Songs" ? "Songs" : "Offline Music", entries: audio, onPlay: onPlay)
                }
            }
        }
        .onChange(of: section) { _, _ in grouping = nil }
        .task { music.prepareIfNeeded(); music.adoptLegacyPlaylists() }
        .sheet(isPresented: $managingFolders) { MacMusicSourcesView().frame(minWidth: 720, idealWidth: 880, minHeight: 440, idealHeight: 580) }
        .alert("Music Library", isPresented: Binding(get: { music.error != nil }, set: { if !$0 { music.error = nil } })) {
            Button("OK") { music.error = nil }
        } message: { Text(music.error ?? "") }
    }
    private var onlineView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("YouTube Music Discovery").font(.largeTitle.bold())
            Text("Music videos and mixes from the connected YouTube interface. YouTube Music’s private songs, albums and account library are not exposed by this account connection.").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Search music, artists, albums or playlists", text: $query).textFieldStyle(.roundedBorder).onSubmit { Task { await load(reset: true) } }
                Button("Search") { Task { await load(reset: true) } }.disabled(busy)
                Button("Play All") { playOnlineQueue(shuffle: false) }.disabled(online.isEmpty)
                Button("Shuffle") { playOnlineQueue(shuffle: true) }.disabled(online.isEmpty)
            }
            if let error { Text(error).foregroundStyle(.red) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(online) { video in
                        HStack {
                            Button { MacPlaybackSession.shared.preferAudio(for: [video]); onPlay(video) } label: { VStack(alignment: .leading) { Text(video.title); Text(video.channelTitle).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
                            Button("Play Next") { MacPlaybackSession.shared.preferAudio(for: [video]); MacMediaQueue.add(video, next: true) }
                            Button("Queue") { MacPlaybackSession.shared.preferAudio(for: [video]); MacMediaQueue.add(video) }
                        }.padding(10).macMediaCard()
                    }
                    if token != nil { Button("Load More") { Task { await load(reset: false) } }.disabled(busy) }
                }
            }.scrollClipDisabled()
            if busy { ProgressView().controlSize(.small) }
        }.padding(24).task { if online.isEmpty { await load(reset: true) } }
    }
    private func playOnlineQueue(shuffle: Bool) {
        MacPlaybackSession.shared.preferAudio(for: online)
        MacMediaQueue.play(online, shuffle: shuffle, title: "Music", onPlay: onPlay)
    }
    private func load(reset: Bool) async {
        guard !busy else { return }; busy = true; error = nil
        defer { busy = false }
        do {
            let result: VideoGroup
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result = try await api.fetchMusicPage(continuation: reset ? nil : token) }
            else { result = try await api.search(query: query.isEmpty ? "music" : query, continuationToken: reset ? nil : token, filter: SearchFilter()) }
            if reset { online = [] }
            let ids = Set(online.map(\.id)); online.append(contentsOf: result.videos.filter { !ids.contains($0.id) }); token = result.nextPageToken
        } catch { self.error = error.localizedDescription }
    }
}
#endif
