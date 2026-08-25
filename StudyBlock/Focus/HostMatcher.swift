import Foundation

/// Pure host-vs-blocklist matching, shared by the tab closer. Kept
/// dependency-free so it's unit-testable in isolation.
enum HostMatcher {
    /// True if `host` belongs to any blocked domain: an exact match or a
    /// subdomain. A leading `www.` on the configured domain is ignored so
    /// entering either form catches both. The leading-dot check prevents
    /// suffix spoofs ("notmonkeytype.com", "monkeytype.com.evil.com").
    static func matches(_ host: String, blockedDomains: [String]) -> Bool {
        let h = host.lowercased()
        for raw in blockedDomains {
            var base = raw.lowercased()
            if base.hasPrefix("www.") { base = String(base.dropFirst(4)) }
            guard !base.isEmpty else { continue }
            if h == base || h.hasSuffix("." + base) { return true }
        }
        return false
    }
}
