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
    /// The named lists the user can switch on and off independently.
    @Published var groups: [BlockGroup] = [] {
        didSet { JSONStore.save(groups, to: "blockGroups.json") }
    }
    /// Lists switched on by an open schedule window, on top of whatever the
    /// user has enabled by hand. Kept separate from `BlockGroup.isEnabled` so
    /// a schedule never has to remember and restore the user's own switches.
    @Published private(set) var scheduledGroupIDs: Set<UUID> = []
    /// True while a focus session owns the block. Background automation checks
    /// this before switching blocking off, so a schedule closing mid-session
    /// can't unblock the sites the session is holding shut.
    @Published var isSessionManaged = false
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

    /// Everything actually enforced: the union of the enabled groups, in group
    /// order and deduplicated, so a site that appears in two lists is written
    /// to /etc/hosts once and stays blocked until both are switched off.
    ///
    /// Computed rather than stored so it can never disagree with the groups —
    /// every caller that used to read a flat list still reads this one.
    var domains: [String] {
        var seen = Set<String>()
        return groups
            .filter { $0.isEnabled || scheduledGroupIDs.contains($0.id) }
            .flatMap(\.domains)
            .filter { seen.insert($0).inserted }
    }

    /// True when this list is only on because a schedule says so — shown in
    /// the UI so a list that looks switched off but is being enforced isn't a
    /// mystery.
    func isOnBySchedule(_ group: BlockGroup) -> Bool {
        !group.isEnabled && scheduledGroupIDs.contains(group.id)
    }

    /// Called by the scheduler as windows open and close.
    func setScheduledGroups(_ ids: Set<UUID>) {
        guard ids != scheduledGroupIDs else { return }
        scheduledGroupIDs = ids
        reapplyIfBlocking()
    }

    /// How long "switch the block off" waits before the block actually comes
    /// off, in seconds. Zero means no wait.
    ///
    /// The delay is the entire feature. The moment you most want the block
    /// gone is the moment you should have the hardest time getting it, and
    /// half a minute is usually longer than the urge lasts. Switching
    /// protection *on* is never delayed.
    @Published var unblockCooldownSeconds: Int {
        didSet { UserDefaults.standard.set(unblockCooldownSeconds, forKey: Self.cooldownKey) }
    }

    /// Seconds left on a pending unblock, or nil when none is pending.
    @Published private(set) var unblockCountdown: Int?

    /// The cooldowns on offer. Anything past five minutes stops being a
    /// cooling-off period and becomes a second kind of lock.
    static let cooldownChoices = [0, 10, 30, 60, 120, 300]
    private static let cooldownKey = "unblockCooldownSeconds"
    private var cooldownTimer: Timer?

    var isCoolingDown: Bool { unblockCountdown != nil }

    init() {
        // `integer(forKey:)` can't tell "never set" from a deliberate zero,
        // and zero is a real setting here — it means no cooldown at all.
        unblockCooldownSeconds = (UserDefaults.standard.object(forKey: Self.cooldownKey) as? Int) ?? 30
        loadGroups()
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

    /// The switch the user actually flips. Turning the block on happens at
    /// once; turning it off goes through the cooldown.
    ///
    /// Automation — a schedule window closing, a focus session ending —
    /// deliberately calls `stopBlocking` instead: those already happen at a
    /// moment the user chose in advance, and making them wait would just
    /// leave the block on for half a minute after its own reason for
    /// existing had passed.
    func toggleBlocking() async {
        guard isBlocking else {
            cancelUnblock()
            await startBlocking()
            return
        }
        requestUnblock()
    }

    /// Begins the wait before the block comes off — or lifts it immediately
    /// when the cooldown is switched off.
    ///
    /// A second request while one is already pending is ignored rather than
    /// restarting the clock: the countdown is a pause for thought, not a
    /// penalty for looking at it twice.
    func requestUnblock() {
        guard isBlocking else { return }
        guard unblockCooldownSeconds > 0 else {
            Task { await stopBlocking() }
            return
        }
        guard unblockCountdown == nil else { return }
        unblockCountdown = unblockCooldownSeconds
        cooldownTimer?.invalidate()
        cooldownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.tickCooldown() }
        }
    }

    /// Called it off — the block stays exactly where it is.
    func cancelUnblock() {
        cooldownTimer?.invalidate()
        cooldownTimer = nil
        unblockCountdown = nil
    }

    private func tickCooldown() {
        guard let remaining = unblockCountdown else { return }
        // Something else already lifted the block (a session ended, a
        // schedule window closed). There is nothing left to count down to.
        guard isBlocking else {
            cancelUnblock()
            return
        }
        guard remaining > 1 else {
            cancelUnblock()
            Task { await stopBlocking() }
            return
        }
        unblockCountdown = remaining - 1
    }

    /// "30s", "2m" — how a cooldown is written wherever it is offered.
    static func cooldownLabel(_ seconds: Int) -> String {
        guard seconds > 0 else { return "Off" }
        guard seconds >= 60 else { return "\(seconds)s" }
        return "\(seconds / 60)m"
    }

    /// The pending unblock as a clock: "0:27".
    var unblockCountdownLabel: String {
        guard let remaining = unblockCountdown else { return "" }
        return String(format: "%d:%02d", remaining / 60, remaining % 60)
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

    // MARK: - Groups

    func addGroup(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        groups.append(BlockGroup(name: name))
    }

    func renameGroup(_ id: UUID, to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].name = name
    }

    func deleteGroup(_ id: UUID) {
        groups.removeAll { $0.id == id }
        reapplyIfBlocking()
    }

    func setGroup(_ id: UUID, enabled: Bool) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].isEnabled = enabled
        reapplyIfBlocking()
    }

    // MARK: - Domains

    func addDomain(_ raw: String, to groupID: UUID) {
        lastError = nil
        guard let domain = DomainValidator.normalize(raw) else {
            lastError = "\"\(raw.trimmingCharacters(in: .whitespacesAndNewlines))\" doesn't look like a website domain"
            return
        }
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        // Already in *this* list is a no-op; already in another one is fine —
        // lists are allowed to overlap.
        guard !groups[index].domains.contains(domain) else { return }
        groups[index].domains.append(domain)
        reapplyIfBlocking()
    }

    func removeDomain(_ domain: String, from groupID: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].domains.removeAll { $0 == domain }
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

    private func loadGroups() {
        if let stored = JSONStore.load([BlockGroup].self, from: "blockGroups.json") {
            groups = stored
            return
        }

        // First launch of a build that has groups. Seed the built-in
        // Distractions list, then carry over anything from the old flat
        // blocklist it doesn't already cover, so no site the user added by
        // hand is lost. An empty `blockGroups.json` is a real state — the user
        // deleted every list — so this only ever runs when the file is absent.
        var seeded = [BlockGroup(name: "Distractions", domains: BlockGroup.distractionsPreset)]
        let preset = Set(BlockGroup.distractionsPreset)
        let carriedOver = (JSONStore.load([String].self, from: "blocklist.json") ?? [])
            .filter { !preset.contains($0) }
        if !carriedOver.isEmpty {
            seeded.append(BlockGroup(name: "My Sites", domains: carriedOver))
        }
        groups = seeded
    }
}
