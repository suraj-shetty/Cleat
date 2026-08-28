import Foundation
import ServiceManagement
import Security
import os

/// Installs, validates, and talks to the privileged helper.
///
/// Registration goes through `SMAppService`, which installs the launchd plist that
/// ships inside this app bundle. No system launchd directory is touched, no
/// `SMJobBless` blessing, and no authorisation right is created — the user simply
/// approves the item once in Login Items & Extensions.
actor HelperClient {
    enum ClientError: LocalizedError {
        case registrationFailed(String)
        case notRegistered
        case awaitingApproval
        case connectionFailed(String)
        case timedOut(TimeInterval)
        case decodingFailed
        case helper(HelperFailure)

        var errorDescription: String? {
            switch self {
            case .registrationFailed(let message):
                return "Could not install the privileged helper: \(message)"
            case .notRegistered:
                return "The privileged helper is not installed yet."
            case .awaitingApproval:
                return "The privileged helper is waiting for your approval in System Settings."
            case .connectionFailed(let message):
                return "Could not reach the privileged helper: \(message)"
            case .timedOut(let seconds):
                return """
                The privileged helper did not respond within \(Int(seconds)) seconds. \
                This usually means the running app and the installed helper are different \
                builds — reinstall the helper from Setup.
                """
            case .decodingFailed:
                return "The privileged helper sent a response this version does not understand."
            case .helper(let failure):
                return failure.message
            }
        }
    }

    private let log = Logger(subsystem: "com.cleat.app", category: "HelperClient")
    private var connection: NSXPCConnection?

    // MARK: - Lifecycle

    nonisolated var status: SMAppService.Status {
        SMAppService.daemon(plistName: HelperConstants.launchdPlistName).status
    }

    func install() throws {
        let service = SMAppService.daemon(plistName: HelperConstants.launchdPlistName)
        switch service.status {
        case .enabled:
            return
        case .requiresApproval:
            throw ClientError.awaitingApproval
        default:
            break
        }
        do {
            try service.register()
        } catch {
            throw ClientError.registrationFailed(error.localizedDescription)
        }
        if service.status == .requiresApproval {
            throw ClientError.awaitingApproval
        }
    }

    func uninstall() throws {
        let service = SMAppService.daemon(plistName: HelperConstants.launchdPlistName)
        invalidateConnection()
        do {
            try service.unregister()
        } catch {
            throw ClientError.registrationFailed(error.localizedDescription)
        }
    }

    // MARK: - Requests

    func send(_ request: HelperRequest) async throws -> HelperResponse {
        guard status == .enabled else {
            throw status == .requiresApproval ? ClientError.awaitingApproval : ClientError.notRegistered
        }
        let payload = try JSONEncoder().encode(request)
        let proxy = try makeProxy()
        let timeout = request.timeout

        // XPC promises a reply *or* an error handler call, but a peer that is rejected
        // by the code-signing requirement and respawned in a loop delivers neither, and
        // the await never returns. A timeout turns that into a message the user can act
        // on instead of an indefinite spinner.
        let responseData: Data = try await withCheckedThrowingContinuation { continuation in
            let box = ContinuationBox(continuation)
            let failingProxy = proxy.withErrorHandler { error in
                box.resume(throwing: ClientError.connectionFailed(error.localizedDescription))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                box.resume(throwing: ClientError.timedOut(timeout))
            }
            failingProxy.perform(payload) { data in
                box.resume(returning: data)
            }
        }

        guard let response = try? JSONDecoder().decode(HelperResponse.self, from: responseData) else {
            throw ClientError.decodingFailed
        }
        if case .failure(let failure) = response {
            throw ClientError.helper(failure)
        }
        return response
    }

    // MARK: - Connection

    private func makeProxy() throws -> ProxyBox {
        let connection = try activeConnection()
        return ProxyBox(connection: connection)
    }

    private func activeConnection() throws -> NSXPCConnection {
        if let connection { return connection }
        let connection = NSXPCConnection(machServiceName: HelperConstants.machServiceName,
                                         options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: CleatHelperProtocol.self)
        let requirement: String
        switch XPCRequirement.build(peerIdentifier: HelperConstants.machServiceName, log: log) {
        case .requirement(let value):
            requirement = value
        case .teamMismatch(let found, let expected):
            throw ClientError.connectionFailed(
                "this app is signed by team \(found) but was built for team \(expected)")
        }
        guard XPCRequirement.isWellFormed(requirement) else {
            throw ClientError.connectionFailed("the helper code-signing requirement did not parse")
        }
        connection.setCodeSigningRequirement(requirement)
        connection.invalidationHandler = { [weak self] in
            Task { await self?.clearConnection() }
        }
        connection.interruptionHandler = { [weak self] in
            Task { await self?.clearConnection() }
        }
        connection.resume()
        self.connection = connection
        return connection
    }

    private func clearConnection() {
        connection = nil
    }

    private func invalidateConnection() {
        connection?.invalidate()
        connection = nil
    }

}

/// Wraps the remote proxy so the error handler can be attached per call.
private struct ProxyBox: @unchecked Sendable {
    let connection: NSXPCConnection

    func withErrorHandler(_ handler: @escaping @Sendable (Error) -> Void) -> CleatHelperProtocol {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler(handler) as? CleatHelperProtocol else {
            // The interface is fixed at compile time, so this cannot realistically
            // fail; return a stub that reports the problem through the same path.
            handler(HelperClient.ClientError.connectionFailed("unexpected proxy type"))
            return NullProxy()
        }
        return proxy
    }
}

private final class NullProxy: NSObject, CleatHelperProtocol {
    func helperVersion(reply: @escaping @Sendable (String) -> Void) { reply("") }
    func perform(_ requestJSON: Data, reply: @escaping @Sendable (Data) -> Void) {}
}

/// Guarantees a continuation is resumed exactly once even though XPC can, in
/// principle, call both the reply block and the error handler.
private final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?

    init(_ continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Data) {
        lock.lock()
        let captured = continuation
        continuation = nil
        lock.unlock()
        captured?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let captured = continuation
        continuation = nil
        lock.unlock()
        captured?.resume(throwing: error)
    }
}
