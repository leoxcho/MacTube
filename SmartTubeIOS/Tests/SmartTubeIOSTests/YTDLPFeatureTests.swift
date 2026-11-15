#if os(macOS)
import Foundation
import Testing
@testable import SmartTubeIOS

@Suite("yt-dlp quality and download policy")
struct YTDLPFeatureTests {
    private func catalogue(withAudio: Bool) throws -> YTDLPStreamResolver.Stream {
        var formats: [[String: Any]] = [
            [
                "format_id": "18", "url": "https://example.com/360", "height": 360, "ext": "mp4", "vcodec": "avc1",
                "acodec": "aac",
            ],
            [
                "format_id": "137", "url": "https://example.com/1080", "height": 1080, "ext": "mp4", "vcodec": "avc1",
                "acodec": "none",
            ],
            [
                "format_id": "webm", "url": "https://example.com/1440", "height": 1440, "ext": "webm", "vcodec": "vp09",
                "acodec": "none",
            ],
            [
                "format_id": "av1", "url": "https://example.com/2160", "height": 2160, "ext": "mp4", "vcodec": "av01",
                "acodec": "none",
            ],
        ]
        if withAudio {
            formats.append([
                "format_id": "140", "url": "https://example.com/audio", "ext": "m4a", "acodec": "aac", "vcodec": "none",
            ])
        }
        return try YTDLPStreamResolver.parse(
            JSONSerialization.data(withJSONObject: [
                "url": "https://example.com/360", "acodec": "aac", "vcodec": "avc1", "formats": formats,
            ]))
    }
    @Test func onlyAvailableNativeHeights() throws {
        #expect(
            YTDLPStreamResolver.playbackFormats(try catalogue(withAudio: true).formats).compactMap(\.height) == [
                1080, 360,
            ])
    }
    @Test func separateVideoRequiresAudio() throws {
        #expect(
            YTDLPStreamResolver.playbackFormats(try catalogue(withAudio: false).formats).compactMap(\.height) == [360])
    }
    @Test func startupRetainsNativeAlternativeAfterCombinedStream() throws {
        let stream = try catalogue(withAudio: true)
        #expect(YTDLPStreamResolver.startupFormats(stream).map(\.id) == ["18", "137"])
    }
    @Test func startupDoesNotOfferSilentAlternativeWithoutAAC() throws {
        let stream = try catalogue(withAudio: false)
        #expect(YTDLPStreamResolver.startupFormats(stream).map(\.id) == ["18"])
    }
    @Test func downloadUsesMergeAndHeightCap() throws {
        let request = YTDLPDownloadRequest(
            videoID: "test", height: 2160, audioOnly: false, destination: URL(fileURLWithPath: "/tmp"))
        let args = try request.arguments(ffmpeg: "/test/ffmpeg")
        #expect(
            args.contains(
                "bestvideo[ext=mp4][height<=2160]+bestaudio[ext=m4a]/best[ext=mp4][acodec!=none][vcodec!=none][height<=2160]"
            ))
        #expect(args.contains("--continue"))
        #expect(args.contains("--no-overwrites"))
        #expect(args.contains("--ffmpeg-location"))
        #expect(throws: YTDLPStreamResolver.Failure.self) { try request.arguments(ffmpeg: nil) }
    }
    @Test func requestedHDNeverEscapesCapAndAllowsLowerFormats() throws {
        let request = YTDLPDownloadRequest(
            videoID: "test", height: 1080, audioOnly: false, destination: URL(fileURLWithPath: "/tmp"))
        let args = try request.arguments(ffmpeg: "/test/ffmpeg")
        let index = try #require(args.firstIndex(of: "-f"))
        #expect(args[index + 1] == "bestvideo[ext=mp4][height<=1080]+bestaudio[ext=m4a]/best[ext=mp4][acodec!=none][vcodec!=none][height<=1080]")
    }
    @Test func combinedOnlyDownloadStillRespectsCeiling() throws {
        let request = YTDLPDownloadRequest(
            videoID: "test", height: 360, audioOnly: false, destination: URL(fileURLWithPath: "/tmp"))
        #expect(try request.arguments(ffmpeg: nil).contains("best[ext=mp4][acodec!=none][vcodec!=none][height<=360]"))
    }
    @Test func audioNeedsNoFFmpeg() throws {
        let request = YTDLPDownloadRequest(
            videoID: "test", height: nil, audioOnly: true, destination: URL(fileURLWithPath: "/tmp"))
        #expect(try request.arguments(ffmpeg: nil).contains("bestaudio[ext=m4a]/bestaudio"))
    }
    @Test func structuredProgressClampsAndRejectsUnknownTotals() {
        #expect(YTDLPDownloadRequest.progress(in: Data(#"{"downloaded_bytes":50,"total_bytes":100}"#.utf8)) == 0.5)
        #expect(YTDLPDownloadRequest.progress(in: Data(#"{"downloaded_bytes":200,"total_bytes":100}"#.utf8)) == 1)
        #expect(YTDLPDownloadRequest.progress(in: Data(#"{"downloaded_bytes":50,"total_bytes":"NA","total_bytes_estimate":100}"#.utf8)) == 0.5)
        #expect(YTDLPDownloadRequest.progress(in: Data(#"{"downloaded_bytes":50}"#.utf8)) == nil)
    }
}
#endif
