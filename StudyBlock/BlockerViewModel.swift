import Foundation
import ServiceManagement
import SwiftUI

enum HelperState: Equatable {
    case needsSetup
    case requiresApproval
    case ready
    case notFound
}

@MainActor
final class BlockerViewModel: ObservableObject {
    @Published var domains: [String] = []
    @Published var isBlocking = false
    @Published var helperState: HelperState = .needsSetup
    @Published var lastError: String?
    @Published var isBusy = false
    /// True when the running helper daemon is older than the app expects
    /// (e.g. after a rebuild). launchd keeps the old daemon alive until it's
    /// killed, so its code must be refreshed explicitly.
    @Published var helperOutdated = false
    /// True when SMAppService says the helper is enabled but it never answers.
    /// Happens when the app's signing identity changed: the stale BTM record
    /// makes launchd kill the daemon on every spawn (EX_CONFIG), yet the
    /// registration still reads as enabled — so neither the setup banner nor
    /// the version check would otherwise surface a fix.
    @Published var helperUnreachable = false

    private let helper = HelperClient()
    private var refreshTimer: Timer?
    private var versionChecked = false
    private var versionCheckFailures = 0

    init() {
        loadBlocklist()
        refresh()
        // Keep status truthful even if hosts or Login Items change outside the
        // app (e.g. user approves the helper in System Settings).
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.refresh() }
        }
    }

    var canToggle: Bool {
        helperState == .ready && !isBusy && (isBlocking || !domains.isEmpty)
    }

    func refresh() {
        // /etc/hosts is world-readable, so blocking state can be read directly
        // without waking the helper.
        let hosts = (try? String(contentsOfFile: StudyBlockShared.hostsPath, encoding: .utf8)) ?? ""
        isBlocking = hosts.contains(StudyBlockShared.hostsBeginMarker)

        switch helper.status {
        case .enabled: helperState = .ready
        case .requiresApproval: helperState = .requiresApproval
        case .notFound: helperState = .notFound
        case .notRegistered: helperState = .needsSetup
        @unknown default: helperState = .needsSetup
        }

        if helperState == .ready {
            checkHelperVersion()
        } else {
            versionChecked = false
            versionCheckFailures = 0
            helperOutdated = false
            helperUnreachable = false
        }
    }

    /// Ask the daemon its version once per connection; flag a mismatch. If it
    /// repeatedly fails to answer while supposedly enabled, flag it as
    /// unreachable so the repair banner appears.
    private func checkHelperVersion() {
        guard !versionChecked else { return }
        versionChecked = true
        Task {
            guard let version = await helper.installedVersion() else {
                versionChecked = false // couldn't reach it; try again next refresh
                versionCheckFailures += 1
                if versionCheckFailures >= 2 { helperUnreachable = true }
                return
            }
            versionCheckFailures = 0
            helperUnreachable = false
            helperOutdated = (version != StudyBlockShared.helperVersion)
        }
    }

    /// Bring the running daemon up to the app's version. First tries a plain
    /// restart (`kickstart` — the fast path when approval is intact and only
    /// the process is stale, e.g. after a rebuild). If the daemon still can't
    /// be reached — which happens when the app's signing identity changed and
    /// macOS invalidated the old approval — falls back to a clean re-register
    /// and sends the user to System Settings to re-approve once.
    func updateHelper() {
        lastError = nil
        Task { await performHelperUpdate() }
    }

    private func performHelperUpdate() async {
        // Fast path — only worth trying when the daemon is alive but running
        // stale code. An unreachable daemon would just respawn and die again,
        // so skip the restart (and its admin prompt) and go straight to the
        // reinstall, which needs no password.
        if !helperUnreachable {
            runAsAdmin("/bin/launchctl kickstart -k system/\(StudyBlockShared.machServiceName)")
            helper.invalidateConnection()
            try? await Task.sleep(nanoseconds: 1_500_000_000)

            if let version = await helper.installedVersion(), version == StudyBlockShared.helperVersion {
                versionChecked = true
                helperOutdated = false
                refresh()
                return
            }
        }

        // Restart didn't take (or wasn't attempted) → the registration itself
        // is stale. Reinstall.
        do {
            try helper.unregister()
            try helper.register()
        } catch {
            // register() throwing usually just means approval is now pending.
            if helper.status != .requiresApproval {
                lastError = "Couldn't reinstall the helper: \(error.localizedDescription)"
            }
        }
        versionChecked = false
        versionCheckFailures = 0
        helperOutdated = false
        helperUnreachable = false
        refresh()
        if helperState == .requiresApproval {
            HelperClient.openSystemSettingsLoginItems()
        }
    }

    private func runAsAdmin(_ shellCommand: String) {
        let script = "do shell script \"\(shellCommand)\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
        process.waitUntilExit()
    }

    func setUpHelper() {
        lastError = nil
        do {
            try helper.register()
        } catch {
            // register() throws when approval is pending; that's the expected
            // first-run path, not an error worth surfacing.
            if helper.status != .requiresApproval {
                lastError = "Could not register helper: \(error.localizedDescription)"
            }
        }
        refresh()
        if helperState == .requiresApproval {
            HelperClient.openSystemSettingsLoginItems()
        }
    }

    func toggleBlocking() async {
        if isBlocking {
            await stopBlocking()
        } else {
            await startBlocking()
        }
    }

    /// Direct entry points so the focus timer can drive blocking without
    /// racing the toggle's current-state check.
    func startBlocking() async {
        await run { try await self.helper.applyBlocklist(self.domains) }
    }

    func stopBlocking() async {
        await run { try await self.helper.clearBlocklist() }
    }

    /// Starts helper-enforced locked blocking. Returns false (with lastError
    /// set) if the helper refused.
    func startLockedBlocking(until endDate: Date) async -> Bool {
        await run { try await self.helper.startLockedSession(domains: self.domains, endDate: endDate) }
        return lastError == nil
    }

    func helperLockEndDate() async -> Date? {
        guard helperState == .ready else { return nil }
        return await helper.lockEndDate()
    }

    /// Ends a locked session before its deadline. Only meant to be called
    /// after the app's own friction gate (the typed-challenge override) has
    /// already passed — returns false (with `lastError` set) on failure.
    func endLockedSessionEarly() async -> Bool {
        await run { try await self.helper.endLockedSessionEarly() }
        return lastError == nil
    }

    private func run(_ operation: () async throws -> Void) async {
        lastError = nil
        isBusy = true
        defer { isBusy = false }
        do {
            try await operation()
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func addDomain(_ raw: String) {
        lastError = nil
        guard let domain = DomainValidator.normalize(raw) else {
            lastError = "\"\(raw.trimmingCharacters(in: .whitespacesAndNewlines))\" doesn't look like a website domain"
            return
        }
        guard !domains.contains(domain) else { return }
        domains.append(domain)
        saveBlocklist()
        reapplyIfBlocking()
    }

    func removeDomains(at offsets: IndexSet) {
        domains.remove(atOffsets: offsets)
        saveBlocklist()
        reapplyIfBlocking()
    }

    /// Editing the list while a block is active updates /etc/hosts immediately,
    /// so the list shown always matches what's enforced.
    private func reapplyIfBlocking() {
        guard isBlocking, helperState == .ready else { return }
        Task {
            do {
                if domains.isEmpty {
                    try await helper.clearBlocklist()
                } else {
                    try await helper.applyBlocklist(domains)
                }
            } catch {
                lastError = error.localizedDescription
            }
            refresh()
        }
    }

    // MARK: - Persistence

    private func loadBlocklist() {
        domains = JSONStore.load([String].self, from: "blocklist.json") ?? []
    }

    private func saveBlocklist() {
        JSONStore.save(domains, to: "blocklist.json")
    }
}
