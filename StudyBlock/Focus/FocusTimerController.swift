import AppKit
import Foundation
import UserNotifications

/// Drives focus sessions: countdown, auto-block on start, auto-unblock on
/// end, stats recording, and completion notification. Sessions can be
/// **locked** (helper-enforced: no early unblock, hosts tampering reverted)
/// and linked to a task so focused time accrues to its course. A running
/// session survives app relaunch via UserDefaults.
@MainActor
final class FocusTimerController: ObservableObject {
    static let presetMinutes = [25, 45, 50]

    @Published private(set) var endDate: Date?
    @Published private(set) var remaining: TimeInterval = 0
    @Published private(set) var isLockedSession = false
    @Published private(set) var currentTaskTitle: String?
    @Published private(set) var currentTaskCourse: String?
    /// Set when a locked session's safety valve trips (see `pollHelperHealth`).
    /// Stays set — surfaced as a banner — until the user acknowledges it.
    @Published var helperStuckWarning = false

    private let blocker: BlockerViewModel
    private let stats: StatsStore
    private var startDate: Date?
    private var currentTaskID: UUID?
    private var blockingWasOnBefore = false
    private var ticker: Timer?
    /// Last time the helper actually answered a health check during a locked
    /// session; nil when not tracking (no locked session running).
    private var lastHelperContact: Date?
    private var lastHelperHealthCheckAttempt: Date?

    /// How often to ping the helper during a locked session, and how long it
    /// can stay silent before the safety valve below gives up on it.
    private static let helperHealthCheckInterval: TimeInterval = 30
    private static let helperStuckThreshold: TimeInterval = 600

    private enum Keys {
        static let end = "focusSessionEnd"
        static let start = "focusSessionStart"
        static let blockingWasOn = "focusBlockingWasOnBefore"
        static let locked = "focusSessionLocked"
        static let taskID = "focusTaskID"
        static let taskTitle = "focusTaskTitle"
        static let taskCourse = "focusTaskCourse"
        static let lastMinutes = "focusLastMinutes"
    }

    init(blocker: BlockerViewModel, stats: StatsStore) {
        self.blocker = blocker
        self.stats = stats
        restorePersistedSession()
        if !isRunning {
            Task { await adoptHelperLockIfNeeded() }
        }
    }

    var isRunning: Bool { endDate != nil }

    /// Fraction of the session elapsed, 0…1. Drives the progress rings.
    var progress: Double {
        guard let endDate, let startDate else { return 0 }
        let total = endDate.timeIntervalSince(startDate)
        guard total > 0 else { return 0 }
        return min(1, max(0, 1 - remaining / total))
    }

    /// Duration of the last started session; used by "focus on this task".
    var defaultMinutes: Int {
        let saved = UserDefaults.standard.integer(forKey: Keys.lastMinutes)
        return saved > 0 ? saved : 25
    }

    var remainingLabel: String {
        let total = max(0, Int(remaining.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var lockedUntilLabel: String {
        endDate.map { $0.formatted(date: .omitted, time: .shortened) } ?? ""
    }

    func start(minutes: Int, task: TodoItem? = nil, locked: Bool = false) {
        guard !isRunning, minutes > 0 else { return }
        Task { await startSession(minutes: minutes, task: task, locked: locked) }
    }

    /// Ends the session early. No-op for locked sessions — that's the point.
    func giveUp() {
        guard !isLockedSession else { return }
        finish(completed: false)
    }

    /// Ends a *locked* session early. Only call this after the typed-challenge
    /// override has already passed — it exists specifically so that check has
    /// somewhere real to lead. Tells the helper to drop its enforcement first;
    /// only updates local state (and stats) if that actually succeeds, so a
    /// failed/unreachable helper can't leave the app thinking it's unlocked
    /// while the hosts file is still enforced underneath it.
    func forceUnlock() async {
        guard isLockedSession else { return }
        guard await blocker.endLockedSessionEarly() else { return }
        finish(completed: false)
    }

    // MARK: - Internals

    private func startSession(minutes: Int, task: TodoItem?, locked: Bool) async {
        let now = Date()
        let end = now.addingTimeInterval(TimeInterval(minutes * 60))
        let canBlock = !blocker.domains.isEmpty && blocker.helperState == .ready

        if locked, canBlock {
            // A locked session must be confirmed by the helper before we
            // present it as locked (inescapable), so this one path waits —
            // but the XPC call is now bounded by a timeout, so it can't hang.
            blockingWasOnBefore = false // lock expiry always unblocks
            guard await blocker.startLockedBlocking(until: end) else { return }
            isLockedSession = true
            beginHelperHealthTracking()
        } else {
            isLockedSession = false
            blockingWasOnBefore = blocker.isBlocking
            // Fire-and-forget: the countdown must start instantly and never
            // wait on (or hang behind) the privileged blocking call. A slow or
            // unreachable helper must not make the Start button feel dead.
            if !blocker.isBlocking, canBlock {
                Task { await blocker.startBlocking() }
            }
        }

        startDate = now
        endDate = end
        currentTaskID = task?.id
        currentTaskTitle = task?.title
        currentTaskCourse = task?.course

        let defaults = UserDefaults.standard
        defaults.set(end, forKey: Keys.end)
        defaults.set(now, forKey: Keys.start)
        defaults.set(blockingWasOnBefore, forKey: Keys.blockingWasOn)
        defaults.set(isLockedSession, forKey: Keys.locked)
        defaults.set(task?.id.uuidString, forKey: Keys.taskID)
        defaults.set(task?.title, forKey: Keys.taskTitle)
        defaults.set(task?.course, forKey: Keys.taskCourse)
        defaults.set(minutes, forKey: Keys.lastMinutes)

        startTicker()
    }

    private func restorePersistedSession() {
        let defaults = UserDefaults.standard
        guard let end = defaults.object(forKey: Keys.end) as? Date else { return }
        startDate = defaults.object(forKey: Keys.start) as? Date
        blockingWasOnBefore = defaults.bool(forKey: Keys.blockingWasOn)
        isLockedSession = defaults.bool(forKey: Keys.locked)
        currentTaskID = defaults.string(forKey: Keys.taskID).flatMap(UUID.init)
        currentTaskTitle = defaults.string(forKey: Keys.taskTitle)
        currentTaskCourse = defaults.string(forKey: Keys.taskCourse)
        endDate = end
        if end <= Date() {
            // Session elapsed while the app was closed.
            finish(completed: true, notify: false)
        } else {
            if isLockedSession { beginHelperHealthTracking() }
            startTicker()
        }
    }

    /// If the helper is enforcing a lock this app doesn't know about (fresh
    /// install, cleared defaults), show it as the running session.
    private func adoptHelperLockIfNeeded() async {
        guard let end = await blocker.helperLockEndDate(), end > Date(), !isRunning else { return }
        startDate = Date()
        endDate = end
        isLockedSession = true
        blockingWasOnBefore = false
        UserDefaults.standard.set(end, forKey: Keys.end)
        UserDefaults.standard.set(startDate, forKey: Keys.start)
        UserDefaults.standard.set(true, forKey: Keys.locked)
        beginHelperHealthTracking()
        startTicker()
    }

    /// Starts (or restarts) the "is the helper still alive" tracking used by
    /// the locked-session safety valve — a fresh clock each time a locked
    /// session begins or is picked back up.
    private func beginHelperHealthTracking() {
        lastHelperContact = Date()
        lastHelperHealthCheckAttempt = nil
    }

    private func startTicker() {
        tick()
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.tick() }
        }
    }

    private func tick() {
        guard let endDate else { return }
        remaining = endDate.timeIntervalSinceNow
        if remaining <= 0 {
            finish(completed: true)
            return
        }
        if isLockedSession { checkHelperHealthIfDue() }
    }

    /// Safety valve for a locked session whose helper has gone silent (crash,
    /// signing/approval break, etc.): pings it every 30s, and if it hasn't
    /// answered at all in 10 minutes, gives up waiting and clears the local
    /// session so the app isn't stuck forever — while being upfront that the
    /// underlying hosts-file block may still be in effect until the helper is
    /// back (see the "Update Helper" banner).
    private func checkHelperHealthIfDue() {
        let now = Date()
        if let lastAttempt = lastHelperHealthCheckAttempt,
           now.timeIntervalSince(lastAttempt) < Self.helperHealthCheckInterval { return }
        lastHelperHealthCheckAttempt = now
        Task { await pollHelperHealth() }
    }

    private func pollHelperHealth() async {
        guard isLockedSession else { return }
        if await blocker.helperLockEndDate() != nil {
            lastHelperContact = Date()
            return
        }
        guard let lastContact = lastHelperContact,
              Date().timeIntervalSince(lastContact) >= Self.helperStuckThreshold else { return }
        helperStuckWarning = true
        finish(completed: false)
    }

    /// Dismisses the safety-valve banner shown after `pollHelperHealth` trips.
    func acknowledgeHelperStuckWarning() {
        helperStuckWarning = false
    }

    private func finish(completed: Bool, notify: Bool = true) {
        guard let end = endDate else { return }
        ticker?.invalidate()
        ticker = nil

        let sessionEnd = completed ? end : Date()
        let minutes = sessionEnd.timeIntervalSince(startDate ?? sessionEnd) / 60
        stats.record(minutes: minutes, completed: completed,
                     course: currentTaskCourse, taskTitle: currentTaskTitle)

        let wasLocked = isLockedSession
        endDate = nil
        startDate = nil
        remaining = 0
        isLockedSession = false
        currentTaskID = nil
        currentTaskTitle = nil
        currentTaskCourse = nil
        for key in [Keys.end, Keys.start, Keys.blockingWasOn, Keys.locked,
                    Keys.taskID, Keys.taskTitle, Keys.taskCourse] {
            UserDefaults.standard.removeObject(forKey: key)
        }

        // Locked sessions are unblocked by the helper itself at the deadline
        // (within its 3 s enforcement tick); asking it earlier just gets
        // refused. Unlocked sessions release the block here, unless it was
        // on manually before the session.
        if !wasLocked, !blockingWasOnBefore, blocker.isBlocking, blocker.helperState == .ready {
            Task { await blocker.stopBlocking() }
        }

        if completed, notify {
            announceCompletion(minutes: Int(minutes.rounded()))
        }
    }

    private func announceCompletion(minutes: Int) {
        NSSound(named: "Glass")?.play()
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Focus session complete"
            content.body = "Nice work — \(minutes) minutes of focused studying."
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
