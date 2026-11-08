import Foundation
import GuardPolicy
import HelperInterface
import Observation
import ServiceManagement
import XPC
import os

/// The app's side of the privileged helper: performs what its setup (`HelperSetup`)
/// decides, and feeds back what happened. `HelperSetup` owns every decision; this class
/// only talks to `SMAppService`, the XPC session and the clock.
///
/// XPC ends the session when the helper exits, crashes or is stopped by launchd. The helper
/// reports changes to awdl0 as they happen, so nothing is resent on a timer.
@MainActor @Observable
final class HelperConnection {
    /// The setup's state, copied only when it changes, so the menu redraws on a new state
    /// and not on every request counted in the phase.
    private(set) var state: HelperState = .connecting

    /// Read whenever a request is sent, so the helper always gets the current decision.
    @ObservationIgnored var wantsSuppression: () -> Bool = { false }

    @ObservationIgnored private var setup = HelperSetup()
    /// Events that arrive while effects are being performed wait here, so each event sees
    /// the phase its predecessor left.
    @ObservationIgnored private var pendingEvents: [HelperEvent] = []
    @ObservationIgnored private var isHandling = false

    @ObservationIgnored private let identifier: String
    @ObservationIgnored private let service: SMAppService
    @ObservationIgnored private var session: XPCSession?
    @ObservationIgnored private var timer: Task<Void, Never>?
    /// Advanced by each new timer, so a timer that was replaced can't fire.
    @ObservationIgnored private var timerNumber = 0
    /// The registration last written to the log; only for logging.
    @ObservationIgnored private var loggedRegistration: Registration?
    @ObservationIgnored private let log = Logger(subsystem: "io.reefsoft.AWDLGuard", category: "helper")

    init(appIdentifier: String) {
        identifier = HelperIdentity.helperIdentifier(appIdentifier: appIdentifier)
        service = SMAppService.daemon(plistName: identifier + ".plist")
    }

    /// Rereads the registration; called at launch and when the menu opens.
    func refresh() {
        handle(.refreshed(readRegistration()))
    }

    /// Sends the current decision, once a session is open.
    func send() {
        handle(.decisionChanged)
    }

    /// Replaces the helper's registration and connects again.
    func repair() {
        handle(.repairRequested)
    }

    func openApproval() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: Events and effects

    private func handle(_ event: HelperEvent) {
        pendingEvents.append(event)
        guard !isHandling else { return }
        isHandling = true
        defer { isHandling = false }
        while !pendingEvents.isEmpty {
            let event = pendingEvents.removeFirst()
            let before = setup.phase
            let effects = setup.handle(event)
            let name = Self.name(setup.phase)
            if name != Self.name(before) { log.notice("Helper setup: \(name, privacy: .public)") }
            if setup.phase.state != state { state = setup.phase.state }
            for effect in effects { perform(effect) }
        }
    }

    private func perform(_ effect: HelperEffect) {
        switch effect {
        case .register:
            do {
                try service.register()
            } catch {
                // It can report an error and still succeed; the registration decides.
                log.error("Helper registration reported: \(error, privacy: .public)")
            }
            handle(.registerFinished(readRegistration()))
        case .unregister:
            Task {
                do {
                    try await service.unregister()
                } catch {
                    log.error("Helper unregistration reported: \(error, privacy: .public)")
                }
                handle(.unregisterFinished)
            }
        case .openSession(let number):
            openSession(number)
        case .closeSession:
            session?.cancel(reason: "Helper session replaced")
            session = nil
        case .sendRequest(let number):
            sendRequest(on: number)
        case .startTimer(let duration):
            startTimer(duration)
        case .cancelTimer:
            timer?.cancel()
            timer = nil
        case .openSettings:
            SMAppService.openSystemSettingsLoginItems()
        case .refresh:
            handle(.refreshed(readRegistration()))
        }
    }

    private func readRegistration() -> Registration {
        let status = service.status
        let registration: Registration =
            switch status {
            case .enabled: .enabled
            case .requiresApproval: .requiresApproval
            case .notRegistered, .notFound: .notRegistered
            @unknown default: .notRegistered
            }
        // Logged on change, so the logs show what macOS reported when the state seems wrong.
        if registration != loggedRegistration {
            log.notice("Helper registration: \(String(describing: registration), privacy: .public)")
            loggedRegistration = registration
        }
        return registration
    }

    // MARK: Session

    private func openSession(_ number: Int) {
        session?.cancel(reason: "Helper session replaced")
        do {
            // Only our own helper, signed by the same team as this app, is trusted.
            session = try XPCSession(
                machService: identifier,
                requirement: .isFromSameTeam(andMatchesSigningIdentifier: identifier),
                incomingMessageHandler: { [weak self] (observation: InterfaceObservation) -> (any Encodable)? in
                    Task { @MainActor in self?.handle(.pushed(session: number, observation)) }
                    return nil
                },
                cancellationHandler: { [weak self] error in
                    Task { @MainActor in
                        self?.log.notice("Helper session ended: \(error, privacy: .public)")
                        self?.handle(.sessionEnded(session: number))
                    }
                })
        } catch {
            log.error("Couldn't connect to helper: \(error, privacy: .public)")
            session = nil
            handle(.sessionEnded(session: number))
        }
    }

    private func sendRequest(on number: Int) {
        guard let session else {
            handle(.sessionEnded(session: number))
            return
        }
        let request = SuppressionRequest(isSuppressed: wantsSuppression())
        do {
            try session.send(request) { [weak self] (result: Result<InterfaceObservation, any Error>) in
                Task { @MainActor in
                    guard let self else { return }
                    switch result {
                    case .success(let observation):
                        self.handle(.replied(session: number, observation))
                    case .failure(let error):
                        // Usually the session is ending anyway. If it isn't, for example a
                        // reply that can't be decoded, ending it lets the setup recover.
                        self.log.error("Helper request failed: \(error, privacy: .public)")
                        self.handle(.sessionEnded(session: number))
                    }
                }
            }
        } catch {
            log.error("Couldn't send request: \(error, privacy: .public)")
            handle(.sessionEnded(session: number))
        }
    }

    // MARK: Timer

    /// The suspending clock stops while the Mac sleeps, so waking up never counts as a slow
    /// reply or a missed retry.
    private func startTimer(_ duration: Duration) {
        timer?.cancel()
        timerNumber += 1
        let number = timerNumber
        timer = Task { [weak self] in
            try? await Task.sleep(for: duration, clock: .suspending)
            guard !Task.isCancelled, let self, number == timerNumber else { return }
            timer = nil
            handle(.timerFired(readRegistration()))
        }
    }

    /// The phase's kind, for the log.
    private static func name(_ phase: HelperPhase) -> String {
        switch phase {
        case .idle: "idle"
        case .registering(let failures): "registering (failures: \(failures))"
        case .unregistering(let failures): "unregistering (failures: \(failures))"
        case .settling(let failures): "settling (failures: \(failures))"
        case .awaitingApproval: "awaiting approval"
        case .connecting(let session, let failures, _): "connecting session \(session) (failures: \(failures))"
        case .connected(let session, _, _): "connected session \(session)"
        case .waitingToRetry(let failures, let retry): "waiting to \(retry) (failures: \(failures))"
        case .failed: "failed"
        }
    }
}
