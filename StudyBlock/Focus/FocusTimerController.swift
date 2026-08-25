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

    private let blocker: BlockerViewModel
    private let stats: StatsStore
    private var startDate: Date?
    private var currentTaskID: UUID?
    private var blockingWasOnBefore = false
    private var ticker: Timer?

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
        startTicker()
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
        }
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
