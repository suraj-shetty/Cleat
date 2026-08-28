import Foundation
import Security
import os

/// XPC entry point for the privileged helper.
///
/// Two things guard this surface: the connection has to satisfy a code-signing
/// requirement pinned to this app's identifier and signing team, and every request
/// is re-validated inside `MountEngine` rather than being trusted because it came
/// from a connection that passed the first check.
final class HelperService: NSObject, NSXPCListenerDelegate, CleatHelperProtocol {
    private let log = Logger(subsystem: "com.cleat.helper", category: "Service")
    private let listener: NSXPCListener
    private let engine = MountEngine()
    /// All privileged work is serialised: two mounts of the same device, or an
    /// unmount racing a mount, would be a genuinely dangerous interleaving.
    private let workQueue = DispatchQueue(label: "com.cleat.helper.work", qos: .userInitiated)
    private let idleTimer: DispatchSourceTimer
    private let connectionCount = Counter()

    override init() {
        listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
        idleTimer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.cleat.helper.idle"))
        super.init()
        listener.delegate = self
    }

    func run() {
        startIdleWatchdog()
        listener.resume()
        RunLoop.current.run()
    }

    // MARK: - NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // `setCodeSigningRequirement` raises rather than throwing when handed a
        // malformed requirement, so the string is compiled first and the connection
        // is refused outright if it will not parse.
        let requirement: String
        switch XPCRequirement.build(peerIdentifier: HelperConstants.clientBundleIdentifier, log: log) {
        case .requirement(let value):
            requirement = value
        case .teamMismatch(let found, let expected):
            log.fault("""
            Refusing every connection: this helper is signed by team \(found, privacy: .public) \
            but was built for team \(expected, privacy: .public). Re-sign it or fix \
            BuildConfiguration.expectedTeamIdentifier.
            """)
            return false
        }
        guard XPCRequirement.isWellFormed(requirement) else {
            log.error("Rejecting connection: the client requirement did not parse.")
            return false
        }
        connection.setCodeSigningRequirement(requirement)

        connection.exportedInterface = NSXPCInterface(with: CleatHelperProtocol.self)
        connection.exportedObject = self
        connectionCount.increment()
        connection.invalidationHandler = { [connectionCount] in connectionCount.decrement() }
        connection.interruptionHandler = { [connectionCount] in connectionCount.decrement() }
        connection.resume()
        log.notice("Accepted a client connection.")
        return true
    }

    // MARK: - CleatHelperProtocol

    func helperVersion(reply: @escaping @Sendable (String) -> Void) {
        reply(HelperConstants.version)
    }

    func perform(_ requestJSON: Data, reply: @escaping @Sendable (Data) -> Void) {
        let engine = engine
        let log = log
        workQueue.async {
            let response: HelperResponse
            do {
                let request = try JSONDecoder().decode(HelperRequest.self, from: requestJSON)
                switch request {
                case .mountReadWrite(let mountRequest):
                    response = engine.mountReadWrite(mountRequest)
                case .unmount(let unmountRequest):
                    response = engine.unmount(unmountRequest, thenEject: false)
                case .eject(let unmountRequest):
                    response = engine.unmount(unmountRequest, thenEject: true)
                case .activeMounts:
                    response = engine.activeMounts()
                }
            } catch {
                log.error("Malformed request: \(String(describing: error), privacy: .public)")
                response = .failure(HelperFailure(kind: .invalidRequest,
                                                  message: "The helper could not decode that request.",
                                                  detail: String(describing: error)))
            }
            let encoded = (try? JSONEncoder().encode(response))
                ?? Data("{\"failure\":{\"kind\":\"internalError\",\"message\":\"Response encoding failed.\"}}".utf8)
            reply(encoded)
        }
    }

    // MARK: - Idle exit

    /// launchd restarts the helper on demand, so there is no reason to sit resident.
    /// Detached ntfs-3g daemons are unaffected by the helper exiting.
    private func startIdleWatchdog() {
        idleTimer.schedule(deadline: .now() + 60, repeating: 60)
        idleTimer.setEventHandler { [connectionCount, log] in
            guard connectionCount.value == 0 else { return }
            log.notice("Idle with no clients; exiting.")
            exit(EXIT_SUCCESS)
        }
        idleTimer.resume()
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func increment() { lock.lock(); count += 1; lock.unlock() }
    func decrement() { lock.lock(); count = max(0, count - 1); lock.unlock() }
}
