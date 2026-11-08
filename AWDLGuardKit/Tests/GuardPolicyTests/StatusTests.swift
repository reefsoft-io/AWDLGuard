import GuardPolicy
import HelperInterface
import Testing

private let suppress = Decision(reason: .game(appName: "GeForce NOW"))
private let allow = Decision(reason: .noTrigger)

@Suite struct StatusTests {
    @Test func suppressedOnlyWhenHelperConfirmsDown() {
        let down = InterfaceObservation(isSuppressing: true, isInterfaceUp: false)
        let status = Status(decision: suppress, helper: .connected(down))
        #expect(status.tone == .suppressed)
        #expect(status.title == "AWDL Off")
        #expect(status.detail == "GeForce NOW in foreground")
    }

    @Test func interfaceStillUpIsAProblem() {
        let up = InterfaceObservation(isSuppressing: true, isInterfaceUp: true)
        #expect(Status(decision: suppress, helper: .connected(up)).tone == .problem)
    }

    @Test func unreadableInterfaceIsAProblem() {
        let unknown = InterfaceObservation(isSuppressing: true, isInterfaceUp: nil)
        #expect(Status(decision: suppress, helper: .connected(unknown)).tone == .problem)
    }

    @Test func failureWinsOverDownInterface() {
        let failed = InterfaceObservation(
            isSuppressing: true, isInterfaceUp: false,
            failure: InterfaceFailure(operation: .bringDown, code: 9))
        let status = Status(decision: suppress, helper: .connected(failed))
        #expect(status.tone == .problem)
        #expect(status.detail.contains("error 9"))
    }

    @Test func reactivationsAreReported() {
        let observation = InterfaceObservation(isSuppressing: true, isInterfaceUp: false, reactivationCount: 3)
        #expect(Status(decision: suppress, helper: .connected(observation)).detail == "Re-enabled by macOS 3 times")
    }

    @Test func helperNotYetSuppressingIsPending() {
        let stale = InterfaceObservation(isSuppressing: false, isInterfaceUp: true)
        #expect(Status(decision: suppress, helper: .connected(stale)).tone == .pending)
    }

    @Test func allowedExplainsReason() {
        let up = InterfaceObservation(isSuppressing: false, isInterfaceUp: true)
        let status = Status(decision: allow, helper: .connected(up))
        #expect(status.tone == .allowed)
        #expect(status.title == "AWDL On")
        #expect(status.detail == "No game in foreground")
    }

    @Test func downWhileAllowedIsNotAFault() {
        let down = InterfaceObservation(isSuppressing: false, isInterfaceUp: false)
        #expect(Status(decision: allow, helper: .connected(down)).tone == .allowed)
    }

    @Test func helperProblemsNeverShowSuppressed() {
        for state in [HelperState.needsApproval, .failed] {
            #expect(Status(decision: suppress, helper: state).tone == .problem)
        }
        #expect(Status(decision: suppress, helper: .connecting).tone == .pending)
    }

    @Test func everyBranchHasItsCopy() {
        func connected(
            _ isSuppressing: Bool, up: Bool?, count: Int = 0, failure: InterfaceFailure.Operation? = nil
        ) -> HelperState {
            .connected(
                InterfaceObservation(
                    isSuppressing: isSuppressing, isInterfaceUp: up, reactivationCount: count,
                    failure: failure.map { InterfaceFailure(operation: $0, code: 1) }))
        }
        let cases: [(Decision, HelperState, Status.Tone, String, String)] = [
            (suppress, .needsApproval, .problem, "Approval Required", "Turn on background activity"),
            (suppress, .connecting, .pending, "Connecting…", "GeForce NOW in foreground"),
            (suppress, .failed, .problem, "Helper Not Working", "Repair to set it up again"),
            (suppress, connected(false, up: true), .pending, "Turning Off…", "GeForce NOW in foreground"),
            (suppress, connected(true, up: false), .suppressed, "AWDL Off", "GeForce NOW in foreground"),
            (suppress, connected(true, up: false, count: 1), .suppressed, "AWDL Off", "Re-enabled by macOS once"),
            (suppress, connected(true, up: true), .problem, "AWDL Still On", "macOS kept it on"),
            (suppress, connected(true, up: nil), .problem, "Status Unavailable", "Couldn't check AWDL"),
            (
                suppress, connected(true, up: false, failure: .bringDown), .problem, "Couldn't Turn Off",
                "Operation not permitted while turning AWDL off (error 1)"
            ),
            (allow, connected(true, up: false), .pending, "Turning On…", "No game in foreground"),
            (
                allow, connected(false, up: false, failure: .bringUp), .problem, "Couldn't Turn On",
                "Operation not permitted while turning AWDL on (error 1)"
            ),
            (allow, connected(false, up: false), .allowed, "AWDL Off", "Turned off by macOS"),
            (allow, connected(false, up: true), .allowed, "AWDL On", "No game in foreground"),
        ]
        for (decision, helper, tone, title, detail) in cases {
            let status = Status(decision: decision, helper: helper)
            #expect(status.tone == tone, "\(helper)")
            #expect(status.title == title, "\(helper)")
            #expect(status.detail == detail, "\(helper)")
        }
    }

    @Test func heldForAnotherSessionWhileAllowed() {
        let held = InterfaceObservation(isSuppressing: true, isHeldForOthers: true, isInterfaceUp: false)
        let status = Status(decision: allow, helper: .connected(held))
        #expect(status.tone == .allowed)
        #expect(status.title == "AWDL Off")
        #expect(status.detail == "Kept off for another user")
    }

    @Test func unrecordableSuppressionIsAProblemNotPending() {
        let failed = InterfaceObservation(
            isSuppressing: false, isInterfaceUp: true,
            failure: InterfaceFailure(operation: .recordState, code: 30))
        let status = Status(decision: suppress, helper: .connected(failed))
        #expect(status.tone == .problem)
        #expect(status.title == "Couldn't Turn Off")
        #expect(status.detail.contains("while saving AWDL state (error 30)"))
        #expect(Status(decision: allow, helper: .connected(failed)).tone == .allowed)
    }

    @Test func notWatchingOffersRepair() {
        let unwatched = InterfaceObservation(isSuppressing: true, isInterfaceUp: false, isWatching: false)
        let status = Status(decision: suppress, helper: .connected(unwatched))
        #expect(status.tone == .problem)
        #expect(status.title == "Not Watching AWDL")
        #expect(status.remedy == .repair)
    }

    @Test func remediesMatchHelperProblems() {
        #expect(Status(decision: suppress, helper: .needsApproval).remedy == .approve)
        // Names the System Settings section, not just the Login Items page, which also lists
        // Open at Login.
        #expect(Status(decision: suppress, helper: .needsApproval).detail == "Turn on background activity")
        #expect(Status(decision: suppress, helper: .failed).remedy == .repair)
        #expect(Status(decision: suppress, helper: .connecting).remedy == nil)
        let down = InterfaceObservation(isSuppressing: true, isInterfaceUp: false)
        #expect(Status(decision: suppress, helper: .connected(down)).remedy == nil)
    }
}
