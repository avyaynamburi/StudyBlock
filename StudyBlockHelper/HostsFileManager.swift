import Foundation
import os

enum HostsError: LocalizedError {
    case readFailed(String)
    case invalidDomain(String)
    case sanityCheckFailed
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .readFailed(let detail): return "Could not read /etc/hosts: \(detail)"
        case .invalidDomain(let domain): return "Invalid domain: \(domain)"
        case .sanityCheckFailed: return "Refusing to write /etc/hosts: new content failed sanity check"
        case .writeFailed(let detail): return "Could not write /etc/hosts: \(detail)"
        }
    }
}

/// All /etc/hosts access lives here. Rules:
/// - Only the region between the studyblock markers is ever added or removed.
/// - Writes are atomic (temp file + rename) and sanity-checked first.
/// - A pristine backup is kept at /etc/hosts.studyblock.orig, created once.
struct HostsFileManager {
    static let backupPath = "/etc/hosts.studyblock.orig"
    private static let tempPath = "/etc/hosts.studyblock.tmp"

    private let logger = Logger(subsystem: "com.avyay.studyblock.helper", category: "hosts")

    /// The exact entry lines the marked section should contain for `domains`.
    /// Pure, so lock enforcement and tests can compare against reality.
    static func blockEntries(for domains: [String]) throws -> [String] {
        let normalized = try domains.map { raw -> String in
            guard let domain = DomainValidator.normalize(raw) else { throw HostsError.invalidDomain(raw) }
            return domain
        }
        var entries: [String] = []
        for domain in normalized {
            entries.append(contentsOf: hostLines(for: domain))
            if !domain.hasPrefix("www.") {
                entries.append(contentsOf: hostLines(for: "www.\(domain)"))
            }
        }
        return entries
    }

    /// Both address-family sinkholes for one hostname. Blocking only IPv4
    /// (0.0.0.0) leaks: a site with AAAA records still resolves and connects
    /// over IPv6, so we must also route it to :: (the IPv6 "unspecified"
    /// address, the analog of 0.0.0.0).
    private static func hostLines(for host: String) -> [String] {
        ["0.0.0.0 \(host)", ":: \(host)"]
    }

    /// The entry lines currently inside the marked section, or nil if there
    /// is no (complete) section.
    static func currentSectionEntries(in content: String) -> [String]? {
        let lines = content.components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: StudyBlockShared.hostsBeginMarker),
              let end = lines[start...].firstIndex(of: StudyBlockShared.hostsEndMarker) else { return nil }
        return Array(lines[(start + 1)..<end])
    }

    /// Whether `content` contains exactly the block section `domains` demand.
    static func sectionMatches(content: String, domains: [String]) -> Bool {
        guard let expected = try? blockEntries(for: domains) else { return false }
        return currentSectionEntries(in: content) == expected
    }

    func apply(domains: [String]) throws {
        let entries = try Self.blockEntries(for: domains)

        let current = try readHosts()
        try backupIfNeeded(current)

        let section = ([StudyBlockShared.hostsBeginMarker] + entries + [StudyBlockShared.hostsEndMarker])
            .joined(separator: "\n")

        var base = stripSection(from: current)
        if !base.hasSuffix("\n") { base += "\n" }
        try writeHosts(base + "\n" + section + "\n")
        flushDNSCache()
        logger.info("Applied blocklist with \(entries.count) entries")
    }

    func clear() throws {
        let current = try readHosts()
        guard current.contains(StudyBlockShared.hostsBeginMarker) else { return }
        try writeHosts(stripSection(from: current))
        flushDNSCache()
        logger.info("Cleared blocklist")
    }

    func isBlocking() -> Bool {
        ((try? readHosts()) ?? "").contains(StudyBlockShared.hostsBeginMarker)
    }

    // MARK: - Internals

    private func readHosts() throws -> String {
        do {
            return try String(contentsOfFile: StudyBlockShared.hostsPath, encoding: .utf8)
        } catch {
            throw HostsError.readFailed(error.localizedDescription)
        }
    }

    private func backupIfNeeded(_ content: String) throws {
        guard !FileManager.default.fileExists(atPath: Self.backupPath) else { return }
        // Back up the file *without* our section, in case a previous session's
        // block was still active when the backup logic first runs.
        let pristine = stripSection(from: content)
        try pristine.write(toFile: Self.backupPath, atomically: true, encoding: .utf8)
        logger.info("Backed up pristine hosts file to \(Self.backupPath)")
    }

    /// Removes the marked section (and the single blank line inserted before
    /// it), leaving the rest of the file untouched.
    private func stripSection(from content: String) -> String {
        var lines = content.components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: StudyBlockShared.hostsBeginMarker) else { return content }
        let end = lines[start...].firstIndex(of: StudyBlockShared.hostsEndMarker) ?? lines.count - 1
        lines.removeSubrange(start...end)
        if start > 0, start - 1 < lines.count, lines[start - 1].isEmpty {
            lines.remove(at: start - 1)
        }
        return lines.joined(separator: "\n")
    }

    private func writeHosts(_ content: String) throws {
        // A hosts file without localhost would break the whole system; never
        // write one that lost it.
        guard content.contains("localhost"), !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HostsError.sanityCheckFailed
        }

        let fm = FileManager.default
        do {
            try content.write(toFile: Self.tempPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([
                .posixPermissions: 0o644,
                .ownerAccountName: "root",
                .groupOwnerAccountName: "wheel",
            ], ofItemAtPath: Self.tempPath)
            guard rename(Self.tempPath, StudyBlockShared.hostsPath) == 0 else {
                throw HostsError.writeFailed(String(cString: strerror(errno)))
            }
        } catch let error as HostsError {
            throw error
        } catch {
            throw HostsError.writeFailed(error.localizedDescription)
        }
    }

    private func flushDNSCache() {
        runCommand("/usr/bin/dscacheutil", ["-flushcache"])
        runCommand("/usr/bin/killall", ["-HUP", "mDNSResponder"])
    }

    private func runCommand(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            logger.error("Failed to run \(path): \(error.localizedDescription)")
        }
    }
}
