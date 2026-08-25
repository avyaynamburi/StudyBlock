import Foundation
import os

final class HelperService: NSObject, HelperProtocol {
    private let lock = LockManager.shared
    private let hosts = HostsFileManager()
    private let logger = Logger(subsystem: "com.avyay.studyblock.helper", category: "service")

    func applyBlocklist(_ domains: [String], reply: @escaping (String?) -> Void) {
        reply(errorMessage { try lock.applyBlocklist(domains) })
    }

    func clearBlocklist(reply: @escaping (String?) -> Void) {
        reply(errorMessage { try lock.clearBlocklist() })
    }

    func getStatus(reply: @escaping (Bool, String) -> Void) {
        reply(hosts.isBlocking(), StudyBlockShared.helperVersion)
    }

    func startLockedSession(_ domains: [String], endDate: Date, reply: @escaping (String?) -> Void) {
        reply(errorMessage { try lock.startLockedSession(domains: domains, endDate: endDate) })
    }

    func getLockEndDate(reply: @escaping (Date?) -> Void) {
        reply(lock.lockEndDate())
    }

    private func errorMessage(_ operation: () throws -> Void) -> String? {
        do {
            try operation()
            return nil
        } catch {
            logger.error("helper operation failed: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }
}
