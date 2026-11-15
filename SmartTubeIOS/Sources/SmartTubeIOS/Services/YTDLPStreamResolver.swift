#if os(macOS)
import Foundation
import SmartTubeIOSCore

actor YTDLPStreamResolver {
    static let timeout: Duration = .seconds(45)
    static let startupTimeout: Duration = .seconds(25)
    static let startupCandidateLimit = 8
    static let heights = [360, 480, 720, 1080, 1440, 2160]
    struct Format: Decodable, Sendable, Identifiable {
        let format_id: String
        let url: String?
        let ext: String?
        let protocolName: String?
        let height: Int?
        let width: Int?
        let fps: Double?
        let acodec: String?
        let vcodec: String?
        let tbr: Double?
        let language: String?
        let language_preference: Double?
        let format_note: String?
        let manifest_url: String?
        let http_headers: [String: String]?
        let rows: Int?
        let columns: Int?
        let fragments: [StoryboardFragment]?
        var id: String { format_id }
        var hasAudio: Bool { acodec != nil && acodec != "none" }
        var hasVideo: Bool { vcodec != nil && vcodec != "none" }
        var isHLS: Bool { protocolName?.hasPrefix("m3u8") == true }
        var directMedia: Bool { protocolName == nil || protocolName == "https" || protocolName == "http" }
        var nativeAudio: Bool {
            hasAudio && ["mp4a", "aac"].contains { acodec?.hasPrefix($0) == true }
        }
        var nativeVideo: Bool {
            guard hasVideo, ext == "mp4", isHLS || directMedia, let codec = vcodec else { return false }
            // AVFoundation rejected remote AV1 tracks in the M4 runtime probe.
            // Keep those formats available to downloads, not the native stream picker.
            return ["avc1", "hvc1", "hev1", "h264"].contains { codec.hasPrefix($0) }
        }
        enum CodingKeys: String, CodingKey {
            case format_id, url, ext, height, width, fps, acodec, vcodec, tbr, http_headers, rows, columns, fragments
            case language, language_preference, format_note, manifest_url
            case protocolName = "protocol"
        }
    }
    struct StoryboardFragment: Decodable, Sendable {
        let url: String
        let duration: Double?
    }
    struct Subtitle: Decodable, Sendable {
        let url: String
        let ext: String?
        let name: String?
    }
    struct Stream: Sendable {
        let url: URL
        let headers: [String: String]
        let formats: [Format]
        let isLive: Bool
        let liveStatus: String?
        let duration: Double?
        var captionTracks: [CaptionTrack] = []
        var storyboard: StoryboardPreview? = nil
    }
    enum Failure: String, LocalizedError {
        case missingExecutable = "yt-dlp or Deno is missing from /usr/local/bin."
        case launch = "Unable to launch yt-dlp."
        case timeout = "Stream operation timed out."
        case extraction =
            "yt-dlp could not complete this operation. Check connectivity, available formats and yt-dlp updates."
        case invalidOutput = "yt-dlp returned an invalid stream response."
        case processing = "YouTube is still processing this livestream recording. Try again later."
        case noStreams = "YouTube returned no supported streams. The broadcast may be unavailable or require sign-in."
        case unsupported = "This format cannot be played by AVFoundation. The previous quality has been restored."
        case ffmpeg =
            "FFmpeg is required to merge high-quality video and audio. Install it before selecting this download."
        var errorDescription: String? { rawValue }
    }
    private struct Response: Decodable {
        let url: String?
        let acodec: String?
        let vcodec: String?
        let format_id: String?
        let ext: String?
        let live_status: String?
        let is_live: Bool?
        let duration: Double?
        let http_headers: [String: String]?
        let formats: [Format]?
        let subtitles: [String: [Subtitle]]?
        let automatic_captions: [String: [Subtitle]]?
    }
    static func validate(url rawURL: String, headers: [String: String]) throws -> URL {
        guard let url = URL(string: rawURL), url.scheme?.lowercased() == "https",
            let host = url.host, !host.isEmpty, url.user == nil, url.password == nil
        else { throw Failure.invalidOutput }
        for (name, value) in headers {
            guard !name.isEmpty, name.utf8.allSatisfy({ $0 > 32 && $0 < 127 && $0 != 58 }),
                !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
            else { throw Failure.invalidOutput }
        }
        return url
    }
    static func parse(_ data: Data) throws -> Stream {
        guard let result = try? JSONDecoder().decode(Response.self, from: data) else {
            throw Failure.invalidOutput
        }
        let headers = result.http_headers ?? [:]
        // Validate response headers even when no selected URL is present.
        _ = try validate(url: result.url ?? "https://www.youtube.com/", headers: headers)
        var formats = (result.formats ?? []).filter {
            guard let raw = $0.url else { return false }
            return (try? validate(url: raw, headers: $0.http_headers ?? headers)) != nil
        }
        if formats.isEmpty, let raw = result.url, let audio = result.acodec, audio != "none",
            let video = result.vcodec, video != "none"
        {
            let selected = try JSONDecoder().decode(
                Format.self,
                from: JSONSerialization.data(withJSONObject: [
                    "format_id": result.format_id ?? "selected", "url": raw, "ext": result.ext ?? "mp4",
                    "acodec": audio, "vcodec": video,
                ]))
            formats = [selected]
        }
        let live = result.live_status == "is_live" || (result.live_status == nil && result.is_live == true)
        let choices = playbackFormats(formats, isLive: live)
        guard let choice = choices.first ?? formats.first(where: { $0.nativeVideo && $0.nativeAudio }),
            let raw = choice.url
        else {
            if result.live_status == "is_upcoming" { throw YTDLPProcessRunner.ExtractionFailure.upcoming }
            if result.live_status == "post_live" { throw Failure.processing }
            throw Failure.noStreams
        }
        return Stream(
            url: try validate(url: raw, headers: headers), headers: headers, formats: formats,
            isLive: live, liveStatus: result.live_status, duration: live ? nil : result.duration,
            captionTracks: captions(result), storyboard: storyboard(result.formats ?? []))
    }
    private static func captions(_ response: Response) -> [CaptionTrack] {
        var tracks: [CaptionTrack] = []
        for (automatic, languages) in [(false, response.subtitles ?? [:]), (true, response.automatic_captions ?? [:])] {
            for language in languages.keys.sorted() where !language.hasSuffix("-orig") {
                guard let subtitle = languages[language]?.first(where: { $0.ext == "vtt" }),
                      let url = try? validate(url: subtitle.url, headers: [:]) else { continue }
                // Prefer uploaded captions to the generated equivalent; do not duplicate languages.
                guard !tracks.contains(where: { $0.languageCode == language }) else { continue }
                tracks.append(CaptionTrack(id: "\(automatic ? "a" : "manual").\(language)", baseURL: url,
                    name: subtitle.name ?? Locale.current.localizedString(forLanguageCode: language) ?? language,
                    languageCode: language, isAutoGenerated: automatic))
            }
        }
        return tracks
    }
    private static func storyboard(_ formats: [Format]) -> StoryboardPreview? {
        // Use a small storyboard rendition. No video fetch or decoder is involved.
        let choices = formats.filter { ($0.rows ?? 0) > 0 && ($0.columns ?? 0) > 0 && !($0.fragments ?? []).isEmpty }
        guard let format = choices.min(by: { ($0.width ?? 0) < ($1.width ?? 0) }),
              let rows = format.rows, let columns = format.columns else { return nil }
        var start = 0.0
        var sheets: [StoryboardPreview.Sheet] = []
        for fragment in format.fragments ?? [] {
            guard let duration = fragment.duration, duration > 0,
                  let url = try? validate(url: fragment.url, headers: [:]) else { continue }
            sheets.append(.init(url: url, start: start, duration: duration))
            start += duration
        }
        guard !sheets.isEmpty else { return nil }
        return StoryboardPreview(rows: rows, columns: columns, sheets: sheets)
    }
    /// The quality menu uses one entry per actual height, including portrait and unusual sizes.
    static func playbackFormats(_ formats: [Format], isLive: Bool = false) -> [Format] {
        let ranked = compatibleFormats(formats, isLive: isLive)
        var seen = Set<Int>()
        return ranked.filter { seen.insert($0.height ?? 0).inserted }
    }
    private static func compatibleFormats(_ formats: [Format], isLive: Bool) -> [Format] {
        let hasAudio = formats.contains { !$0.hasVideo && $0.nativeAudio && $0.ext == "m4a" && $0.directMedia }
        return formats.filter {
            $0.nativeVideo && ($0.nativeAudio || (!isLive && !$0.hasAudio && $0.directMedia && hasAudio))
        }.sorted {
            if ($0.height ?? 0) != ($1.height ?? 0) { return ($0.height ?? 0) > ($1.height ?? 0) }
            if $0.isHLS != $1.isHLS { return $0.isHLS }
            if $0.hasAudio != $1.hasAudio { return $0.hasAudio }
            let leftH264 = $0.vcodec?.hasPrefix("avc1") == true || $0.vcodec?.hasPrefix("h264") == true
            let rightH264 = $1.vcodec?.hasPrefix("avc1") == true || $1.vcodec?.hasPrefix("h264") == true
            if leftH264 != rightH264 { return leftH264 }
            if ($0.tbr ?? 0) != ($1.tbr ?? 0) { return ($0.tbr ?? 0) > ($1.tbr ?? 0) }
            return $0.id < $1.id
        }
    }
    /// Prefer the extractor's original/default track, then the user's language, then bitrate.
    static func audioFormats(_ stream: Stream) -> [Format] {
        let locale = Locale.preferredLanguages.first?.split(separator: "-").first.map(String.init)
        return stream.formats.filter { !$0.hasVideo && $0.nativeAudio && $0.ext == "m4a" && $0.directMedia }
            .sorted {
                if ($0.language_preference ?? 0) != ($1.language_preference ?? 0) {
                    return ($0.language_preference ?? 0) > ($1.language_preference ?? 0)
                }
                let leftDefault = $0.format_note?.contains("default") == true
                let rightDefault = $1.format_note?.contains("default") == true
                if leftDefault != rightDefault { return leftDefault }
                let leftLanguage = $0.language?.split(separator: "-").first.map(String.init) == locale
                let rightLanguage = $1.language?.split(separator: "-").first.map(String.init) == locale
                if leftLanguage != rightLanguage { return leftLanguage }
                if ($0.tbr ?? 0) != ($1.tbr ?? 0) { return ($0.tbr ?? 0) > ($1.tbr ?? 0) }
                return $0.id < $1.id
            }
    }
    /// Preserve alternatives at the same height. Round-robin transports before lower-quality retries.
    static func startupFormats(_ stream: Stream, preferredHeight: Int? = nil) -> [Format] {
        var ranked = compatibleFormats(stream.formats, isLive: stream.isLive)
        if let preferredHeight {
            ranked.sort {
                let left = abs(($0.height ?? 0) - preferredHeight)
                let right = abs(($1.height ?? 0) - preferredHeight)
                return left < right
            }
        }
        let originalLanguage = audioFormats(stream).first?.language?.lowercased()
        let mismatchedAudio: (Format) -> Bool = { format in
            guard let originalLanguage, let language = format.language?.lowercased(), format.nativeAudio else { return false }
            return language != originalLanguage
        }
        let dubbed = ranked.filter { !$0.isHLS && mismatchedAudio($0) }
        var groups = [ranked.filter { $0.isHLS },
                      ranked.filter { !$0.isHLS && $0.nativeAudio && !mismatchedAudio($0) },
                      ranked.filter { !$0.hasAudio }]
        var choices: [Format] = []
        var seen = Set<String>()
        while choices.count < startupCandidateLimit && groups.contains(where: { !$0.isEmpty }) {
            for index in groups.indices where !groups[index].isEmpty {
                let format = groups[index].removeFirst()
                if let url = format.url, seen.insert(url).inserted { choices.append(format) }
                if choices.count == startupCandidateLimit { break }
            }
        }
        return Array((choices + dubbed).prefix(startupCandidateLimit))
    }
    /// Promote a master only after its declared video codec and referenced audio group are compatible.
    static func validatedMaster(_ data: Data, url: URL, headers: [String: String]) throws -> Format? {
        guard data.count <= 2_097_152, let text = String(data: data, encoding: .utf8),
              text.hasPrefix("#EXTM3U") else { return nil }
        let lines = text.components(separatedBy: .newlines)
        let audio = lines.filter { $0.hasPrefix("#EXT-X-MEDIA:") && $0.contains("TYPE=AUDIO") && $0.contains("URI=") }
        let variants = lines.filter { line in
            line.hasPrefix("#EXT-X-STREAM-INF:") && line.contains("avc1.") && line.contains("mp4a.")
                && audio.contains(where: { group in
                    guard let groupRange = group.range(of: "GROUP-ID=\""),
                          let end = group[groupRange.upperBound...].firstIndex(of: "\"") else { return false }
                    let name = group[groupRange.upperBound..<end]
                    return line.contains("AUDIO=\"\(name)\"")
                })
        }
        guard !variants.isEmpty else { return nil }
        let heights = variants.compactMap { line -> Int? in
            guard let range = line.range(of: "RESOLUTION=") else { return nil }
            let dimensions = line[range.upperBound...].prefix(while: { $0 != "," })
            return dimensions.split(separator: "x").last.flatMap { Int($0) }
        }
        var fields: [String: Any] = ["format_id": "hls-master", "url": url.absoluteString,
            "ext": "mp4", "protocol": "m3u8_native", "vcodec": "avc1", "acodec": "mp4a",
            "http_headers": headers]
        if let height = heights.max() { fields["height"] = height }
        return try JSONDecoder().decode(Format.self, from: JSONSerialization.data(withJSONObject: fields))
    }
    func resolve(videoID: String) async throws -> Stream {
        let data = try await YTDLPProcessRunner().run(
            arguments: [
                "--skip-download", "--dump-single-json", "--ignore-no-formats-error", "--",
                try YTDLPProcessRunner.watchURL(videoID),
            ], timeout: Self.timeout)
        return try await resolve(data: data)
    }
    /// Captured metadata follows the same verified manifest path as a fresh resolver response.
    func resolve(data: Data) async throws -> Stream {
        let response = try JSONDecoder().decode(Response.self, from: data)
        let base = Result { try Self.parse(data) }
        let formats = response.formats ?? []
        guard !formats.contains(where: { $0.isHLS && $0.nativeAudio }),
              let candidate = formats.first(where: { $0.isHLS && $0.nativeVideo && $0.manifest_url != nil }),
              let raw = candidate.manifest_url else { return try base.get() }
        let headers = (response.http_headers ?? [:]).merging(candidate.http_headers ?? [:], uniquingKeysWith: { _, new in new })
        let masterURL = try Self.validate(url: raw, headers: headers)
        var request = URLRequest(url: masterURL, timeoutInterval: 10)
        request.allHTTPHeaderFields = headers
        request.httpShouldHandleCookies = false
        do {
            let (bytes, httpResponse) = try await URLSession.shared.bytes(for: request)
            guard (httpResponse as? HTTPURLResponse)?.statusCode == 200,
                  httpResponse.expectedContentLength <= 2_097_152 else { return try base.get() }
            var manifest = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard manifest.count < 2_097_152 else { return try base.get() }
                manifest.append(byte)
            }
            guard let master = try Self.validatedMaster(manifest, url: masterURL, headers: headers)
            else { return try base.get() }
            let live = response.live_status == "is_live" || (response.live_status == nil && response.is_live == true)
            let validated = formats.filter {
                guard let raw = $0.url else { return false }
                return (try? Self.validate(url: raw, headers: $0.http_headers ?? headers)) != nil
            }
            return Stream(url: masterURL, headers: response.http_headers ?? [:], formats: validated + [master],
                          isLive: live, liveStatus: response.live_status, duration: live ? nil : response.duration,
                          captionTracks: Self.captions(response), storyboard: Self.storyboard(formats))
        } catch is CancellationError { throw CancellationError() }
        catch { return try base.get() }
    }
}
#endif
