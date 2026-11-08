import Darwin
import Dispatch
import Foundation
import HelperInterface
import os

/// Owns awdl0: reads and sets its `IFF_UP` flag, and watches the routing socket so it can
/// bring the interface straight back down when macOS reactivates it during suppression.
///
/// This is reactive: macOS can still bring awdl0 up for the moment before the helper sees
/// the routing message and takes it down again. Each of those is counted as a reactivation.
///
/// A marker file is the one record that the helper owes awdl0 a bring-up. It is written
/// before awdl0 is taken down and removed only once awdl0 is back up, so a failed bring-up
/// is retried on the next release, at exit, and by the next helper to start. That way the
/// helper only ever undoes its own change. The one exception is that a helper starting
/// with the marker brings awdl0 up even if macOS has since taken it down itself. The marker
/// lives in /var/run, which is cleared at boot, when awdl0 starts up anyway.
///
/// Confined to the helper's queue: every method after `init` must be called on it.
final class AWDLInterface: @unchecked Sendable {
    static let name = "awdl0"

    private let queue: DispatchQueue
    private let markerPath: String
    private let controlSocket: Int32
    private let routeSocket: Int32
    private var routeSource: DispatchSourceRead?
    private var onChange: (InterfaceObservation) -> Void = { _ in }
    private var observation = InterfaceObservation(isSuppressing: false, isInterfaceUp: nil)
    private let log = Logger(category: "interface")

    /// Opens the sockets. Nothing happens to awdl0 until `start`.
    init(queue: DispatchQueue, markerPath: String) throws(InterfaceFailure) {
        self.queue = queue
        self.markerPath = markerPath
        controlSocket = socket(AF_INET, SOCK_DGRAM, 0)
        guard controlSocket >= 0 else { throw InterfaceFailure(operation: .readFlags, code: errno) }
        routeSocket = socket(PF_ROUTE, SOCK_RAW, 0)
        guard routeSocket >= 0, fcntl(routeSocket, F_SETFL, O_NONBLOCK) == 0 else {
            throw InterfaceFailure(operation: .watchChanges, code: errno)
        }
    }

    /// Brings awdl0 up if the marker shows a previous helper still owed it that, then starts
    /// watching. `onChange` runs on the queue whenever macOS changes awdl0 and the
    /// observation changes with it.
    func start(onChange: @escaping (InterfaceObservation) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        self.onChange = onChange
        if hasMarker {
            log.notice("A previous helper was holding awdl0 down; bringing it up")
            release()
        } else {
            refresh()
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: routeSocket, queue: queue)
        source.setEventHandler { [unowned self] in readRouteMessages() }
        source.activate()
        routeSource = source
    }

    /// Holds awdl0 down or releases it, and returns what the helper then observed.
    ///
    /// Suppression starts only once the marker is written, so awdl0 is never down without a
    /// record. Releasing brings awdl0 up only while the marker says the helper owes it that;
    /// repeating a release never forces up an interface that macOS itself took down.
    func setSuppressed(_ isSuppressed: Bool) -> InterfaceObservation {
        dispatchPrecondition(condition: .onQueue(queue))
        // Each request is a new attempt at recording suppression.
        if observation.failure?.operation == .recordState { observation.failure = nil }
        if isSuppressed {
            if observation.isSuppressing || writeMarker() {
                if !observation.isSuppressing { observation.reactivationCount = 0 }
                observation.isSuppressing = true
                holdDown(countingReactivation: false)
            }
        } else if hasMarker {
            release()
        } else {
            refresh()
        }
        return observation
    }

    /// Stops watching and restores awdl0 if the helper owes it that. Called before the
    /// helper exits.
    func restore() {
        dispatchPrecondition(condition: .onQueue(queue))
        routeSource?.cancel()
        routeSource = nil
        if hasMarker { release() }
    }

    // MARK: Marker (on queue)

    private var hasMarker: Bool {
        access(markerPath, F_OK) == 0
    }

    /// Creates the marker. On failure, records it and leaves awdl0 alone.
    private func writeMarker() -> Bool {
        let descriptor = open(markerPath, O_WRONLY | O_CREAT, 0o644)
        guard descriptor >= 0 else {
            let failure = InterfaceFailure(operation: .recordState, code: errno)
            observation.failure = failure
            log.error("\(failure.description, privacy: .public): \(self.markerPath, privacy: .public)")
            refresh()
            return false
        }
        close(descriptor)
        return true
    }

    /// Brings awdl0 up and, once that worked, removes the marker. A marker left after a
    /// failure means the next release, exit or helper tries again.
    private func release() {
        bringUp()
        if observation.failure == nil { unlink(markerPath) }
    }

    // MARK: Interface operations (on queue)

    private func holdDown(countingReactivation: Bool) {
        perform { () throws(InterfaceFailure) -> Int32 in
            let flags = try readFlags()
            guard flags & IFF_UP != 0 else { return flags }
            if countingReactivation {
                observation.reactivationCount += 1
                log.info("macOS brought awdl0 up during suppression; bringing it down")
            }
            try writeFlags(flags & ~IFF_UP, operation: .bringDown)
            return try readFlags()
        }
    }

    private func bringUp() {
        observation.isSuppressing = false
        perform { () throws(InterfaceFailure) -> Int32 in
            let flags = try readFlags()
            guard flags & IFF_UP == 0 else { return flags }
            try writeFlags(flags | IFF_UP, operation: .bringUp)
            return try readFlags()
        }
    }

    private func refresh() {
        perform { () throws(InterfaceFailure) -> Int32 in try readFlags() }
    }

    /// Runs one pass on awdl0 and records the flags it ends with, or the failure. A clean
    /// pass clears an earlier interface failure; a failure to record suppression stays until
    /// the next request, since no pass retries it.
    private func perform(_ body: () throws(InterfaceFailure) -> Int32) {
        do {
            let flags = try body()
            observation.isInterfaceUp = flags & IFF_UP != 0
            if observation.failure?.operation != .recordState { observation.failure = nil }
        } catch {
            log.error("\(error.description, privacy: .public)")
            observation.failure = error
            observation.isInterfaceUp = (try? readFlags()).map { $0 & IFF_UP != 0 }
        }
    }

    private func readFlags() throws(InterfaceFailure) -> Int32 {
        var request = ifreq(interfaceName: Self.name)
        guard ioctl(controlSocket, SIOCGIFFLAGS, &request) == 0 else {
            throw InterfaceFailure(operation: .readFlags, code: errno)
        }
        return Int32(UInt16(bitPattern: request.ifr_ifru.ifru_flags))
    }

    private func writeFlags(_ flags: Int32, operation: InterfaceFailure.Operation) throws(InterfaceFailure) {
        var request = ifreq(interfaceName: Self.name)
        request.ifr_ifru.ifru_flags = Int16(truncatingIfNeeded: flags)
        guard ioctl(controlSocket, SIOCSIFFLAGS, &request) == 0 else {
            throw InterfaceFailure(operation: operation, code: errno)
        }
    }

    // MARK: Routing socket (on queue)

    /// Drains the routing socket. Any interface message for awdl0 triggers one pass, which
    /// rereads the flags rather than trusting the flags in the message.
    private func readRouteMessages() {
        let before = observation
        var buffer = [UInt8](repeating: 0, count: 2048)
        var concernsAWDL = false
        while true {
            let length = buffer.withUnsafeMutableBytes { read(routeSocket, $0.baseAddress, $0.count) }
            if length < 0 {
                let code = errno
                if code == EINTR { continue }
                if code == EAGAIN { break }
                if code == ENOBUFS {
                    // Messages were dropped in a burst; one of them may have been for awdl0.
                    concernsAWDL = true
                    continue
                }
                // A routing socket that keeps failing would spin, so stop watching and
                // report it. Repair restarts the helper, which opens a new socket.
                observation.isWatching = false
                log.error("Routing socket failed: errno \(code)")
                routeSource?.cancel()
                routeSource = nil
                break
            }
            guard length >= MemoryLayout<if_msghdr>.size else { continue }
            let message = buffer.withUnsafeBytes { $0.loadUnaligned(as: if_msghdr.self) }
            guard Int32(message.ifm_type) == RTM_IFINFO else { continue }
            if message.ifm_index == UInt16(truncatingIfNeeded: if_nametoindex(Self.name)) {
                concernsAWDL = true
            }
        }

        if concernsAWDL {
            if observation.isSuppressing {
                holdDown(countingReactivation: true)
            } else {
                refresh()
            }
        }
        if observation != before { onChange(observation) }
    }
}

// MARK: - System definitions Swift can't import

// <sys/sockio.h> builds these request codes with the function-like _IOW and _IOWR macros,
// which Swift doesn't import. They encode the direction, the size of `ifreq`, the group
// letter and the command number.
private func socketRequest(direction: UInt, command: UInt) -> UInt {
    let parameterMask: UInt = 0x1fff
    return direction | ((UInt(MemoryLayout<ifreq>.size) & parameterMask) << 16)
        | (UInt(UInt8(ascii: "i")) << 8) | command
}

private let SIOCSIFFLAGS = socketRequest(direction: 0x8000_0000, command: 16)  // _IOW('i', 16, struct ifreq)
private let SIOCGIFFLAGS = socketRequest(direction: 0xC000_0000, command: 17)  // _IOWR('i', 17, struct ifreq)

extension ifreq {
    fileprivate init(interfaceName: String) {
        self.init()
        withUnsafeMutableBytes(of: &ifr_name) { name in
            name.copyBytes(from: interfaceName.utf8.prefix(name.count - 1))
        }
    }
}
