import Foundation
import Testing

@testable import SmartTubeIOSCore

@Suite("Watch recommendation renderer compatibility")
struct RelatedVideoResponseTests {
    private func lockup(id: String, badge: String = "18:37", live: Bool = false) -> [String: Any] {
        ["lockupViewModel": [
            "contentId": id,
            "contentType": "LOCKUP_CONTENT_TYPE_VIDEO",
            "rendererContext": ["commandContext": ["onTap": ["innertubeCommand": ["watchEndpoint": ["videoId": id]]]]],
            "metadata": ["lockupMetadataViewModel": [
                "title": ["content": "A related video"],
                "metadata": ["contentMetadataViewModel": ["metadataRows": [["metadataParts": [["text": ["content": "Example channel"]]]]]]],
            ]],
            "contentImage": ["thumbnailViewModel": [
                "image": ["sources": [["url": "https://i.ytimg.com/vi/\(id)/hqdefault.jpg", "width": 336, "height": 188]]],
                "overlays": [["thumbnailBottomOverlayViewModel": ["badges": [["thumbnailBadgeViewModel": [
                    "text": badge, "badgeStyle": live ? "THUMBNAIL_OVERLAY_BADGE_STYLE_LIVE" : "THUMBNAIL_OVERLAY_BADGE_STYLE_DEFAULT",
                ]]]]]],
            ]],
        ]]
    }

    @Test("Modern WEB secondaryResults retain thumbnails, duration, channel and order")
    func modernWebResponse() async throws {
        let api = InnerTubeAPI()
        let first = lockup(id: "first")
        let response: [String: Any] = ["contents": ["twoColumnWatchNextResults": [
            "results": ["videoRenderer": ["videoId": "current", "title": ["simpleText": "Current"]]],
            "secondaryResults": ["secondaryResults": ["results": [["itemSectionRenderer": ["contents": [first, lockup(id: "live", badge: "LIVE", live: true), first]]]]]],
        ]]]
        let videos = await api.parseRelatedVideos(from: response)
        #expect(videos.map(\.id) == ["first", "live"])
        let firstVideo = try #require(videos.first)
        #expect(firstVideo.channelTitle == "Example channel")
        #expect(firstVideo.duration == 1117)
        #expect(firstVideo.thumbnailURL?.host == "i.ytimg.com")
        #expect(videos.last?.isLive == true)
    }

    @Test("Legacy compactVideoRenderer remains supported")
    func legacyResponse() async {
        let api = InnerTubeAPI()
        let response: [String: Any] = ["contents": ["compactVideoRenderer": [
            "videoId": "legacy", "title": ["simpleText": "Legacy"], "lengthText": ["simpleText": "1:02"],
        ]]]
        let videos = await api.parseRelatedVideos(from: response)
        #expect(videos.first?.id == "legacy")
        #expect(videos.first?.duration == 62)
    }

    @Test("Empty responses produce an empty list for the caller's search fallback")
    func emptyResponse() async {
        let api = InnerTubeAPI()
        #expect(await api.parseRelatedVideos(from: [:]).isEmpty)
    }
}
