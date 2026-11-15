import Foundation
import Testing

@testable import SmartTubeIOS

@Suite("Playback reopen session policy")
struct PlaybackSessionLeaseTests {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    @Test func tenConsecutiveCloseReopenCyclesRejectOldCallbacks() {
        var session = PlaybackSessionLease()
        var obsolete: [UUID] = []
        for cycle in 0..<10 {
            obsolete.append(session.token)
            session.advance()  // close
            session.park(at: now.addingTimeInterval(Double(cycle)))
            obsolete.append(session.token)
            session.advance()  // reopen the SAME video
            #expect(obsolete.allSatisfy { !session.isCurrent($0) })
            #expect(
                session.canReuse(
                    now: now.addingTimeInterval(Double(cycle) + 1), resolvedAt: nil, urls: [], isLive: false))
        }
    }
    @Test func readyItemStillRequiresFreshSignedURLs() {
        var session = PlaybackSessionLease()
        session.park(at: now)
        let expired = URL(string: "https://example.com/video?expire=1999999999")!
        #expect(!session.canReuse(now: now, resolvedAt: now, urls: [expired], isLive: false))
        let expiring = URL(string: "https://example.com/video?expire=2000000010")!
        #expect(!session.canReuse(now: now, resolvedAt: now, urls: [expiring], isLive: false))
    }
    @Test func staleResolvedCatalogueCannotBeReused() {
        var session = PlaybackSessionLease()
        session.park(at: now)
        #expect(!session.canReuse(now: now, resolvedAt: now.addingTimeInterval(-100), urls: [], isLive: false))
    }
    @Test func liveBroadcastRequiresFreshResolutionAfterClose() {
        var session = PlaybackSessionLease()
        session.park(at: now)
        #expect(!session.canReuse(now: now, resolvedAt: now, urls: [], isLive: true))
    }
    @Test func recentVODCanReuseButOldParkedItemCannot() {
        var session = PlaybackSessionLease()
        session.park(at: now)
        #expect(session.canReuse(now: now, resolvedAt: now, urls: [], isLive: false))
        #expect(!session.canReuse(now: now.addingTimeInterval(91), resolvedAt: nil, urls: [], isLive: false))
    }
}
