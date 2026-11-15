#if os(macOS)
import Foundation
import Testing
@testable import SmartTubeIOS

@Suite("Native stream failure classification")
struct NativePlaybackRecoveryPolicyTests {
    @Test func nestedHTTPRejection() {
        let transport = NSError(domain: "MacTube.Range", code: 403)
        let wrapped = NSError(domain: "AVFoundationErrorDomain", code: -11800,
                              userInfo: [NSUnderlyingErrorKey: transport])
        #expect(NativePlaybackRecoveryPolicy.classify(wrapped) == .rejected)
    }
    @Test func expiredSignedURLTakesPrecedence() {
        let failure = NSError(domain: "AVFoundationErrorDomain", code: -11800)
        #expect(NativePlaybackRecoveryPolicy.classify(failure, now: Date(timeIntervalSince1970: 100),
                    url: "https://example.test/media?expire=99") == .expired)
    }
    @Test func networkInterruptionDiffersFromUnsupportedMedia() {
        #expect(NativePlaybackRecoveryPolicy.classify(NSError(domain: NSURLErrorDomain,
                    code: NSURLErrorNetworkConnectionLost)) == .network)
        #expect(NativePlaybackRecoveryPolicy.classify(YTDLPStreamResolver.Failure.unsupported) == .unsupported)
        #expect(NativePlaybackRecoveryPolicy.classify(YTDLPStreamResolver.Failure.timeout) == .timeout)
    }
    @Test func permanentExtractionFailuresDoNotResolveAgain() {
        for failure in [YTDLPProcessRunner.ExtractionFailure.signIn, .unavailable, .upcoming, .challenge] {
            #expect(!NativePlaybackRecoveryPolicy.shouldRefresh(after: failure))
        }
        #expect(!NativePlaybackRecoveryPolicy.shouldRefresh(after: YTDLPStreamResolver.Failure.missingExecutable))
        #expect(NativePlaybackRecoveryPolicy.shouldRefresh(after: YTDLPProcessRunner.ExtractionFailure.delivery))
        #expect(NativePlaybackRecoveryPolicy.shouldRefresh(after: YTDLPProcessRunner.ExtractionFailure.network))
    }
    @Test func failedAudioURLIsAttributedWithoutRejectingVideo() {
        let audio = "https://example.test/audio?expire=200"
        let transport = NSError(domain: "MacTube.MediaHTTP", code: 403,
            userInfo: [NSURLErrorFailingURLStringErrorKey: audio])
        let wrapped = NSError(domain: "AVFoundationErrorDomain", code: -11800,
            userInfo: [NSUnderlyingErrorKey: transport])
        #expect(NativePlaybackRecoveryPolicy.failedMediaURL(wrapped) == audio)
    }
    @Test func opaqueAVFoundationFailureIsNotCalledExternalRestriction() {
        #expect(NativePlaybackRecoveryPolicy.classify(NSError(domain: "AVFoundationErrorDomain",
                    code: -11828)) == .unknown)
    }
}
#endif
