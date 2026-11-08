import Foundation
import HelperInterface
import XPC
import os

/// The privileged helper. It holds awdl0 down while any connected app session asks for
/// that, and reports what it observes. Each session's request lasts until the session
/// ends; when the last one ends, or launchd stops the helper, it restores awdl0 and exits,
/// so it never runs unseen.
///
/// Everything runs on one serial queue: the listener, every session's events, the routing
/// socket and the termination signal. XPC handlers hop onto it.
final class Helper: @unchecked Sendable {
    private let queue: DispatchQueue
    private let interface: AWDLInterface
    private var sessions: [Int: XPCSession] = [:]
    private var requests = SessionRequests()
    private var lastSessionNumber = 0
    private let log = Logger(subsystem: "io.reefsoft.AWDLGuard.Helper", category: "helper")

    /// How long a helper that launchd started may wait for its first session.
    private static let firstSessionTimeout: DispatchTimeInterval = .seconds(10)

    init(queue: DispatchQueue, interface: AWDLInterface) {
        self.queue = queue
        self.interface = interface
        queue.sync {
            interface.start { [unowned self] observation in push(observation) }
        }
        queue.asyncAfter(deadline: .now() + Self.firstSessionTimeout) { [unowned self] in
            if lastSessionNumber == 0 { shutDown("No app connected") }
        }
    }

    /// Accepts an app session. Runs on the queue, as the listener's handler.
    func accept(_ request: XPCListener.IncomingSessionRequest) -> XPCListener.IncomingSessionRequest.Decision {
        dispatchPrecondition(condition: .onQueue(queue))
        lastSessionNumber += 1
        let number = lastSessionNumber
        let (decision, session) = request.accept(
            incomingMessageHandler: { [unowned self] (received: XPCReceivedMessage) -> (any Encodable)? in
                // Handled on the helper's queue, which this handler isn't guaranteed to run
                // on. handoffReply answers from that queue, for sync and async messages
                // alike; XPCReceivedMessage just isn't marked Sendable.
                nonisolated(unsafe) let message = received
                return message.handoffReply(to: queue) { [unowned self] in
                    receive(message, from: number)
                }
            },
            cancellationHandler: { [unowned self] error in
                queue.async { [unowned self] in
                    log.info("App session \(number) ended: \(error, privacy: .public)")
                    end(number)
                }
            })
        sessions[number] = session
        return decision
    }

    /// Restores awdl0 and exits.
    func shutDown(_ reason: String) -> Never {
        dispatchPrecondition(condition: .onQueue(queue))
        log.info("Exiting: \(reason, privacy: .public)")
        interface.restore()
        exit(EXIT_SUCCESS)
    }

    private func receive(_ message: XPCReceivedMessage, from number: Int) {
        do {
            let request = try message.decode(as: SuppressionRequest.self)
            requests.set(request.isSuppressed, for: number)
            let observation = interface.setSuppressed(requests.isSuppressionWanted)
            message.reply(report(observation, for: number))
            push(observation, excluding: number)
        } catch {
            // Not from a matching app version. Ending the session lets the app recover the
            // usual way instead of waiting for a reply.
            log.error("Unreadable request from session \(number): \(error, privacy: .public)")
            sessions[number]?.cancel(reason: "Unreadable request")
        }
    }

    private func end(_ number: Int) {
        sessions[number] = nil
        requests.remove(number)
        if sessions.isEmpty { shutDown("Last app session ended") }
        push(interface.setSuppressed(requests.isSuppressionWanted))
    }

    /// Sends `observation` to every session, or to every session but the one that just got
    /// it as a reply.
    private func push(_ observation: InterfaceObservation, excluding excluded: Int? = nil) {
        for (number, session) in sessions where number != excluded {
            do {
                try session.send(report(observation, for: number))
            } catch {
                log.error("Couldn't push to session \(number): \(error, privacy: .public)")
            }
        }
    }

    /// The observation as session `number` sees it.
    private func report(_ observation: InterfaceObservation, for number: Int) -> InterfaceObservation {
        var report = observation
        report.isHeldForOthers = observation.isSuppressing && requests.isHeldForOthers(excluding: number)
        return report
    }
}

func runHelper() -> Never {
    let log = Logger(subsystem: "io.reefsoft.AWDLGuard.Helper", category: "helper")

    guard let helperIdentifier = Bundle.main.bundleIdentifier,
        let appIdentifier = HelperIdentity.appIdentifier(helperIdentifier: helperIdentifier)
    else {
        log.fault("Helper has no usable bundle identifier")
        exit(EXIT_FAILURE)
    }

    let queue = DispatchQueue(label: helperIdentifier)
    let helper: Helper
    do {
        let interface = try AWDLInterface(queue: queue, markerPath: "/var/run/\(helperIdentifier).suppressing")
        helper = Helper(queue: queue, interface: interface)
    } catch {
        log.fault("\(error.description, privacy: .public)")
        exit(EXIT_FAILURE)
    }

    // launchd sends SIGTERM when the helper is unregistered, turned off under Background App
    // Activity in System Settings, or at shutdown; restore awdl0 before going.
    signal(SIGTERM, SIG_IGN)
    let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
    termination.setEventHandler { helper.shutDown("Stopped by launchd") }
    termination.activate()

    let listener: XPCListener
    do {
        // Only the AWDL Guard app, signed by the same team as this helper, may connect.
        listener = try XPCListener(
            service: helperIdentifier,
            targetQueue: queue,
            requirement: .isFromSameTeam(andMatchesSigningIdentifier: appIdentifier)
        ) { request in
            helper.accept(request)
        }
    } catch {
        log.fault("Couldn't start listener: \(error, privacy: .public)")
        queue.sync { () -> Never in helper.shutDown("No listener") }
    }

    log.info("Helper started")
    withExtendedLifetime((listener, termination)) { dispatchMain() }
}

runHelper()
