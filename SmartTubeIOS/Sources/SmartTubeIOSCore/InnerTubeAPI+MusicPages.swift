import Foundation

extension InnerTubeAPI {
    /// Carries endpoint provenance with continuation tokens so category and search pages never mix.
    public func fetchMusicPage(continuation: String? = nil) async throws -> VideoGroup {
        let searchPrefix = "mactube-music-search:"
        let browsePrefix = "mactube-music-browse:"
        if let continuation, continuation.hasPrefix(searchPrefix) {
            var group = try await search(query: "music", continuationToken: String(continuation.dropFirst(searchPrefix.count)))
            group.nextPageToken = group.nextPageToken.map { searchPrefix + $0 }
            return group
        }
        do {
            let raw = continuation.map { $0.hasPrefix(browsePrefix) ? String($0.dropFirst(browsePrefix.count)) : $0 }
            var body = makeBody(client: tvClientContext, continuationToken: raw)
            if raw == nil { body["browseId"] = "FEmusic_home" }
            let data = try await postTVCategory(endpoint: "browse", body: body)
            var group = try parseVideoGroup(from: data, title: "Music")
            if !group.videos.isEmpty || continuation != nil {
                group.nextPageToken = group.nextPageToken.map { browsePrefix + $0 }
                return group
            }
        } catch { if continuation != nil { throw error } }
        var group = try await search(query: "music")
        group.nextPageToken = group.nextPageToken.map { searchPrefix + $0 }
        return group
    }
}
