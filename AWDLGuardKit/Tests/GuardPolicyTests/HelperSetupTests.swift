import GuardPolicy
import HelperInterface
import Testing

private let up = InterfaceObservation(isSuppressing: false, isInterfaceUp: true)
private let down = InterfaceObservation(isSuppressing: true, isInterfaceUp: false)
private let reply = HelperSetup.replyTimeout
private let poll = HelperSetup.approvalPoll

/// A setup driven into `phase` through real events, so every test starts from a state the
/// machine can actually reach.
private func setup(at phase: Reachable) -> HelperSetup {
    var setup = HelperSetup()
    switch phase {
    case .registering:
        _ = setup.handle(.refreshed(.notRegistered))
    case .awaitingApproval:
        _ = setup.handle(.refreshed(.requiresApproval))
    case .connecting:
        _ = setup.handle(.refreshed(.enabled))
    case .connected:
        _ = setup.handle(.refreshed(.enabled))
        _ = setup.handle(.replied(session: 1, up))
    case .waitingToReregister:
        _ = setup.handle(.refreshed(.enabled))
        _ = setup.handle(.sessionEnded(session: 1))
    case .failed:
        _ = setup.handle(.refreshed(.notRegistered))
        for _ in 1..<HelperSetup.maxFailures {
            _ = setup.handle(.registerFinished(.notRegistered))
            _ = setup.handle(.timerFired(.notRegistered))
        }
        _ = setup.handle(.registerFinished(.notRegistered))
    }
    return setup
}

private enum Reachable {
    case registering, awaitingApproval, connecting, connected, waitingToReregister, failed
}

@Suite struct HelperSetupTests {
    // MARK: Deciding from the registration

    @Test func unregisteredHelperIsRegistered() {
        var setup = HelperSetup()
        #expect(setup.handle(.refreshed(.notRegistered)) == [.cancelTimer, .register])
        #expect(setup.phase == .registering(failures: 0))
        #expect(setup.state == .connecting)
    }

    @Test func approvalWaitingAtLaunchDoesNotOpenSettings() {
        var setup = HelperSetup()
        #expect(setup.handle(.refreshed(.requiresApproval)) == [.startTimer(poll)])
        #expect(setup.state == .needsApproval)
    }

    @Test func enabledHelperIsConnected() {
        var setup = HelperSetup()
        #expect(setup.handle(.refreshed(.enabled)) == [.openSession(1), .sendRequest(1), .startTimer(reply)])
        #expect(setup.phase == .connecting(session: 1, failures: 0, unanswered: 1))
    }

    // MARK: Registering

    @Test func ownRegistrationNeedingApprovalOpensSettings() {
        var setup = setup(at: .registering)
        #expect(setup.handle(.registerFinished(.requiresApproval)) == [.openSettings, .startTimer(poll)])
        #expect(setup.state == .needsApproval)
    }

    @Test func registrationThatWorkedConnects() {
        var setup = setup(at: .registering)
        #expect(setup.handle(.registerFinished(.enabled)) == [.openSession(1), .sendRequest(1), .startTimer(reply)])
    }

    @Test func failedRegistrationRetriesWithBackoff() {
        var setup = setup(at: .registering)
        #expect(setup.handle(.registerFinished(.notRegistered)) == [.startTimer(.seconds(1))])
        #expect(setup.phase == .waitingToRetry(failures: 1, retry: .register))
        #expect(setup.handle(.timerFired(.notRegistered)) == [.cancelTimer, .register])
        #expect(setup.handle(.registerFinished(.notRegistered)) == [.startTimer(.seconds(2))])
    }

    @Test func registrationThatErredButSucceededConnectsOnRetry() {
        var setup = setup(at: .registering)
        _ = setup.handle(.registerFinished(.notRegistered))
        #expect(setup.handle(.timerFired(.enabled)) == [.openSession(1), .sendRequest(1), .startTimer(reply)])
        #expect(setup.phase == .connecting(session: 1, failures: 1, unanswered: 1))
    }

    @Test func attemptsRunOutIntoFailed() {
        let setup = setup(at: .failed)
        #expect(setup.phase == .failed)
        #expect(setup.state == .failed)
    }

    // MARK: Approval

    @Test func approvalPollKeepsPolling() {
        var setup = setup(at: .awaitingApproval)
        #expect(setup.handle(.timerFired(.requiresApproval)) == [.startTimer(poll)])
        #expect(setup.handle(.refreshed(.requiresApproval)) == [])
    }

    @Test func approvalConnects() {
        var setup = setup(at: .awaitingApproval)
        #expect(setup.handle(.timerFired(.enabled)) == [.openSession(1), .sendRequest(1), .startTimer(reply)])
    }

    @Test func approvalSeenOnRefreshConnects() {
        var setup = setup(at: .awaitingApproval)
        #expect(setup.handle(.refreshed(.enabled)) == [.openSession(1), .sendRequest(1), .startTimer(reply)])
    }

    // MARK: Sessions

    @Test func replyConnectsAndStopsTheTimer() {
        var setup = setup(at: .connecting)
        #expect(setup.handle(.replied(session: 1, down)) == [.cancelTimer])
        #expect(setup.phase == .connected(session: 1, observation: down, unanswered: 0))
        #expect(setup.state == .connected(down))
    }

    @Test func pushBeforeTheReplyCountsAsAnswered() {
        var setup = setup(at: .connecting)
        #expect(setup.handle(.pushed(session: 1, down)) == [])
        #expect(setup.phase == .connected(session: 1, observation: down, unanswered: 1))
    }

    @Test func requestsWhileConnectedAreTimed() {
        var setup = setup(at: .connected)
        #expect(setup.handle(.decisionChanged) == [.sendRequest(1), .startTimer(reply)])
        #expect(setup.handle(.decisionChanged) == [.sendRequest(1)])
        // Timed from the last reply while one is still out.
        #expect(setup.handle(.replied(session: 1, down)) == [.startTimer(reply)])
        #expect(setup.handle(.replied(session: 1, down)) == [.cancelTimer])
    }

    @Test func requestWhileConnectingIsSentOnTheSameSession() {
        var setup = setup(at: .connecting)
        #expect(setup.handle(.decisionChanged) == [.sendRequest(1)])
        #expect(setup.phase == .connecting(session: 1, failures: 0, unanswered: 2))
    }

    @Test func helperThatNeverAnswersIsReregistered() {
        var setup = setup(at: .connecting)
        #expect(setup.handle(.timerFired(.enabled)) == [.closeSession, .startTimer(.seconds(1))])
        #expect(setup.phase == .waitingToRetry(failures: 1, retry: .reregister))
        #expect(setup.handle(.timerFired(.enabled)) == [.startTimer(HelperSetup.unregisterTimeout), .unregister])
        #expect(setup.handle(.unregisterFinished) == [.startTimer(HelperSetup.settleDelay)])
        #expect(setup.handle(.timerFired(.notRegistered)) == [.register])
        #expect(setup.phase == .registering(failures: 1))
    }

    @Test func sessionEndingBeforeAnAnswerIsAFailure() {
        var setup = setup(at: .connecting)
        #expect(setup.handle(.sessionEnded(session: 1)) == [.closeSession, .startTimer(.seconds(1))])
        #expect(setup.phase == .waitingToRetry(failures: 1, retry: .reregister))
    }

    @Test func helperThatWorkedIsReconnectedNotReregistered() {
        var setup = setup(at: .connected)
        #expect(setup.handle(.sessionEnded(session: 1)) == [.closeSession, .cancelTimer, .refresh])
        #expect(setup.phase == .idle)
        #expect(setup.handle(.refreshed(.enabled)) == [.openSession(2), .sendRequest(2), .startTimer(reply)])
        #expect(setup.phase == .connecting(session: 2, failures: 0, unanswered: 1))
    }

    @Test func hungHelperIsReconnected() {
        var setup = setup(at: .connected)
        _ = setup.handle(.decisionChanged)
        #expect(setup.handle(.timerFired(.enabled)) == [.closeSession, .cancelTimer, .refresh])
    }

    @Test func approvalTurnedOffWhileConnected() {
        var setup = setup(at: .connected)
        #expect(setup.handle(.refreshed(.requiresApproval)) == [.closeSession, .startTimer(poll)])
        #expect(setup.state == .needsApproval)
        #expect(setup.handle(.refreshed(.enabled)) == [.openSession(2), .sendRequest(2), .startTimer(reply)])
    }

    @Test func refreshWhileConnectedChangesNothing() {
        var setup = setup(at: .connected)
        #expect(setup.handle(.refreshed(.enabled)) == [])
    }

    @Test func eventsFromAnEarlierSessionAreIgnored() {
        var setup = setup(at: .connected)
        _ = setup.handle(.sessionEnded(session: 1))
        _ = setup.handle(.refreshed(.enabled))
        let before = setup.phase
        #expect(setup.handle(.replied(session: 1, down)) == [])
        #expect(setup.handle(.pushed(session: 1, down)) == [])
        #expect(setup.handle(.sessionEnded(session: 1)) == [])
        #expect(setup.phase == before)
    }

    @Test func closedSessionReportingItsEndIsIgnored() {
        // closeSession cancels the session, and its cancellation arrives afterwards.
        var setup = setup(at: .connecting)
        _ = setup.handle(.timerFired(.enabled))
        let before = setup.phase
        #expect(setup.handle(.sessionEnded(session: 1)) == [])
        #expect(setup.phase == before)
    }

    // MARK: Repair

    @Test func repairReplacesTheRegistration() {
        var setup = setup(at: .failed)
        #expect(setup.handle(.repairRequested) == [.closeSession, .startTimer(HelperSetup.unregisterTimeout), .unregister])
        #expect(setup.phase == .unregistering(failures: 0))
        #expect(setup.state == .connecting)
    }

    @Test func repairRaceIsAbsorbed() {
        // 7 November: registering straight after unregistering was refused.
        var setup = setup(at: .connected)
        _ = setup.handle(.repairRequested)
        _ = setup.handle(.unregisterFinished)
        _ = setup.handle(.timerFired(.notRegistered))
        #expect(setup.handle(.registerFinished(.notRegistered)) == [.startTimer(.seconds(1))])
        #expect(setup.handle(.timerFired(.notRegistered)) == [.cancelTimer, .register])
        #expect(setup.handle(.registerFinished(.enabled)) == [.openSession(2), .sendRequest(2), .startTimer(reply)])
        #expect(setup.handle(.replied(session: 2, down)) == [.cancelTimer])
        #expect(setup.state == .connected(down))
    }

    @Test func repairDuringAnOperationIsIgnored() {
        var registering = setup(at: .registering)
        #expect(registering.handle(.repairRequested) == [])
        #expect(registering.phase == .registering(failures: 0))

        var unregistering = setup(at: .failed)
        _ = unregistering.handle(.repairRequested)
        #expect(unregistering.handle(.repairRequested) == [])
        _ = unregistering.handle(.unregisterFinished)
        #expect(unregistering.handle(.repairRequested) == [])
        #expect(unregistering.phase == .settling(failures: 0))
    }

    @Test func repairWhileWaitingToRetryStartsOver() {
        var setup = setup(at: .waitingToReregister)
        #expect(setup.handle(.repairRequested) == [.closeSession, .startTimer(HelperSetup.unregisterTimeout), .unregister])
        #expect(setup.phase == .unregistering(failures: 0))
    }

    @Test func neverStartingHelperEndsInFailedThenRepairs() {
        var setup = HelperSetup()
        _ = setup.handle(.refreshed(.enabled))
        var session = 1
        for failure in 1..<HelperSetup.maxFailures {
            _ = setup.handle(.sessionEnded(session: session))
            #expect(setup.phase == .waitingToRetry(failures: failure, retry: .reregister))
            _ = setup.handle(.timerFired(.enabled))
            _ = setup.handle(.unregisterFinished)
            _ = setup.handle(.timerFired(.notRegistered))
            _ = setup.handle(.registerFinished(.enabled))
            session += 1
        }
        #expect(setup.handle(.sessionEnded(session: session)) == [.closeSession, .cancelTimer])
        #expect(setup.state == .failed)

        _ = setup.handle(.repairRequested)
        _ = setup.handle(.unregisterFinished)
        _ = setup.handle(.timerFired(.notRegistered))
        _ = setup.handle(.registerFinished(.enabled))
        _ = setup.handle(.replied(session: session + 1, up))
        #expect(setup.state == .connected(up))
    }

    // MARK: Ignored pairs

    @Test func refreshDuringAnOperationOrABackoffIsIgnored() {
        var registering = setup(at: .registering)
        #expect(registering.handle(.refreshed(.enabled)) == [])
        var waiting = setup(at: .waitingToReregister)
        #expect(waiting.handle(.refreshed(.enabled)) == [])
        #expect(waiting.phase == .waitingToRetry(failures: 1, retry: .reregister))
    }

    @Test func openingTheMenuWhenFailedTriesOnceMore() {
        var setup = setup(at: .failed)
        #expect(setup.handle(.refreshed(.enabled)) == [.openSession(1), .sendRequest(1), .startTimer(reply)])
        #expect(setup.phase == .connecting(session: 1, failures: HelperSetup.maxFailures - 1, unanswered: 1))
        // One more failure is the last.
        #expect(setup.handle(.timerFired(.enabled)) == [.closeSession, .cancelTimer])
        #expect(setup.state == .failed)
        // An answer clears it.
        _ = setup.handle(.refreshed(.enabled))
        _ = setup.handle(.replied(session: 2, up))
        #expect(setup.state == .connected(up))
    }

    @Test func failedThenApprovalTurnedOffWaitsForApproval() {
        var setup = setup(at: .failed)
        #expect(setup.handle(.refreshed(.requiresApproval)) == [.startTimer(poll)])
        #expect(setup.state == .needsApproval)
    }

    @Test func failuresCarryThroughApproval() {
        // A re-register that macOS sends back for approval doesn't reset the count, and
        // doesn't open Settings again.
        var setup = setup(at: .waitingToReregister)
        _ = setup.handle(.timerFired(.enabled))
        _ = setup.handle(.unregisterFinished)
        _ = setup.handle(.timerFired(.notRegistered))
        #expect(setup.handle(.registerFinished(.requiresApproval)) == [.startTimer(poll)])
        #expect(setup.phase == .awaitingApproval(failures: 1))
        _ = setup.handle(.timerFired(.enabled))
        #expect(setup.phase == .connecting(session: 2, failures: 1, unanswered: 1))
    }

    @Test func unregisterThatNeverFinishesTimesOut() {
        var setup = setup(at: .failed)
        _ = setup.handle(.repairRequested)
        #expect(setup.handle(.timerFired(.enabled)) == [.startTimer(HelperSetup.settleDelay)])
        #expect(setup.phase == .settling(failures: 0))
        // Its late result is ignored.
        #expect(setup.handle(.unregisterFinished) == [])
        #expect(setup.handle(.timerFired(.notRegistered)) == [.register])
    }

    @Test func decisionChangeWithoutASessionSendsNothing() {
        var setup = setup(at: .awaitingApproval)
        #expect(setup.handle(.decisionChanged) == [])
    }

    // MARK: Values

    @Test func retryDelayDoubles() {
        let delays = (1..<HelperSetup.maxFailures).map(HelperSetup.retryDelay(afterFailures:))
        #expect(delays == [.seconds(1), .seconds(2), .seconds(4)])
    }

    @Test func stateForEveryPhase() {
        let cases: [(HelperPhase, HelperState)] = [
            (.idle, .connecting),
            (.registering(failures: 0), .connecting),
            (.unregistering(failures: 0), .connecting),
            (.settling(failures: 0), .connecting),
            (.connecting(session: 1, failures: 0, unanswered: 1), .connecting),
            (.waitingToRetry(failures: 1, retry: .register), .connecting),
            (.awaitingApproval(failures: 0), .needsApproval),
            (.connected(session: 1, observation: down, unanswered: 0), .connected(down)),
            (.failed, .failed),
        ]
        for (phase, state) in cases {
            #expect(phase.state == state, "\(phase)")
        }
    }
}
