#if os(macOS)
import Foundation

struct YTDLPDownloadRequest: Sendable {
    let videoID: String
    let height: Int?
    let audioOnly: Bool
    let destination: URL
    static var ffmpeg: String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }
    func arguments(ffmpeg: String? = Self.ffmpeg) throws -> [String] {
        if let height, !YTDLPStreamResolver.heights.contains(height) { throw YTDLPStreamResolver.Failure.invalidOutput }
        let url = try YTDLPProcessRunner.watchURL(videoID)
        let cap = (height ?? (ffmpeg == nil ? 360 : nil)).map { "[height<=\($0)]" } ?? ""
        let format: String
        if audioOnly {
            format =
                ffmpeg == nil
                ? "bestaudio[ext=m4a]/bestaudio" : "bestaudio[ext=m4a]/bestaudio/best[acodec!=none][vcodec!=none]"
        } else if ffmpeg != nil {
            let separate = "bestvideo[ext=mp4]\(cap)+bestaudio[ext=m4a]"
            let combined = "best[ext=mp4][acodec!=none][vcodec!=none]\(cap)"
            // A requested resolution is a ceiling: old/low-resolution uploads may
            // never offer that exact height. Keep the highest capped video first
            // so a combined 360p stream cannot win over requested 1080p video.
            format = "\(separate)/\(combined)"
        } else {
            guard (height ?? 360) <= 360 else { throw YTDLPStreamResolver.Failure.ffmpeg }
            format = "best[ext=mp4][acodec!=none][vcodec!=none]\(cap)"
        }
        let label = audioOnly ? "audio" : height.map { "\($0)p" } ?? "best"
        var args = [
            "--format-sort", "proto:https", "--check-formats",
            "--no-simulate", "--newline", "--quiet", "--progress", "--progress-delta", "0.5",
            "--progress-template",
            "download:{\"downloaded_bytes\":%(progress.downloaded_bytes)j,\"total_bytes\":%(progress.total_bytes)j,\"total_bytes_estimate\":%(progress.total_bytes_estimate)j,\"status\":%(progress.status)j}",
            "--continue", "--no-overwrites", "--write-info-json", "--write-thumbnail",
            "--paths", destination.path, "--output", "%(title).180B [%(id)s] [\(label)].%(ext)s",
            "--print", "after_move:{\"filepath\":%(filepath)j}", "-f", format,
        ]
        if let ffmpeg { args += ["--ffmpeg-location", ffmpeg, "--merge-output-format", "mp4", "--embed-metadata"] }
        if audioOnly, ffmpeg != nil { args += ["--extract-audio", "--audio-format", "m4a"] }
        return args + ["--", url]
    }
    static func result(in output: Data, destination: URL) throws -> URL {
        for line in output.split(separator: 10).reversed() {
            if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                let path = object["filepath"] as? String
            {
                let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
                guard url.deletingLastPathComponent() == destination.resolvingSymlinksInPath(),
                    FileManager.default.fileExists(atPath: url.path)
                else { throw YTDLPStreamResolver.Failure.invalidOutput }
                return url
            }
        }
        throw YTDLPStreamResolver.Failure.invalidOutput
    }
    static func progress(in line: Data) -> Double? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let downloaded = object["downloaded_bytes"] as? Double,
            let total = (object["total_bytes"] as? Double) ?? (object["total_bytes_estimate"] as? Double),
            total > 0, downloaded.isFinite, total.isFinite
        else { return nil }
        return min(1, max(0, downloaded / total))
    }
}

#endif
