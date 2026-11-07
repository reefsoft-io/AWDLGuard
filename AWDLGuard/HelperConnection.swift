import Foundation
import GuardPolicy
import HelperInterface
import Observation
import ServiceManagement
import XPC
import os

/// The app's side of the privileged helper: its registration with launchd and the XPC
/// session to it. `state` is the only record of what the helper last reported.
///
/// Driven by events, not a loop. XPC ends the session when the helper exits, crashes or is
/// stopped by launchd; the app then rereads the registration and opens a new session,
/// which launches the helper again, and sends what it wants. The helper reports changes to
/// awdl0 as they happen, so nothing is resent on a timer.
@MainActor @Observable
final class HelperConnection {
    private(set) var state: HelperState = .connecting

    /// Read whenever a request is sent, so the helper always gets the current decision.
    @ObservationIgnored var wantsSuppression: () -> Bool = { false }

    @ObservationIgnored private let identifier: String
    @ObservationIgnored private let service: SMAppService
    @ObservationIgnored private var session: XPCSession?
    /// Numbers sessions, so replies, pushes and cancellations from an ended session are
    /// ignored. Disconnecting also advances it.
    @ObservationIgnored private var sessionNumber = 0
    /// Whether the current session has answered at least once.
    @ObservationIgnored private var hasReplied = false
    /// Requests sent on the current session that haven't been answered.
    @ObservationIgnored private var unansweredCount = 0
    @ObservationIgnored private var replyTimer: Task<Void, Never>?
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var retryDelay = firstRetryDelay
    @ObservationIgnored private var approvalWatch: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "io.reefsoft.AWDLGuard", category: "helper")

    /// A request unanswered for this long, not counting sleep, means the helper isn't
    /// responding.
    private static let replyTimeout: Duration = .seconds(10)
    /// A session that ended before ever answering is retried after this delay, doubling up
    /// to `maxRetryDelay`.
    private static let firstRetryDelay: Duration = .seconds(1)
    private static let maxRetryDelay: Duration = .seconds(30)
    /// How often registration is reread while the helper waits for approval: SMAppService
    /// has no notification for approval in System Settings.
    private static let approvalPoll: Duration = .seconds(2)

    init(appIdentifier: String) {
        identifier = HelperIdentity.helperIdentifier(appIdentifier: appIdentifier)
        service = SMAppService.daemon(plistName: identifier + ".plist")
    }

    /// Rereads the registration, and connects if the helper is enabled and not connected.
    /// Called at launch, when the menu opens, after install and repair, when a session that
    /// worked ends, on each retry, and every 2 seconds while waiting for approval.
    func refresh() {
        guard state != .repairing else { return }
        switch service.status {
        case .enabled:
            stopWatchingApproval()
            if session == nil { connect() }
        case .requiresApproval:
            disconnect()
            state = .needsApproval
            watchApproval()
        default:
            disconnect()
            stopWatchingApproval()
            // Keep the reason a failed install gave until the next attempt.
            if case .installFailed = state { return }
            state = .notInstalled
        }
    }

    /// Sends the current decision on the open session. Without one there's nothing to do:
    /// the next session sends the decision as it opens.
    func send() {
        guard let session else { return }
        let number = sessionNumber
        let request = SuppressionRequest(isSuppressed: wantsSuppression())
        do {
            try session.send(request) { [weak self] (result: Result<InterfaceObservation, any Error>) in
                Task { @MainActor in self?.receiveReply(result, from: number) }
            }
            unansweredCount += 1
            startReplyTimer()
        } catch {
            log.error("Couldn't send request: \(error, privacy: .public)")
            sessionEnded(number)
        }
    }

    /// Registers the helper with launchd; macOS then asks the user to approve it.
    func install() {
        do {
            try service.register()
        } catch {
            log.error("Helper registration failed: \(error, privacy: .public)")
            // An error can still leave the helper registered, enabled or waiting for
            // approval; only a helper that isn't registered at all is a failed install.
            if service.status == .notRegistered || service.status == .notFound {
                disconnect()
                state = .installFailed(error.localizedDescription)
                return
            }
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        refresh()
    }

    func openApproval() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Unregisters and re-registers the helper, for a helper that stopped responding.
    /// launchd stops the old helper, which restores awdl0 as it goes.
    func repair() async {
        guard state != .repairing else { return }
        disconnect()
        stopWatchingApproval()
        state = .repairing
        do {
            try await service.unregister()
        } catch {
            log.error("Helper unregistration failed: \(error, privacy: .public)")
        }
        state = .connecting
        install()
    }

    // MARK: Session

    private func connect() {
        disconnect()
        let number = sessionNumber
        hasReplied = false
        // A retry after a session that never answered stays "not responding" until a reply.
        if state != .notResponding { state = .connecting }
        do {
            // Only our own helper, signed by the same team as this app, is trusted.
            session = try XPCSession(
                machService: identifier,
                requirement: .isFromSameTeam(andMatchesSigningIdentifier: identifier),
                incomingMessageHandler: { [weak self] (observation: InterfaceObservation) -> (any Encodable)? in
                    Task { @MainActor in self?.receive(observation, from: number) }
                    return nil
                },
                cancellationHandler: { [weak self] error in
                    Task { @MainActor in
                        self?.log.notice("Helper session ended: \(error, privacy: .public)")
                        self?.sessionEnded(number)
                    }
                })
        } catch {
            log.error("Couldn't connect to helper: \(error, privacy: .public)")
            sessionEnded(number)
            return
        }
        send()
    }

    /// Closes the session without retrying, and drops anything still on its way from it.
    private func disconnect() {
        session?.cancel(reason: "Helper unavailable")
        session = nil
        sessionNumber += 1
        unansweredCount = 0
        stopReplyTimer()
        retry?.cancel()
        retry = nil
    }

    private func sessionEnded(_ number: Int) {
        guard number == sessionNumber else { return }
        let didReply = hasReplied
        disconnect()
        if didReply {
            // The helper was working and went away: it crashed, exited or was stopped.
            // Reconnecting launches it again, unless it was unregistered or turned off.
            state = .connecting
            refresh()
        } else {
            state = .notResponding
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, Self.maxRetryDelay)
        retry = Task { [weak self] in
            try? await Task.sleep(for: delay, clock: .suspending)
            guard !Task.isCancelled, let self else { return }
            retry = nil
            refresh()
        }
    }

    private func receiveReply(_ result: Result<InterfaceObservation, any Error>, from number: Int) {
        guard number == sessionNumber else { return }
        unansweredCount -= 1
        stopReplyTimer()
        if unansweredCount > 0 { startReplyTimer() }
        switch result {
        case .success(let observation):
            receive(observation, from: number)
        case .failure(let error):
            // Usually the session is ending anyway. If it isn't, for example a reply that
            // can't be decoded, end it so recovery runs.
            log.error("Helper request failed: \(error, privacy: .public)")
            sessionEnded(number)
        }
    }

    private func receive(_ observation: InterfaceObservation, from number: Int) {
        guard number == sessionNumber else { return }
        hasReplied = true
        retryDelay = Self.firstRetryDelay
        state = .connected(observation)
    }

    // MARK: Timers

    /// While requests are unanswered, times the wait since the last reply, or since the
    /// first of them was sent. The suspending clock stops while the Mac sleeps, so waking up
    /// never counts as a slow reply.
    private func startReplyTimer() {
        guard replyTimer == nil else { return }
        let number = sessionNumber
        replyTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.replyTimeout, clock: .suspending)
            guard !Task.isCancelled, let self, number == sessionNumber else { return }
            replyTimer = nil
            log.error("Helper hasn't answered for \(Self.replyTimeout, privacy: .public)")
            state = .notResponding
        }
    }

    private func stopReplyTimer() {
        replyTimer?.cancel()
        replyTimer = nil
    }

    private func watchApproval() {
        guard approvalWatch == nil else { return }
        approvalWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.approvalPoll)
                guard !Task.isCancelled, let self else { return }
                refresh()
            }
        }
    }

    private func stopWatchingApproval() {
        approvalWatch?.cancel()
        approvalWatch = nil
    }
}
