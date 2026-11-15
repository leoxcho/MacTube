import Foundation
import os

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private let tubeLog = Logger(subsystem: appSubsystem, category: "InnerTube")

// MARK: - Browse endpoints

extension InnerTubeAPI {

    // MARK: - Visitor data helper

    /// Extracts `responseContext.visitorData` from a browse response and stores it.
    /// The stored token is included in subsequent home-feed requests so YouTube can
    /// tailor recommendations to this specific device/session.
    func updateVisitorData(from response: [String: Any]) {
        guard let ctx = response["responseContext"] as? [String: Any],
            let vd = ctx["visitorData"] as? String, !vd.isEmpty
        else { return }
        visitorData = vd
    }

    // MARK: - Home

    /// Fetches the home feed.
    /// When authenticated, uses TVHTML5 on youtubei.googleapis.com for a personalised feed.
    /// When unauthenticated, uses the WEB client on www.youtube.com for the default feed.
    public func fetchHome(continuationToken: String? = nil) async throws -> VideoGroup {
        let isAuth = authToken != nil
        var body = makeBody(
            client: isAuth ? tvClientContext : webClientContext,
            continuationToken: continuationToken,
            includeVisitorData: true)
        if continuationToken == nil {
            body["browseId"] = "FEwhat_to_watch"
        }
        let data =
            isAuth
            ? try await postTV(endpoint: "browse", body: body)
            : try await post(endpoint: "browse", body: body)
        updateVisitorData(from: data)
        return try parseVideoGroup(from: data, title: BrowseSection.SectionType.home.defaultTitle)
    }

    /// Fetches the home feed as multiple named shelves (TYPE_ROW in Android).
    /// Returns one VideoGroup per shelf; each has layout == .row.
    /// Falls back to a single flat VideoGroup if no shelves are found.
    public func fetchHomeRows(continuationToken: String? = nil) async throws -> [VideoGroup] {
        let isAuth = authToken != nil
        var body = makeBody(
            client: isAuth ? tvClientContext : webClientContext,
            continuationToken: continuationToken,
            includeVisitorData: true)
        if continuationToken == nil {
            body["browseId"] = "FEwhat_to_watch"
        }
        let data =
            isAuth
            ? try await postTV(endpoint: "browse", body: body)
            : try await post(endpoint: "browse", body: body)
        updateVisitorData(from: data)
        let rows = parseVideoGroupRows(from: data)
        tubeLog.notice("fetchHomeRows → \(rows.count, privacy: .public) shelves")
        let rowShortsDetail = rows.map { row -> String in
            let s = row.videos.filter { $0.isShort }.count
            return "'\(row.title ?? "?")': \(s)/\(row.videos.count) shorts"
        }.joined(separator: ", ")
        tubeLog.notice("fetchHomeRows shelf detail: [\(rowShortsDetail, privacy: .public)]")
        return rows
    }

    // MARK: - Subscriptions

    /// Fetches subscriptions feed (requires auth).
    /// Uses TVHTML5 client on youtubei.googleapis.com — the only endpoint that accepts
    /// the OAuth token issued by the TV device-code flow.
    public func fetchSubscriptions(continuationToken: String? = nil) async throws -> VideoGroup {
        var body = makeBody(client: tvClientContext, continuationToken: continuationToken)
        if continuationToken == nil {
            body["browseId"] = "FEsubscriptions"
        }
        let data = try await postTV(endpoint: "browse", body: body)
        let group = try parseVideoGroup(from: data, title: "Subscriptions")
        // Preserve the API's arrival order — YouTube returns tiles in the order
        // it considers most relevant. Sorting by date re-inserts new pages'
        // videos between existing ones instead of appending them.
        return group
    }

    /// Enumerates the authenticated TV guide, channel catalog and upload feed.
    /// Results are incremental; exhaustion describes the exposed interfaces, not
    /// proof that YouTube returned the account's complete subscription library.
    public func fetchSubscribedChannels() async throws -> [Channel] {
        try await fetchSubscribedChannels(onPage: nil)
    }

    public func fetchSubscribedChannels(
        onPage: (@Sendable ([Channel]) async -> Void)?
    ) async throws -> [Channel] {
        guard let accountToken = authToken else { throw APIError.notAuthenticated }
        let accountPageID = activeChannel.pageId
        var pending: [(endpoint: String, token: String, tracking: String?, web: Bool)] = []
        let accountCookie = sapisid
        var seenTokens = Set<String>()
        var channelsByID: [String: Channel] = [:]
        func checkAccount() throws {
            try Task.checkCancellation()
            // Do not join pages belonging to different primary/Brand Accounts.
            guard authToken == accountToken, activeChannel.pageId == accountPageID, sapisid == accountCookie else {
                throw CancellationError()
            }
        }
        func snapshot() -> [Channel] {
            channelsByID.values.sorted {
                let comparison = $0.title.localizedCaseInsensitiveCompare($1.title)
                return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
            }
        }
        func collect(_ response: [String: Any], endpoint: String, web: Bool = false, followContinuations: Bool = true) {
            for channel in parseGuideChannels(from: response) + parseChannelRenderers(from: response) + parseSubscribedChannels(from: response) {
                if var existing = channelsByID[channel.id] {
                    if existing.title.isEmpty { existing.title = channel.title }
                    existing.thumbnailURL = existing.thumbnailURL ?? channel.thumbnailURL
                    existing.subscriberCount = existing.subscriberCount ?? channel.subscriberCount
                    channelsByID[channel.id] = existing
                } else {
                    channelsByID[channel.id] = channel
                }
            }
            func walk(_ object: Any, endpoint: String, depth: Int = 0) {
                guard depth < 50 else { return }
                if let dictionary = object as? [String: Any] {
                    // A guide can carry browse continuations. Respect its supplied
                    // command API path rather than posting every token to /guide.
                    let metadata = (dictionary["commandMetadata"] as? [String: Any])?["webCommandMetadata"] as? [String: Any]
                    let apiURL = metadata?["apiUrl"] as? String
                    let target = apiURL?.hasSuffix("/browse") == true ? "browse"
                        : apiURL?.hasSuffix("/guide") == true ? "guide" : endpoint
                    for key in ["nextContinuationData", "reloadContinuationData", "continuationCommand"] {
                        if let value = dictionary[key] as? [String: Any],
                           let token = (value["continuation"] ?? value["token"]) as? String,
                           !token.isEmpty, seenTokens.insert((web ? "web:" : "tv:") + target + ":" + token).inserted {
                            pending.append((target, token, dictionary["clickTrackingParams"] as? String, web))
                        }
                    }
                    for value in dictionary.values { walk(value, endpoint: target, depth: depth + 1) }
                } else if let array = object as? [Any] {
                    for value in array { walk(value, endpoint: endpoint, depth: depth + 1) }
                }
            }
            if followContinuations { walk(response, endpoint: endpoint) }
        }
        // Merge all available interfaces even when the guide is nonempty: a
        // truncated sidebar must not suppress channels exposed by another source.
        for (endpoint, browseID) in [("guide", ""), ("browse", "FEchannels"), ("browse", "FEsubscriptions")] {
            try checkAccount()
            var body = makeBody(client: tvClientContext)
            if !browseID.isEmpty { body["browseId"] = browseID }
            do {
                let response = try await postTV(endpoint: endpoint, body: body, explicitBearerToken: accountToken)
                try checkAccount()
                // Upload history is supplemental only; enumerating every old
                // subscription video is unbounded and cannot prove completeness.
                collect(response, endpoint: endpoint, followContinuations: browseID != "FEsubscriptions")
                await onPage?(snapshot())
            } catch is CancellationError { throw CancellationError() }
            catch {
                tubeLog.warning("Subscription source unavailable; retaining other sources: \(error.localizedDescription, privacy: .public)")
            }
        }
        // Existing cookie-authenticated sessions can expose the desktop channel
        // catalog omitted by TV. Never send TV OAuth Bearer credentials to WEB.
        if let accountCookie {
            try checkAccount()
            var body = makeBody(client: webClientContext)
            body["browseId"] = "FEchannels"
            do {
                let response = try await postSubscriptionWeb(endpoint: "browse", body: body, cookie: accountCookie)
                try checkAccount()
                collect(response, endpoint: "browse", web: true)
                await onPage?(snapshot())
            } catch is CancellationError { throw CancellationError() }
            catch {
                tubeLog.warning("Desktop subscription catalog unavailable; retaining TV results")
            }
        }
        var cursor = 0
        while cursor < pending.count {
            try checkAccount()
            let continuation = pending[cursor]
            cursor += 1
            var body = makeBody(client: continuation.web ? webClientContext : tvClientContext, continuationToken: continuation.token)
            if let tracking = continuation.tracking, var context = body["context"] as? [String: Any] {
                context["clickTracking"] = ["clickTrackingParams": tracking]
                body["context"] = context
            }
            do {
                let response: [String: Any]
                if continuation.web, let accountCookie {
                    response = try await postSubscriptionWeb(endpoint: continuation.endpoint, body: body, cookie: accountCookie)
                } else {
                    response = try await postTV(endpoint: continuation.endpoint, body: body, explicitBearerToken: accountToken)
                }
                try checkAccount()
                collect(response, endpoint: continuation.endpoint, web: continuation.web)
                await onPage?(snapshot())
            } catch is CancellationError { throw CancellationError() }
            catch {
                tubeLog.warning("Subscription page unavailable; retrieved list may be incomplete: \(error.localizedDescription, privacy: .public)")
            }
        }
        return snapshot()
    }

    /// Cookie-backed WEB catalog requests reuse the connected session. This path
    /// is unavailable for a TV OAuth-only account and never asks for tokens.
    private func postSubscriptionWeb(endpoint: String, body: [String: Any], cookie: String) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appendingPathComponent(endpoint))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue(InnerTubeClients.Web.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(InnerTubeClients.Web.nameID, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(InnerTubeClients.Web.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue(InnerTubeAPI.sapisidhash(sapisid: cookie), forHTTPHeaderField: "Authorization")
        activeChannel.apply(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], json["error"] == nil else {
            throw APIError.decodingError("Subscription catalog unavailable")
        }
        return json
    }

    /// Fetches watch history (requires auth).
    public func fetchHistory(continuationToken: String? = nil) async throws -> VideoGroup {
        var body = makeBody(client: tvClientContext, continuationToken: continuationToken)
        if continuationToken == nil {
            body["browseId"] = "FEhistory"
        }
        let data = try await postTV(endpoint: "browse", body: body)
        return try parseVideoGroup(from: data, title: "History")
    }

    // MARK: - Search

    public func search(
        query: String,
        continuationToken: String? = nil,
        filter: SearchFilter = .default
    ) async throws -> VideoGroup {
        var body = makeBody(client: webClientContext, continuationToken: continuationToken)
        if continuationToken == nil {
            body["query"] = query
            if let params = filter.encodedParams() {
                body["params"] = params
            }
        }
        let data = try await post(endpoint: "search", body: body)
        var group = try parseVideoGroup(from: data, title: "Search: \(query)")
        if filter.type == .channel {
            group.videos = parseChannelRenderers(from: data).map {
                Video(id: $0.id, title: $0.title, channelTitle: "Channel", channelId: $0.id, thumbnailURL: $0.thumbnailURL)
            }
        } else if filter.type == .playlist {
            group.videos = try parsePlaylists(from: data).map {
                Video(id: $0.id, title: $0.title, channelTitle: $0.videoCount.map { "\($0) videos" } ?? "Playlist", thumbnailURL: $0.thumbnailURL, playlistId: $0.id)
            }
        }
        return group
    }

    public func fetchSearchSuggestions(query: String) async throws -> [String] {
        guard var components = URLComponents(string: "https://suggestqueries-clients6.youtube.com/complete/search")
        else {
            return []
        }
        components.queryItems = [
            URLQueryItem(name: "client", value: "youtube"),
            URLQueryItem(name: "ds", value: "yt"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "callback", value: ""),
        ]
        guard let url = components.url else { return [] }
        print("[Suggestions] Fetching URL: \(url)")
        let (data, response) = try await session.data(from: url)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        print("[Suggestions] HTTP status: \(statusCode), bytes: \(data.count)")
        // Response format: [query, [[suggestion, 0, []], ...], ...]
        guard let raw = String(data: data, encoding: .utf8) else {
            print("[Suggestions] Failed to decode response as UTF-8")
            return []
        }
        print("[Suggestions] Raw prefix: \(raw.prefix(120))")
        // Extract the outermost JSON array — works regardless of callback wrapper name
        guard let arrayStart = raw.firstIndex(of: "["),
            let arrayEnd = raw.lastIndex(of: "]")
        else {
            print("[Suggestions] Could not find JSON array bounds")
            return []
        }
        let jsonString = String(raw[arrayStart...arrayEnd])
        print("[Suggestions] JSON prefix after strip: \(jsonString.prefix(120))")
        guard let jsonData = jsonString.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: jsonData) as? [Any]
        else {
            print("[Suggestions] JSON parse failed")
            return []
        }
        guard let suggestions = json[safe: 1] as? [[Any]] else {
            print("[Suggestions] Unexpected JSON shape: \(json.prefix(2))")
            return []
        }
        let results = suggestions.compactMap { $0[safe: 0] as? String }
        print("[Suggestions] Parsed \(results.count) suggestions: \(results.prefix(5))")
        return results
    }

    // MARK: - Shorts

    public func fetchShorts() async throws -> VideoGroup {
        // NOTE (2026-05-24): Strategies 1–3 (FEshorts via postTV, postTVCategory, WEB)
        // were removed because YouTube deprecated the FEshorts browseId — all three
        // returned HTTP 400 on every client (TV+auth, TV-category, WEB). Confirmed via
        // log analysis: the home browse with the same token/version succeeds (200), so
        // it is specifically FEshorts that YouTube no longer accepts, not a client version
        // or auth issue. yt-dlp (2026.03.17) does not use FEshorts at all and does not
        // support the Shorts homepage feed. Search is the only working path right now.
        // TODO: re-add a FEshorts attempt if YouTube re-enables it, or find a replacement
        // browseId/params that yields a Shorts feed.

        // Search "#shorts" with the YouTube Shorts duration filter (EgIYAQ== / sp=EgIYAQ%3D%3D).
        // WEB client videoRenderer items in search results rarely carry reelWatchEndpoint or
        // the SHORTS overlay style, so parseVideoRenderer leaves isShort=false for most of them
        // even though they are genuine Shorts. Since the duration:short filter guarantees
        // every result is ≤ 4 min and we searched for "#shorts", we treat any video ≤ 180 s
        // as a Short and override isShort in-place.
        let shortsFilter = SearchFilter(duration: .short)
        let searchGroup = try await search(query: "#shorts", filter: shortsFilter)
        // Accept videos already flagged isShort=true by the parser (shortsLockupViewModel sets
        // isShort=true directly), OR any video with duration ≤ 180 s that wasn't flagged.
        // Do NOT reject on nil duration — shortsLockupViewModel items have nil duration.
        var shorts = searchGroup.videos.filter { $0.isShort || ($0.duration.map { $0 <= 180 } ?? false) }
        for i in shorts.indices where !shorts[i].isShort { shorts[i].isShort = true }
        let dropped = searchGroup.videos.filter { !($0.isShort || ($0.duration.map { $0 <= 180 } ?? false)) }
        for v in dropped {
            tubeLog.notice(
                "fetchShorts DROPPED: id=\(v.id, privacy: .public) dur=\(v.duration.map { "\($0)" } ?? "nil", privacy: .public) isShort=\(v.isShort, privacy: .public) title=\(v.title.prefix(40), privacy: .public)"
            )
        }
        tubeLog.notice(
            "fetchShorts search → \(searchGroup.videos.count, privacy: .public) total, \(shorts.count, privacy: .public) kept as shorts (\(dropped.count, privacy: .public) dropped), token=\(searchGroup.nextPageToken.map { String($0.prefix(16)) + "\u{2026}" } ?? "nil", privacy: .public)"
        )
        // Tag token with "srch:" so fetchShortsMore() uses only the search continuation path.
        return VideoGroup(
            title: "Shorts", videos: shorts, nextPageToken: searchGroup.nextPageToken.map { "srch:" + $0 })
    }

    public func fetchShortsMore(continuationToken: String) async throws -> VideoGroup {
        // InnerTube continuation tokens are client-specific: a token issued by one
        // client (e.g. postTV) returns HTTP 400 when sent to a different client
        // (e.g. WEB). fetchShorts() embeds a source prefix in every token it returns
        // so we can route the continuation to the correct client without retrying all.
        //
        // Prefix  Client         Auth needed
        // "stv:"  postTV         yes (Bearer)
        // "stvc:" postTVCategory no
        // "web:"  WEB browse     no
        // "srch:" search         no
        // ""      legacy         try-all (backward compat)
        let (source, rawToken): (String, String) = {
            let tagged: [(String, String)] = [
                ("stv:", "stv"), ("stvc:", "stvc"), ("web:", "web"), ("srch:", "srch"),
            ]
            for (prefix, tag) in tagged where continuationToken.hasPrefix(prefix) {
                return (tag, String(continuationToken.dropFirst(prefix.count)))
            }
            return ("", continuationToken)
        }()
        tubeLog.notice(
            "fetchShortsMore source=\(source.isEmpty ? "legacy" : source, privacy: .public) token=\(rawToken.prefix(16), privacy: .public)…"
        )
        let isAuth = authToken != nil

        switch source {
        case "stv":
            let body = makeBody(client: tvClientContext, continuationToken: rawToken)
            let data = try await postTV(endpoint: "browse", body: body)
            let group = try parseVideoGroup(from: data, title: "Shorts")
            let shorts = group.videos.filter { $0.isShort }
            tubeLog.notice(
                "fetchShortsMore postTV → \(group.videos.count, privacy: .public) videos, \(shorts.count, privacy: .public) shorts"
            )
            return VideoGroup(title: "Shorts", videos: shorts, nextPageToken: group.nextPageToken.map { "stv:" + $0 })

        case "stvc":
            let body = makeBody(client: tvClientContext, continuationToken: rawToken)
            let data = try await postTVCategory(endpoint: "browse", body: body)
            let group = try parseVideoGroup(from: data, title: "Shorts")
            let shorts = group.videos.filter { $0.isShort }
            tubeLog.notice(
                "fetchShortsMore postTVCategory → \(group.videos.count, privacy: .public) videos, \(shorts.count, privacy: .public) shorts"
            )
            return VideoGroup(title: "Shorts", videos: shorts, nextPageToken: group.nextPageToken.map { "stvc:" + $0 })

        case "web":
            let body = makeBody(client: webClientContext, continuationToken: rawToken)
            let data = try await post(endpoint: "browse", body: body)
            let group = try parseVideoGroup(from: data, title: "Shorts")
            let shorts = group.videos.filter { $0.isShort }
            tubeLog.notice(
                "fetchShortsMore WEB → \(group.videos.count, privacy: .public) videos, \(shorts.count, privacy: .public) shorts"
            )
            return VideoGroup(title: "Shorts", videos: shorts, nextPageToken: group.nextPageToken.map { "web:" + $0 })

        case "srch":
            let group = try await search(query: "#shorts", continuationToken: rawToken)
            var shorts = group.videos.filter { $0.isShort || ($0.duration.map { $0 <= 180 } ?? false) }
            for i in shorts.indices where !shorts[i].isShort { shorts[i].isShort = true }
            let dropped = group.videos.filter { !($0.isShort || ($0.duration.map { $0 <= 180 } ?? false)) }
            for v in dropped {
                tubeLog.notice(
                    "fetchShortsMore DROPPED: id=\(v.id, privacy: .public) dur=\(v.duration.map { "\($0)" } ?? "nil", privacy: .public) isShort=\(v.isShort, privacy: .public) title=\(v.title.prefix(40), privacy: .public)"
                )
            }
            tubeLog.notice(
                "fetchShortsMore search → \(group.videos.count, privacy: .public) total, \(shorts.count, privacy: .public) kept (\(dropped.count, privacy: .public) dropped), nextToken=\(group.nextPageToken != nil ? "yes" : "no", privacy: .public)"
            )
            return VideoGroup(title: "Shorts", videos: shorts, nextPageToken: group.nextPageToken.map { "srch:" + $0 })

        default:
            // Legacy un-prefixed token (from older app versions): try all clients as before.
            if isAuth {
                do {
                    let body = makeBody(client: tvClientContext, continuationToken: rawToken)
                    let data = try await postTV(endpoint: "browse", body: body)
                    let group = try parseVideoGroup(from: data, title: "Shorts")
                    let shorts = group.videos.filter { $0.isShort }
                    let token = group.nextPageToken.map { String($0.prefix(16)) + "…" } ?? "nil"
                    tubeLog.notice(
                        "fetchShortsMore postTV → \(group.videos.count, privacy: .public) videos, \(shorts.count, privacy: .public) shorts, token=\(token, privacy: .public)"
                    )
                    if !group.videos.isEmpty {
                        return VideoGroup(title: "Shorts", videos: shorts, nextPageToken: group.nextPageToken)
                    }
                } catch {
                    tubeLog.notice("fetchShortsMore postTV failed (\(error, privacy: .public)) — trying postTVCategory")
                }
            }

            do {
                let body = makeBody(client: tvClientContext, continuationToken: rawToken)
                let data = try await postTVCategory(endpoint: "browse", body: body)
                let group = try parseVideoGroup(from: data, title: "Shorts")
                let shorts = group.videos.filter { $0.isShort }
                let token = group.nextPageToken.map { String($0.prefix(16)) + "…" } ?? "nil"
                tubeLog.notice(
                    "fetchShortsMore postTVCategory → \(group.videos.count, privacy: .public) videos, \(shorts.count, privacy: .public) shorts, token=\(token, privacy: .public)"
                )
                if !group.videos.isEmpty {
                    return VideoGroup(title: "Shorts", videos: shorts, nextPageToken: group.nextPageToken)
                }
            } catch {
                tubeLog.notice("fetchShortsMore postTVCategory failed (\(error, privacy: .public)) — trying WEB")
            }

            do {
                let body = makeBody(client: webClientContext, continuationToken: rawToken)
                let data = try await post(endpoint: "browse", body: body)
                let group = try parseVideoGroup(from: data, title: "Shorts")
                let shorts = group.videos.filter { $0.isShort }
                let token = group.nextPageToken.map { String($0.prefix(16)) + "\u{2026}" } ?? "nil"
                tubeLog.notice(
                    "fetchShortsMore WEB → \(group.videos.count, privacy: .public) videos, \(shorts.count, privacy: .public) shorts, token=\(token, privacy: .public)"
                )
                if !group.videos.isEmpty {
                    return VideoGroup(title: "Shorts", videos: shorts, nextPageToken: group.nextPageToken)
                }
            } catch {
                tubeLog.notice("fetchShortsMore WEB failed (\(error, privacy: .public)) — trying search continuation")
            }

            // Last resort: search continuation token.
            let searchGroup = try await search(query: "#shorts", continuationToken: rawToken)
            let searchShorts = searchGroup.videos.filter { $0.isShort }
            let searchToken = searchGroup.nextPageToken.map { String($0.prefix(16)) + "\u{2026}" } ?? "nil"
            tubeLog.notice(
                "fetchShortsMore search → \(searchGroup.videos.count, privacy: .public) total, \(searchShorts.count, privacy: .public) shorts, token=\(searchToken, privacy: .public)"
            )
            return VideoGroup(title: "Shorts", videos: searchShorts, nextPageToken: searchGroup.nextPageToken)
        }
    }

    // MARK: - Category sections

    public func fetchMusic() async throws -> VideoGroup {
        do {
            // FEmusic_home is the TVHTML5 browse ID for the music category page.
            var body = makeBody(client: tvClientContext)
            body["browseId"] = "FEmusic_home"
            let data = try await postTVCategory(endpoint: "browse", body: body)
            let group = try parseVideoGroup(from: data, title: "Music")
            if !group.videos.isEmpty { return group }
        } catch {
            tubeLog.notice("fetchMusic browse failed, falling back to search: \(error, privacy: .public)")
        }
        return try await search(query: "music")
    }

    public func fetchGaming() async throws -> VideoGroup {
        do {
            // FEgaming requires TVHTML5 context on www.youtube.com (not googleapis.com).
            var body = makeBody(client: tvClientContext)
            body["browseId"] = "FEgaming"
            let data = try await postTVCategory(endpoint: "browse", body: body)
            let group = try parseVideoGroup(from: data, title: "Gaming")
            if !group.videos.isEmpty { return group }
        } catch {
            tubeLog.notice("fetchGaming browse failed, falling back to search: \(error, privacy: .public)")
        }
        return try await search(query: "gaming")
    }

    public func fetchNews() async throws -> VideoGroup {
        // FEnews is not a valid InnerTube browse ID — use search directly.
        return try await search(query: "news today")
    }

    public func fetchLive() async throws -> VideoGroup {
        do {
            var body = makeBody(client: tvClientContext)
            body["browseId"] = "FElive_home"
            let data = try await postTVCategory(endpoint: "browse", body: body)
            let group = try parseVideoGroup(from: data, title: "Live")
            if !group.videos.isEmpty { return group }
        } catch {
            tubeLog.notice("fetchLive browse failed, falling back to search: \(error, privacy: .public)")
        }
        return try await search(query: "live stream")
    }

    public func fetchSports() async throws -> VideoGroup {
        do {
            // FEsportsau is the known TVHTML5 browse ID for the sports category.
            var body = makeBody(client: tvClientContext)
            body["browseId"] = "FEsportsau"
            let data = try await postTVCategory(endpoint: "browse", body: body)
            let group = try parseVideoGroup(from: data, title: "Sports")
            if !group.videos.isEmpty { return group }
        } catch {
            tubeLog.notice("fetchSports browse failed, falling back to search: \(error, privacy: .public)")
        }
        return try await search(query: "sports")
    }
}
