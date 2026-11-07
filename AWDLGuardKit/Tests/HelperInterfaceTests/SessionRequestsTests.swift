import HelperInterface
import Testing

@Suite struct SessionRequestsTests {
    @Test func anySessionWantingSuppressionWins() {
        var requests = SessionRequests()
        requests.set(false, for: 1)
        requests.set(true, for: 2)
        #expect(requests.isSuppressionWanted)
    }

    @Test func removingTheLastSuppressingSessionReleases() {
        var requests = SessionRequests()
        requests.set(true, for: 1)
        requests.set(false, for: 2)
        requests.remove(1)
        #expect(!requests.isSuppressionWanted)
        #expect(!requests.isEmpty)
    }

    @Test func heldForOthersExcludesTheAskingSession() {
        var requests = SessionRequests()
        requests.set(true, for: 1)
        requests.set(false, for: 2)
        #expect(!requests.isHeldForOthers(excluding: 1))
        #expect(requests.isHeldForOthers(excluding: 2))
    }

    @Test func aSessionChangingItsMindReplacesItsRequest() {
        var requests = SessionRequests()
        requests.set(true, for: 1)
        requests.set(false, for: 1)
        #expect(!requests.isSuppressionWanted)
    }

    @Test func emptyAfterTheLastSessionEnds() {
        var requests = SessionRequests()
        requests.set(true, for: 1)
        requests.remove(1)
        #expect(requests.isEmpty)
        #expect(!requests.isSuppressionWanted)
    }
}
