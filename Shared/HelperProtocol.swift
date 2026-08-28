import Foundation

/// Constants shared between the app and the privileged helper daemon.
enum StudyBlockShared {
    /// Mach service name the daemon listens on; must match the launchd plist's
    /// Label and MachServices key.
    static let machServiceName = "com.avyay.studyblock.helper"

    /// Bumped whenever the helper's behavior changes, so the app can detect a
    /// stale installed helper and re-register it.
    static let helperVersion = "1.3.0"

    /// Hard cap on locked sessions, so a bug or typo can't lock the Mac's
    /// network for days.
    static let maxLockSeconds: TimeInterval = 8 * 60 * 60

    static let hostsPath = "/etc/hosts"
    static let hostsBeginMarker = "# >>> studyblock begin (do not edit between markers)"
    static let hostsEndMarker = "# <<< studyblock end"
}

/// XPC interface exposed by the root helper daemon.
///
/// Reply strings are error messages: nil means success. While a locked
/// session is active, applyBlocklist and clearBlocklist are refused until
/// the lock's end date passes.
@objc(HelperProtocol)
protocol HelperProtocol {
    func applyBlocklist(_ domains: [String], reply: @escaping (String?) -> Void)
    func clearBlocklist(reply: @escaping (String?) -> Void)
    func getStatus(reply: @escaping (_ isBlocking: Bool, _ version: String) -> Void)
    func startLockedSession(_ domains: [String], endDate: Date, reply: @escaping (String?) -> Void)
    func getLockEndDate(reply: @escaping (Date?) -> Void)
    /// Ends an active locked session immediately, before its deadline. The
    /// helper trusts the app to have already gated this behind real friction
    /// (the typed-challenge override) — it isn't itself a security check.
    func endLockedSessionEarly(reply: @escaping (String?) -> Void)
}

/// Domain normalization/validation, used by the app for input feedback and
/// re-run defensively by the helper before anything touches /etc/hosts.
enum DomainValidator {
    /// Turns raw user input ("https://www.YouTube.com/watch?v=x") into a bare
    /// hostname ("www.youtube.com"), or nil if no valid hostname remains.
    static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["https://", "http://"] where s.hasPrefix(scheme) {
            s = String(s.dropFirst(scheme.count))
        }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        if let colon = s.firstIndex(of: ":") { s = String(s[..<colon]) }
        // Hostname: dot-separated labels of [a-z0-9-], no leading/trailing
        // hyphen, at least two labels (so "localhost" alone is rejected).
        let pattern = "^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$"
        guard s.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return s
    }
}
