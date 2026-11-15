#if os(macOS)
import Foundation
import Testing
@testable import SmartTubeIOS

@Suite("yt-dlp structured stream validation")
struct YTDLPStreamResolverTests {
    @Test func preservesHeaders() throws {
        let data = Data(
            #"{"url":"https://example.com/video","acodec":"aac","vcodec":"h264","http_headers":{"User-Agent":"test-agent","Referer":"https://www.youtube.com/"}}"#
                .utf8)
        let stream = try YTDLPStreamResolver.parse(data)
        #expect(stream.headers["User-Agent"] == "test-agent")
        #expect(stream.headers["Referer"] == "https://www.youtube.com/")
    }
    @Test(arguments: ["http://example.com/v", "file:///tmp/video", "https://user:secret@example.com/v", "https://"])
    func rejectsUnsafeURL(_ url: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["url": url, "acodec": "aac", "vcodec": "h264"])
        #expect(throws: YTDLPStreamResolver.Failure.self) { try YTDLPStreamResolver.parse(data) }
    }
    @Test func rejectsSeparateAudioAndHeaderInjection() throws {
        for fields in [
            ["url": "https://example.com/v", "acodec": "none", "vcodec": "h264"],
            [
                "url": "https://example.com/v", "acodec": "aac", "vcodec": "h264",
                "http_headers": ["Referer": "value\r\nInjected: bad"],
            ],
        ] as [[String: Any]] {
            let data = try JSONSerialization.data(withJSONObject: fields)
            #expect(throws: YTDLPStreamResolver.Failure.self) { try YTDLPStreamResolver.parse(data) }
        }
    }
    private func response(
        status: String, protocolName: String = "m3u8_native", audio: String = "mp4a.40.2", video: String = "avc1.640028"
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "live_status": status, "is_live": true, "duration": 12345.0,
            "formats": [
                [
                    "format_id": "live", "url": "https://example.com/manifest",
                    "height": 720, "ext": "mp4", "protocol": protocolName,
                    "acodec": audio, "vcodec": video,
                ]
            ],
        ])
    }
    @Test func liveHLSHasNoFixedDuration() throws {
        let stream = try YTDLPStreamResolver.parse(response(status: "is_live"))
        #expect(stream.isLive)
        #expect(stream.duration == nil)
        #expect(YTDLPStreamResolver.playbackFormats(stream.formats, isLive: true).count == 1)
    }
    @Test func completedRecordingOverridesStaleLiveFlag() throws {
        let stream = try YTDLPStreamResolver.parse(response(status: "was_live"))
        #expect(!stream.isLive)
        #expect(stream.duration == 12345)
    }
    @Test func processingRecordingHasActionableError() throws {
        let data = Data(#"{"live_status":"post_live","formats":[]}"#.utf8)
        #expect(throws: YTDLPStreamResolver.Failure.processing) { try YTDLPStreamResolver.parse(data) }
    }
    @Test func rejectsFragmentManifestsAV1AndSilentLive() throws {
        for data in [
            try response(status: "is_live", protocolName: "http_dash_segments"),
            try response(status: "is_live", video: "av01.0.08M.08"),
            try response(status: "is_live", audio: "none"),
        ] {
            #expect(throws: YTDLPStreamResolver.Failure.noStreams) { try YTDLPStreamResolver.parse(data) }
        }
    }

    @Test func preservesSameHeightFallbackAndPortraitSizes() throws {
        let data = try JSONSerialization.data(withJSONObject: ["formats": [
            ["format_id": "combined", "url": "https://example.com/combined", "ext": "mp4", "height": 1920,
             "vcodec": "avc1.640028", "acodec": "mp4a.40.2"],
            ["format_id": "separate", "url": "https://example.com/video", "ext": "mp4", "height": 1920,
             "vcodec": "avc1.640028", "acodec": "none"],
            ["format_id": "audio", "url": "https://example.com/audio", "ext": "m4a",
             "vcodec": "none", "acodec": "mp4a.40.2"],
        ]])
        let stream = try YTDLPStreamResolver.parse(data)
        #expect(YTDLPStreamResolver.playbackFormats(stream.formats).count == 1)
        #expect(YTDLPStreamResolver.startupFormats(stream).map(\.id) == ["combined", "separate"])
    }
    @Test @MainActor func validatesMediaResponseRanges() throws {
        func response(_ range: String, length: String = "10") -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "https://example.com/v")!, statusCode: 206,
                            httpVersion: nil, headerFields: ["Content-Range": range, "Content-Length": length])!
        }
        let valid = try YTDLPRangeLoader.responseRange(response("bytes 20-29/100"), start: 20)
        #expect(valid?.end == 29)
        #expect(valid?.total == 100)
        for range in ["bytes 0-9/100", "bytes 20-29/*", "bytes 20-200/100", "nonsense"] {
            #expect(throws: Error.self) { try YTDLPRangeLoader.responseRange(response(range), start: 20) }
        }
        #expect(throws: Error.self) {
            try YTDLPRangeLoader.responseRange(response("bytes 20-29/100", length: "5"), start: 20)
        }
    }

    @Test func promotesOnlyHLSMastersWithNativeVideoAndReferencedAudio() throws {
        let valid = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",URI="audio.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=1000,CODECS="avc1.640028,mp4a.40.2",RESOLUTION=1920x1080,AUDIO="aac"
        video.m3u8
        """
        let url = URL(string: "https://example.com/master.m3u8")!
        let master = try YTDLPStreamResolver.validatedMaster(Data(valid.utf8), url: url, headers: [:])
        #expect(master?.height == 1080)
        #expect(master?.nativeAudio == true)
        #expect(master?.isHLS == true)
        for invalid in [valid.replacingOccurrences(of: "avc1.640028", with: "vp09.00.10.08"),
                        valid.replacingOccurrences(of: "AUDIO=\"aac\"", with: "AUDIO=\"missing\"")] {
            #expect(try YTDLPStreamResolver.validatedMaster(Data(invalid.utf8), url: url, headers: [:]) == nil)
        }
    }
    @Test func prefersOriginalAudioOverEquallyRatedDub() throws {
        let data = try JSONSerialization.data(withJSONObject: ["formats": [
            ["format_id": "v", "url": "https://example.com/v", "ext": "mp4", "height": 720,
             "vcodec": "avc1", "acodec": "none"],
            ["format_id": "dub", "url": "https://example.com/dub", "ext": "m4a", "vcodec": "none",
             "acodec": "mp4a.40.2", "tbr": 130, "language": "bn", "language_preference": -1],
            ["format_id": "original", "url": "https://example.com/original", "ext": "m4a", "vcodec": "none",
             "acodec": "mp4a.40.2", "tbr": 130, "language": "en-US", "language_preference": 10],
        ]])
        #expect(YTDLPStreamResolver.audioFormats(try YTDLPStreamResolver.parse(data)).first?.id == "original")
    }

    @Test func originalSeparateAudioOutranksWrongLanguageCombined() throws {
        let data = try JSONSerialization.data(withJSONObject: ["formats": [
            ["format_id": "dubbed-combined", "url": "https://example.com/dubbed", "ext": "mp4", "height": 360,
             "vcodec": "avc1", "acodec": "mp4a.40.2", "language": "bn"],
            ["format_id": "v", "url": "https://example.com/v", "ext": "mp4", "height": 1080,
             "vcodec": "avc1", "acodec": "none"],
            ["format_id": "a", "url": "https://example.com/a", "ext": "m4a", "vcodec": "none",
             "acodec": "mp4a.40.2", "language": "en-US", "language_preference": 10],
        ]])
        let stream = try YTDLPStreamResolver.parse(data)
        #expect(YTDLPStreamResolver.startupFormats(stream).map(\.id) == ["v", "dubbed-combined"])
    }

    @Test func resolutionCeilingUsesActualPortraitDimensions() throws {
        let data = try JSONSerialization.data(withJSONObject: ["formats": [
            ["format_id": "portrait720", "url": "https://example.com/720", "ext": "mp4", "width": 405, "height": 720,
             "vcodec": "avc1", "acodec": "mp4a.40.2"],
            ["format_id": "portrait1080", "url": "https://example.com/1080", "ext": "mp4", "width": 608, "height": 1080,
             "vcodec": "avc1", "acodec": "mp4a.40.2"],
        ]])
        let stream = try YTDLPStreamResolver.parse(data)
        #expect(YTDLPPlaybackAsset.maximumResolution(stream: stream, preferredHeight: 720) == CGSize(width: 405, height: 720))
        #expect(YTDLPPlaybackAsset.maximumResolution(stream: stream, preferredHeight: 1080) == CGSize(width: 608, height: 1080))
        #expect(YTDLPPlaybackAsset.maximumResolution(stream: stream, preferredHeight: 360) == nil)
    }

    @Test func upcomingPremiereIsNotReportedAsPlaybackDefect() throws {
        let data = Data(#"{"live_status":"is_upcoming","formats":[]}"#.utf8)
        #expect(throws: YTDLPProcessRunner.ExtractionFailure.upcoming) { try YTDLPStreamResolver.parse(data) }
    }

}
#endif
