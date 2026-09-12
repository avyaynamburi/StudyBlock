import AppKit
import Foundation
import UserNotifications

/// How a session measures itself.
///
/// A timer counts down to a deadline it was given; a stopwatch counts up and
/// ends when you say so. Everything else about a session — blocking, stats,
/// the task it is linked to — is identical, which is why this is a mode on
/// one controller rather than a second one.
enum FocusMode: String, CaseIterable, Identifiable {
    case timer, stopwatch

    var id: String { rawValue }
    var label: String { self == .timer ? "Timer" : "Stopwatch" }
    var icon: String { self == .timer ? "timer" : "stopwatch" }
}

/// A finished session, waiting on the only question it can't answer itself:
/// is the thing you were working on actually done?
struct FinishedSessionPrompt: Identifiable, Equatable {
    let id = UUID()
    var taskID: UUID
    var taskTitle: String
    var minutes: Int
}

/// Where a session found the task it is timing, so the board can put it back
/// there afterwards.
///
/// A task is in Currently Doing for exactly as long as something is being
/// done: the session moves it there on the way in and returns it on the way
/// out. Without the return, Currently Doing silently becomes a second backlog
/// of everything you have ever started.
struct SessionTaskPlacement: Identifiable, Equatable {
    let id = UUID()
    var taskID: UUID
    var column: TaskColumn
    /// Whether the card was manually placed before the session took it. A
    /// session moving a card is not the user placing it, so this is restored
    /// too — otherwise every session quietly opts its task out of automatic
    /// column promotion for good.
    var wasManual: Bool
}

/// Drives focus sessions: countdown, auto-block on start, auto-unblock on
/// end, stats recording, and completion notification. Sessions can be
/// **locked** (helper-enforced: no early unblock, hosts tampering reverted)
/// and linked to a task so focused time accrues to its course. A running
/// session survives app relaunch via UserDefaults.
@MainActor
final class FocusTimerController: ObservableObject {
    static let presetMinutes = [25, 45, 50]
    /// Offered when a session that has run out asks whether to keep going.
    static let extendMinutes = [5, 10, 15, 30]

    @Published private(set) var endDate: Date?
    @Published private(set) var remaining: TimeInterval = 0
    /// Which way this session counts. A stopwatch has no `endDate`, so most
    /// of the countdown machinery simply doesn't apply to it.
    @Published private(set) var mode: FocusMode = .timer
    /// How long the session has been running, counted up. Maintained for both
    /// modes — the timer uses it to credit overtime, the stopwatch shows it.
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var isLockedSession = false
    /// The task this session is timing, if any. Published so the rest of the
    /// app can tell whether something that just happened to a task happened
    /// to *this* one.
    @Published private(set) var currentTaskID: UUID?
    @Published private(set) var currentTaskTitle: String?
    /// Where this session's task was before the session moved it into
    /// Currently Doing.
    private var currentTaskPlacement: SessionTaskPlacement?
    @Published private(set) var currentTaskCourse: String?
    /// Set when a locked session's safety valve trips (see `pollHelperHealth`).
    /// Stays set — surfaced as a banner — until the user acknowledges it.
    @Published var helperStuckWarning = false
    /// True once a *task-linked* session has reached zero. The session stays
    /// open — the block stays on and the clock keeps counting up — until the
    /// user comes back and either finishes or extends it, so time away from
    /// the desk isn't silently counted as the end of studying.
    @Published private(set) var isAwaitingConfirmation = false
    /// How long the session has been sitting past its deadline.
    @Published private(set) var overtime: TimeInterval = 0
    /// Set when a task-linked session ends by being *finished* — the app then
    /// has one question worth asking, and exactly one moment at which asking
    /// it isn't an interruption.
    ///
    /// Published rather than handled here because the answer moves a task
    /// between columns, and this controller has no business holding the
    /// board. It is cleared by whoever presents the question.
    @Published var finishedPrompt: FinishedSessionPrompt?
    /// Published when a task-linked session ends, for the board to act on.
    /// Set for *every* ending — finished, given up on, or cut short — because
    /// the task belongs back where it came from either way.
    @Published var taskToRestore: SessionTaskPlacement?

    private let blocker: BlockerViewModel
    private let stats: StatsStore
    private var startDate: Date?
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
        static let taskColumn = "focusTaskColumn"
        static let taskColumnManual = "focusTaskColumnManual"
        static let lastMinutes = "focusLastMinutes"
        static let mode = "focusSessionMode"
    }

    init(blocker: BlockerViewModel, stats: StatsStore) {
        self.blocker = blocker
        self.stats = stats
        restorePersistedSession()
        if !isRunning {
            Task { await adoptHelperLockIfNeeded() }
        }
    }

    /// A session is running whenever it has a start. It used to key off
    /// `endDate`, which a stopwatch does not have.
    var isRunning: Bool { startDate != nil }

    var isStopwatch: Bool { mode == .stopwatch }

    /// Fraction of the session elapsed, 0…1. Drives the progress ring, which
    /// a stopwatch has no basis for — there is no total to be a fraction of.
    var progress: Double {
        guard let endDate, let startDate else { return 0 }
        let total = endDate.timeIntervalSince(startDate)
        guard total > 0 else { return 0 }
        return min(1, max(0, 1 - remaining / total))
    }

    /// What the progress ring should draw.
    ///
    /// A stopwatch has no total to be a fraction of, so rather than sit at
    /// zero looking broken, its ring sweeps once a minute — motion that says
    /// "running" without implying an end that doesn't exist.
    var ringProgress: Double {
        guard mode == .stopwatch else { return progress }
        return elapsed.truncatingRemainder(dividingBy: 60) / 60
    }

    /// Duration of the last started session; used by "focus on this task".
    var defaultMinutes: Int {
        let saved = UserDefaults.standard.integer(forKey: Keys.lastMinutes)
        return saved > 0 ? saved : 25
    }

    var remainingLabel: String {
        Self.clock(remaining)
    }

    /// The stopwatch's own reading, counting up.
    var elapsedLabel: String {
        Self.clock(elapsed)
    }

    /// Whatever this session's headline number is, for the ring and the menu
    /// bar: time left on a timer, time served on a stopwatch.
    var displayLabel: String {
        if isAwaitingConfirmation { return overtimeLabel }
        return mode == .stopwatch ? elapsedLabel : remainingLabel
    }

    /// m:ss, growing an hours field only once it is needed — a stopwatch can
    /// run all afternoon, where a 25-minute timer never could.
    private static func clock(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        let hours = total / 3600
        guard hours > 0 else { return String(format: "%d:%02d", total / 60, total % 60) }
        return String(format: "%d:%02d:%02d", hours, (total % 3600) / 60, total % 60)
    }

    var lockedUntilLabel: String {
        endDate.map { $0.formatted(date: .omitted, time: .shortened) } ?? ""
    }

    var overtimeLabel: String {
        Self.clock(overtime)
    }

    /// Minutes the session has actually run, overtime included — what gets
    /// credited when the user finally finishes it.
    var elapsedMinutes: Int {
        guard let startDate else { return 0 }
        return Int((Date().timeIntervalSince(startDate) / 60).rounded())
    }

    func start(minutes: Int, task: TodoItem? = nil, locked: Bool = false) {
        guard !isRunning, minutes > 0 else { return }
        Task { await startSession(mode: .timer, minutes: minutes, task: task, locked: locked) }
    }

    /// Starts an open-ended session that counts up until it is stopped.
    ///
    /// Never locked: the helper enforces a lock by being told when to release
    /// it, and a stopwatch has no such moment to give.
    func startStopwatch(task: TodoItem? = nil) {
        guard !isRunning else { return }
        Task { await startSession(mode: .stopwatch, minutes: 0, task: task, locked: false) }
    }

    /// Starts whichever kind of session `mode` names, so callers holding a
    /// mode picker don't each have to branch.
    func start(mode: FocusMode, minutes: Int, task: TodoItem? = nil, locked: Bool = false) {
        switch mode {
        case .timer: start(minutes: minutes, task: task, locked: locked)
        case .stopwatch: startStopwatch(task: task)
        }
    }

    /// Ends the session early. No-op for locked sessions — that's the point.
    func giveUp() {
        guard !isLockedSession else { return }
        finish(completed: false)
    }

    /// Ends a stopwatch and banks the time. Stopping one is how it is
    /// *meant* to end, so unlike `giveUp` this counts as a completed session
    /// rather than an abandoned one.
    func stopStopwatch() {
        guard isRunning, mode == .stopwatch else { return }
        finish(completed: true, notify: false, endingAt: Date())
    }

    /// Stops a stopwatch because its task has just been ticked off.
    ///
    /// Banks the time exactly like `stopStopwatch`, but hands the task back
    /// to nobody: "is it done?" was answered the moment the user checked the
    /// box, and restoring the card's old column would drag it straight back
    /// out of Completed.
    func stopStopwatchForCompletedTask() {
        guard isRunning, mode == .stopwatch else { return }
        finish(completed: true, notify: false, endingAt: Date(), askIfDone: false)
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

    private func startSession(mode: FocusMode, minutes: Int, task: TodoItem?, locked: Bool) async {
        // Tells background automation (the block schedule) to keep its hands
        // off the block until this session ends.
        blocker.isSessionManaged = true
        self.mode = mode
        let now = Date()
        // A stopwatch has no deadline; everything downstream keys off this
        // being nil rather than off the mode itself.
        let end: Date? = mode == .timer ? now.addingTimeInterval(TimeInterval(minutes * 60)) : nil
        let canBlock = !blocker.domains.isEmpty && blocker.helperState == .ready

        if locked, canBlock, let end {
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
        elapsed = 0
        currentTaskID = task?.id
        currentTaskTitle = task?.title
        currentTaskCourse = task?.course
        // Read off the task itself rather than asked of the caller: every
        // route into a session already hands over the whole task, and a
        // caller that had to remember this is a caller that will forget.
        currentTaskPlacement = task.map {
            SessionTaskPlacement(taskID: $0.id, column: $0.column, wasManual: $0.columnIsManual)
        }

        let defaults = UserDefaults.standard
        defaults.set(end, forKey: Keys.end)
        defaults.set(now, forKey: Keys.start)
        defaults.set(blockingWasOnBefore, forKey: Keys.blockingWasOn)
        defaults.set(isLockedSession, forKey: Keys.locked)
        defaults.set(task?.id.uuidString, forKey: Keys.taskID)
        defaults.set(task?.title, forKey: Keys.taskTitle)
        defaults.set(task?.course, forKey: Keys.taskCourse)
        defaults.set(task?.column.rawValue, forKey: Keys.taskColumn)
        defaults.set(task?.columnIsManual ?? false, forKey: Keys.taskColumnManual)
        defaults.set(mode.rawValue, forKey: Keys.mode)
        // Only a real duration is worth remembering as the default next time.
        if mode == .timer { defaults.set(minutes, forKey: Keys.lastMinutes) }

        startTicker()
    }

    private func restorePersistedSession() {
        let defaults = UserDefaults.standard
        let savedMode = defaults.string(forKey: Keys.mode).flatMap(FocusMode.init(rawValue:)) ?? .timer

        // A stopwatch is stored as a start with no end, so it restores on a
        // path of its own: pick the clock back up where it was and keep going.
        if savedMode == .stopwatch {
            guard let start = defaults.object(forKey: Keys.start) as? Date else { return }
            mode = .stopwatch
            startDate = start
            endDate = nil
            isLockedSession = false
            blockingWasOnBefore = defaults.bool(forKey: Keys.blockingWasOn)
            currentTaskID = defaults.string(forKey: Keys.taskID).flatMap(UUID.init)
            currentTaskTitle = defaults.string(forKey: Keys.taskTitle)
            currentTaskCourse = defaults.string(forKey: Keys.taskCourse)
            restorePersistedPlacement()
            blocker.isSessionManaged = true
            startTicker()
            return
        }

        mode = .timer
        guard let end = defaults.object(forKey: Keys.end) as? Date else { return }
        // `isRunning` keys off the start now, so a stored session missing its
        // start would read as not running while its ticker ran and its end
        // date sat in defaults — live, invisible, and impossible to finish.
        // Falling back keeps it recoverable; only a corrupt store gets here.
        startDate = (defaults.object(forKey: Keys.start) as? Date) ?? Date()
        blockingWasOnBefore = defaults.bool(forKey: Keys.blockingWasOn)
        isLockedSession = defaults.bool(forKey: Keys.locked)
        currentTaskID = defaults.string(forKey: Keys.taskID).flatMap(UUID.init)
        currentTaskTitle = defaults.string(forKey: Keys.taskTitle)
        currentTaskCourse = defaults.string(forKey: Keys.taskCourse)
        restorePersistedPlacement()
        endDate = end
        if end <= Date() {
            // Elapsed while the app was closed. A task session comes back
            // still waiting to be finished, which is the whole point of it not
            // ending on its own; one without a task just closes out.
            if currentTaskID != nil {
                isAwaitingConfirmation = true
                overtime = -(endDate?.timeIntervalSinceNow ?? 0)
                isLockedSession = false
                startTicker()
            } else {
                finish(completed: true, notify: false)
            }
        } else {
            if isLockedSession { beginHelperHealthTracking() }
            startTicker()
        }
    }

    /// Picks the task's original spot back up after a relaunch, so a session
    /// restored from disk still knows where to put its task when it ends.
    private func restorePersistedPlacement() {
        let defaults = UserDefaults.standard
        guard let taskID = currentTaskID else { return }
        let column = defaults.string(forKey: Keys.taskColumn)
            .flatMap(TaskColumn.init(rawValue:)) ?? .doing
        currentTaskPlacement = SessionTaskPlacement(
            taskID: taskID, column: column,
            wasManual: defaults.bool(forKey: Keys.taskColumnManual))
    }

    /// If the helper is enforcing a lock this app doesn't know about (fresh
    /// install, cleared defaults), show it as the running session.
    private func adoptHelperLockIfNeeded() async {
        guard let end = await blocker.helperLockEndDate(), end > Date(), !isRunning else { return }
        mode = .timer
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
        guard let startDate else { return }
        elapsed = Date().timeIntervalSince(startDate)
        // A stopwatch has no deadline to run down, so the whole countdown
        // below — expiry, overtime, the helper health check — is moot.
        guard let endDate else { return }
        let left = endDate.timeIntervalSinceNow
        remaining = max(0, left)

        if left <= 0 {
            // A session started from a task waits for its owner instead of
            // ending itself. One without a task has nobody to report back to,
            // so it still finishes on its own.
            guard currentTaskID != nil else {
                finish(completed: true)
                return
            }
            if !isAwaitingConfirmation { beginAwaitingConfirmation() }
            overtime = -left
            return
        }
        if isLockedSession { checkHelperHealthIfDue() }
    }

    /// Enters the "time is up, still waiting" state.
    ///
    /// A locked session stops counting as locked here: the helper released its
    /// hold at the deadline, so there is nothing left to enforce, and leaving
    /// the flag set would keep the "no giving up" UI on screen and make the
    /// health check treat the expired lock as a helper that has gone silent.
    private func beginAwaitingConfirmation() {
        isAwaitingConfirmation = true
        isLockedSession = false
        lastHelperContact = nil
        announceCompletion(minutes: plannedMinutes)
    }

    private var plannedMinutes: Int {
        guard let startDate, let endDate else { return 0 }
        return Int((endDate.timeIntervalSince(startDate) / 60).rounded())
    }

    /// Finishes a session that has been waiting at zero, crediting everything
    /// it actually ran — the overtime included.
    func finishAwaited() {
        guard isAwaitingConfirmation else { return }
        isAwaitingConfirmation = false
        overtime = 0
        finish(completed: true, notify: false, endingAt: Date())
    }

    /// Adds time, either to a session still running or to one waiting at zero.
    /// From a waiting state the clock restarts from now rather than from the
    /// old deadline, so "extend 10 minutes" always buys ten more minutes
    /// rather than however much is left after the overtime.
    func extend(by minutes: Int) {
        guard isRunning, minutes > 0, mode == .timer else { return }
        // A lock that's still in force can't be lengthened: the helper refuses
        // a second startLockedSession while one is active, so the app would
        // end up counting toward a deadline the helper had already released,
        // and the health check would later read that as a silent helper.
        // Once the lock expires — which is exactly when a session starts
        // waiting — extending is free.
        guard !isLockedSession else { return }
        let base = isAwaitingConfirmation ? Date() : (endDate ?? Date())
        let newEnd = base.addingTimeInterval(TimeInterval(minutes * 60))

        endDate = newEnd
        remaining = max(0, newEnd.timeIntervalSinceNow)
        overtime = 0
        isAwaitingConfirmation = false
        UserDefaults.standard.set(newEnd, forKey: Keys.end)
        startTicker()
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

    private func finish(completed: Bool, notify: Bool = true, endingAt: Date? = nil,
                        askIfDone: Bool = true) {
        blocker.isSessionManaged = false
        // Keyed on the start, not the end: a stopwatch has no end date, and
        // guarding on one here used to mean it could never be finished at all.
        guard let start = startDate else { return }
        ticker?.invalidate()
        ticker = nil

        // A completed timer is credited to its deadline; anything else — a
        // stopwatch, or a session given up on — to the moment it stopped.
        let sessionEnd = endingAt ?? ((completed ? endDate : nil) ?? Date())
        let minutes = sessionEnd.timeIntervalSince(start) / 60
        stats.record(minutes: minutes, completed: completed,
                     course: currentTaskCourse, taskTitle: currentTaskTitle)

        // Asked only of a session that ran its course. One given up on has
        // already answered the question.
        if askIfDone, let placement = currentTaskPlacement {
            taskToRestore = placement
            if completed, let taskID = currentTaskID, let title = currentTaskTitle {
                finishedPrompt = FinishedSessionPrompt(taskID: taskID, taskTitle: title,
                                                       minutes: max(1, Int(minutes.rounded())))
            }
        }

        let wasLocked = isLockedSession
        endDate = nil
        startDate = nil
        remaining = 0
        elapsed = 0
        overtime = 0
        mode = .timer
        isAwaitingConfirmation = false
        isLockedSession = false
        currentTaskID = nil
        currentTaskTitle = nil
        currentTaskCourse = nil
        currentTaskPlacement = nil
        for key in [Keys.end, Keys.start, Keys.blockingWasOn, Keys.locked,
                    Keys.taskID, Keys.taskTitle, Keys.taskCourse, Keys.mode,
                    Keys.taskColumn, Keys.taskColumnManual] {
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
