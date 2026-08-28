import Foundation
import ServiceManagement

enum HelperClientError: LocalizedError {
    case helperReported(String)
    case notConnected(String)

    var errorDescription: String? {
        switch self {
        case .helperReported(let message): return message
        case .notConnected(let detail): return "Could not reach the helper: \(detail)"
        }
    }
}

/// One-shot gate so a value produced by racing callbacks (XPC reply vs. error
/// vs. timeout) is consumed exactly once. Thread-safe.
final class ResumeOnce {
    private var entered = false
    private let lock = NSLock()

    func tryEnter() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if entered { return false }
        entered = true
        return true
    }
}

/// Owns registration of the root helper daemon (via SMAppService) and the XPC
/// connection to it.
final class HelperClient {
    private let service = SMAppService.daemon(plistName: "\(StudyBlockShared.machServiceName).plist")
    private var connection: NSXPCConnection?
    private let connectionLock = NSLock()

    var status: SMAppService.Status { service.status }

    /// Registers the daemon with launchd. On first run this makes it appear in
    /// System Settings > General > Login Items & Extensions for approval;
    /// status stays .requiresApproval until the user allows it there.
    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }

    static func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func applyBlocklist(_ domains: [String]) async throws {
        try await call { proxy, finish in
            proxy.applyBlocklist(domains) { finish($0) }
        }
    }

    func clearBlocklist() async throws {
        try await call { proxy, finish in
            proxy.clearBlocklist { finish($0) }
        }
    }

    func startLockedSession(domains: [String], endDate: Date) async throws {
        try await call { proxy, finish in
            proxy.startLockedSession(domains, endDate: endDate) { finish($0) }
        }
    }

    func endLockedSessionEarly() async throws {
        try await call { proxy, finish in
            proxy.endLockedSessionEarly { finish($0) }
        }
    }

    /// Version string the installed helper reports, nil if unreachable.
    func installedVersion() async -> String? {
        await query { proxy, finish in
            proxy.getStatus { _, version in finish(version) }
        }
    }

    /// End date of the helper's active locked session, nil if unlocked or
    /// unreachable.
    func lockEndDate() async -> Date? {
        await query { proxy, finish in
            proxy.getLockEndDate { finish($0) }
        }
    }

    /// Runs one read-only helper query, resolving to nil on connection error
    /// or timeout — a registered-but-unlaunchable daemon must read as
    /// unreachable, not hang the caller forever.
    private func query<T>(_ body: @escaping (HelperProtocol, @escaping (T?) -> Void) -> Void) async -> T? {
        let connection = ensureConnection()
        let gate = ResumeOnce()
        return await withCheckedContinuation { continuation in
            let finish: (T?) -> Void = { value in
                if gate.tryEnter() { continuation.resume(returning: value) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.callTimeout) { finish(nil) }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                finish(nil)
            }) as? HelperProtocol else {
                finish(nil)
                return
            }
            body(proxy, finish)
        }
    }

    // MARK: - XPC plumbing

    /// How long to wait for the helper before giving up. A registered-but-
    /// unlaunchable daemon can leave an XPC call pending forever; without this
    /// the awaiting UI (toggle, locked-session start) would hang.
    private static let callTimeout: TimeInterval = 8

    /// Runs one helper call. Exactly one of {reply, connection error, timeout}
    /// resumes the continuation — `ResumeOnce` guards against the others
    /// arriving late (e.g. a real reply after the timeout already fired).
    private func call(_ body: @escaping (HelperProtocol, @escaping (String?) -> Void) -> Void) async throws {
        let connection = ensureConnection()
        let gate = ResumeOnce()
        return try await withCheckedThrowingContinuation { continuation in
            let timeout = DispatchWorkItem {
                if gate.tryEnter() {
                    continuation.resume(throwing: HelperClientError.notConnected(
                        "it didn\u{2019}t respond in time. Try \u{201C}Update Helper\u{201D} or reopen the app."))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.callTimeout, execute: timeout)

            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                if gate.tryEnter() {
                    timeout.cancel()
                    continuation.resume(throwing: HelperClientError.notConnected(error.localizedDescription))
                }
            }) as? HelperProtocol else {
                if gate.tryEnter() {
                    timeout.cancel()
                    continuation.resume(throwing: HelperClientError.notConnected("bad proxy"))
                }
                return
            }
            body(proxy) { errorMessage in
                if gate.tryEnter() {
                    timeout.cancel()
                    if let errorMessage {
                        continuation.resume(throwing: HelperClientError.helperReported(errorMessage))
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }

    /// Drop the current XPC connection so the next call reconnects — used
    /// after restarting the daemon so we talk to the fresh process.
    func invalidateConnection() {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        connection?.invalidate()
        connection = nil
    }

    private func ensureConnection() -> NSXPCConnection {
        connectionLock.lock()
        defer { connectionLock.unlock() }

        if let connection { return connection }

        let new = NSXPCConnection(machServiceName: StudyBlockShared.machServiceName, options: .privileged)
        new.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        new.invalidationHandler = { [weak self] in
            guard let self else { return }
            self.connectionLock.lock()
            self.connection = nil
            self.connectionLock.unlock()
        }
        new.resume()
        connection = new
        return new
    }
}
