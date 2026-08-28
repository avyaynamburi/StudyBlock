import Foundation
import os

enum LockError: LocalizedError {
    case locked(until: Date)
    case alreadyLocked
    case invalidEndDate
    case tooLong

    var errorDescription: String? {
        switch self {
        case .locked(let until):
            let time = until.formatted(date: .omitted, time: .shortened)
            return "A locked focus session is running — blocking can't change until \(time)."
        case .alreadyLocked:
            return "A locked session is already running."
        case .invalidEndDate:
            return "The session end time must be in the future."
        case .tooLong:
            return "Locked sessions are capped at 8 hours."
        }
    }
}

/// Single owner of all /etc/hosts operations in the helper. While a locked
/// session is active it refuses apply/clear requests, re-writes the hosts
/// file within seconds if anyone tampers with it, and auto-unblocks at the
/// deadline — even across helper restarts and reboots (lock state persists
/// in /var/db and the daemon has RunAtLoad).
final class LockManager {
    static let shared = LockManager()

    private struct LockState: Codable {
        var endDate: Date
        var domains: [String]
    }

    private static let lockFilePath = "/var/db/com.avyay.studyblock.lock.json"

    private let queue = DispatchQueue(label: "com.avyay.studyblock.lock")
    private let hosts = HostsFileManager()
    private let logger = Logger(subsystem: "com.avyay.studyblock.helper", category: "lock")
    private var enforcementTimer: DispatchSourceTimer?

    // MARK: - Public API (thread-safe)

    func applyBlocklist(_ domains: [String]) throws {
        try queue.sync {
            try ensureUnlocked()
            try hosts.apply(domains: domains)
        }
    }

    func clearBlocklist() throws {
        try queue.sync {
            try ensureUnlocked()
            try hosts.clear()
        }
    }

    func startLockedSession(domains: [String], endDate: Date) throws {
        try queue.sync {
            guard activeLock() == nil else { throw LockError.alreadyLocked }
            guard endDate > Date() else { throw LockError.invalidEndDate }
            guard endDate.timeIntervalSinceNow <= StudyBlockShared.maxLockSeconds else { throw LockError.tooLong }

            try hosts.apply(domains: domains)
            try persist(LockState(endDate: endDate, domains: domains))
            startEnforcement()
            logger.info("Locked session started, ends \(endDate.description)")
        }
    }

    func lockEndDate() -> Date? {
        queue.sync { activeLock()?.endDate }
    }

    /// Ends the active lock right now, regardless of remaining time. The app
    /// only calls this after its own typed-challenge friction gate passes —
    /// the helper itself doesn't gate who's allowed to ask.
    func endEarly() {
        queue.sync {
            guard activeLock() != nil else { return }
            endLock()
            logger.info("Locked session ended early")
        }
    }

    /// Called once at helper launch: resume enforcement of a live lock, or
    /// clean up after one that expired while the helper was down.
    func resumeAfterLaunch() {
        queue.sync {
            guard let lock = loadPersisted() else { return }
            if lock.endDate > Date() {
                if !currentHostsMatch(lock.domains) {
                    try? hosts.apply(domains: lock.domains)
                }
                startEnforcement()
                logger.info("Resumed locked session ending \(lock.endDate.description)")
            } else {
                endLock()
            }
        }
    }

    // MARK: - Internals (call only on `queue`)

    private func ensureUnlocked() throws {
        if let lock = activeLock() { throw LockError.locked(until: lock.endDate) }
    }

    private func activeLock() -> LockState? {
        guard let lock = loadPersisted(), lock.endDate > Date() else { return nil }
        return lock
    }

    private func startEnforcement() {
        enforcementTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in self?.enforce() }
        timer.resume()
        enforcementTimer = timer
    }

    private func enforce() {
        guard let lock = loadPersisted() else {
            enforcementTimer?.cancel()
            enforcementTimer = nil
            return
        }
        if Date() >= lock.endDate {
            endLock()
            return
        }
        if !currentHostsMatch(lock.domains) {
            logger.warning("Hosts file tampered with during locked session — re-applying")
            try? hosts.apply(domains: lock.domains)
        }
    }

    private func endLock() {
        enforcementTimer?.cancel()
        enforcementTimer = nil
        try? hosts.clear()
        try? FileManager.default.removeItem(atPath: Self.lockFilePath)
        logger.info("Locked session ended, blocklist cleared")
    }

    private func currentHostsMatch(_ domains: [String]) -> Bool {
        guard let content = try? String(contentsOfFile: StudyBlockShared.hostsPath, encoding: .utf8) else { return false }
        return HostsFileManager.sectionMatches(content: content, domains: domains)
    }

    private func persist(_ state: LockState) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        try data.write(to: URL(fileURLWithPath: Self.lockFilePath), options: .atomic)
    }

    private func loadPersisted() -> LockState? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Self.lockFilePath)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LockState.self, from: data)
    }
}
