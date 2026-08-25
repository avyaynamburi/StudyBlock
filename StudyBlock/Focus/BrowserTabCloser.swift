import AppKit
import Combine
import Foundation
import os

/// DNS-level blocking (the hosts file) stops *new* connections, but a page
/// that's already loaded in an open tab keeps working — especially offline-
/// capable single-page apps. This closes tabs pointing at blocked domains
/// whenever blocking is active, in whichever supported browsers are already
/// running. Runs in the app process (like AppBlockerController), via
/// AppleScript, so it needs the one-time Automation permission per browser.
@MainActor
final class BrowserTabCloser: ObservableObject {
    /// Set once if macOS denies Automation permission, surfaced in the UI.
    @Published var permissionHint: String?

    /// Browsers that share Safari's / Chrome's scripting vocabulary
    /// (`URL of every tab of every window`, `close tab j of window i`).
    private static let browserBundleIDs = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser", // Arc
        "com.vivaldi.Vivaldi",
    ]

    private let blocker: BlockerViewModel
    private var blockingWatcher: AnyCancellable?
    private var sweepTimer: Timer?
    private let logger = Logger(subsystem: "com.avyay.StudyBlock", category: "tabs")

    init(blocker: BlockerViewModel) {
        self.blocker = blocker
        // Sweep on every rising edge of blocking, and keep sweeping every 5 s
        // while it stays on to catch tabs opened just before enforcement.
        blockingWatcher = blocker.$isBlocking
            .removeDuplicates()
            .sink { [weak self] isBlocking in
                Task { @MainActor in self?.blockingChanged(to: isBlocking) }
            }
    }

    private func blockingChanged(to isBlocking: Bool) {
        sweepTimer?.invalidate()
        sweepTimer = nil
        guard isBlocking else { return }
        sweepNow()
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.sweepNow() }
        }
    }

    func sweepNow() {
        let domains = blocker.domains
        guard blocker.isBlocking, !domains.isEmpty else { return }
        for bundleID in Self.browserBundleIDs where isRunning(bundleID) {
            closeMatchingTabs(bundleID: bundleID, domains: domains)
        }
    }

    // MARK: - AppleScript

    private func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private func closeMatchingTabs(bundleID: String, domains: [String]) {
        guard let urlsByWindow = tabURLs(bundleID: bundleID) else { return }

        // Collect (window, tab) index pairs to close. Indices are 1-based;
        // close them per window in descending order so earlier closes don't
        // shift the indices of later ones.
        var commands: [String] = []
        for (windowIndex, urls) in urlsByWindow.enumerated() {
            let toClose = urls.enumerated()
                .filter { host(of: $0.element).map { HostMatcher.matches($0, blockedDomains: domains) } ?? false }
                .map { $0.offset + 1 }
                .sorted(by: >)
            for tabIndex in toClose {
                commands.append("close tab \(tabIndex) of window \(windowIndex + 1)")
            }
        }
        guard !commands.isEmpty else { return }

        let script = "tell application id \"\(bundleID)\"\n" + commands.joined(separator: "\n") + "\nend tell"
        runScript(script, bundleID: bundleID)
        logger.info("Closed \(commands.count) blocked tab(s) in \(bundleID)")
    }

    private func host(of urlString: String) -> String? {
        URLComponents(string: urlString)?.host
    }

    /// `URL of every tab of every window` → one array of URL strings per window.
    private func tabURLs(bundleID: String) -> [[String]]? {
        let script = "tell application id \"\(bundleID)\" to get URL of every tab of every window"
        guard let result = runScript(script, bundleID: bundleID) else { return nil }
        // Nested list: outer item per window, inner item per tab URL.
        return (0..<result.numberOfItems).map { w in
            guard let windowList = result.atIndex(w + 1) else { return [] }
            return (0..<windowList.numberOfItems).compactMap { t in
                windowList.atIndex(t + 1)?.stringValue
            }
        }
    }

    @discardableResult
    private func runScript(_ source: String, bundleID: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            // -1743 = user hasn't granted Automation permission (or denied it).
            if code == -1743 {
                permissionHint = "Allow StudyBlock to control your browsers in System Settings → Privacy & Security → Automation, so it can close tabs on blocked sites."
            }
            logger.error("AppleScript error for \(bundleID): \(String(describing: error))")
            return nil
        }
        return result
    }
}
