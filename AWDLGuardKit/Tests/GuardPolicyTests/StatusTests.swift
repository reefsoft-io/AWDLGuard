import GuardPolicy
import HelperInterface
import Testing

private let suppress = Decision(isSuppressed: true, reason: .game(appName: "GeForce NOW"))
private let allow = Decision(isSuppressed: false, reason: .noTrigger)

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
        for state in [HelperState.notInstalled, .needsApproval, .notResponding] {
            #expect(Status(decision: suppress, helper: state).tone == .problem)
        }
        #expect(Status(decision: suppress, helper: .connecting).tone == .pending)
    }

    @Test func repairingIsPending() {
        let status = Status(decision: suppress, helper: .repairing)
        #expect(status.tone == .pending)
        #expect(status.title == "Repairing…")
        #expect(status.detail == "Restarting helper")
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
        #expect(Status(decision: suppress, helper: .notInstalled).remedy == .install)
        #expect(Status(decision: suppress, helper: .needsApproval).remedy == .approve)
        // Names the System Settings section, not just the Login Items page, which also lists
        // Open at Login.
        #expect(Status(decision: suppress, helper: .needsApproval).detail == "Allow in the Background")
        #expect(Status(decision: suppress, helper: .notResponding).remedy == .repair)
        #expect(Status(decision: suppress, helper: .repairing).remedy == nil)
        #expect(Status(decision: suppress, helper: .connecting).remedy == nil)
        let down = InterfaceObservation(isSuppressing: true, isInterfaceUp: false)
        #expect(Status(decision: suppress, helper: .connected(down)).remedy == nil)
    }
}
