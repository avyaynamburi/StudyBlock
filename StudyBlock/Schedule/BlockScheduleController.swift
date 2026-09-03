import AppKit
import Combine
import Foundation

/// Watches the clock and switches blocking on when a scheduled window opens,
/// off when the last one closes.
///
/// It acts on *transitions* only. Nothing is re-asserted while a window is
/// open, so turning a scheduled block off by hand leaves it off until the next
/// window — a schedule is a reminder that starts itself, not a lock.
@MainActor
final class BlockScheduleController: ObservableObject {
    @Published var schedules: [BlockSchedule] = [] {
        didSet {
            JSONStore.save(schedules, to: "blockSchedules.json")
            // An edit can open or close a window immediately (switching a
            // schedule on during its own hours, say), so re-evaluate rather
            // than waiting up to a tick for it to take effect.
            evaluate()
        }
    }

    /// Schedules whose window is open right now — drives the "on now" markers.
    @Published private(set) var activeIDs: Set<UUID> = []

    private let blocker: BlockerViewModel
    private var ticker: Timer?
    private var wakeObserver: NSObjectProtocol?
    /// True while blocking is on because a window opened it. Without this the
    /// scheduler would switch off a block the user had started themselves.
    private var startedByScheduler = false

    init(blocker: BlockerViewModel) {
        self.blocker = blocker
        schedules = JSONStore.load([BlockSchedule].self, from: "blockSchedules.json") ?? []

        // Evaluated at launch rather than waiting for a transition: the Mac is
        // usually asleep or the app closed at the moment a window opens, so a
        // scheduler that only reacted to boundaries it witnessed would miss
        // nearly all of them.
        evaluate()

        ticker = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.evaluate() }
        }
        // Timers don't fire while the machine sleeps, so a window that opened
        // overnight is caught the moment it wakes instead of up to 15s later.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.evaluate() }
        }
    }

    deinit {
        ticker?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    var activeSchedules: [BlockSchedule] {
        schedules.filter { activeIDs.contains($0.id) }
    }

    // MARK: - Editing

    func add(_ schedule: BlockSchedule) {
        schedules.append(schedule)
    }

    func update(_ schedule: BlockSchedule) {
        guard let index = schedules.firstIndex(where: { $0.id == schedule.id }) else { return }
        schedules[index] = schedule
    }

    func delete(_ id: UUID) {
        schedules.removeAll { $0.id == id }
    }

    /// Removes every schedule. `didSet` re-evaluates, so a window that was
    /// open a moment ago closes here and hands its block back — the same path
    /// as deleting the last schedule one at a time.
    func clearAll() {
        guard !schedules.isEmpty else { return }
        schedules.removeAll()
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let index = schedules.firstIndex(where: { $0.id == id }) else { return }
        schedules[index].isEnabled = enabled
    }

    // MARK: - The clock

    private func evaluate(now: Date = Date()) {
        let current = Set(schedules.filter { $0.isActive(at: now) }.map(\.id))
        guard current != activeIDs else { return }

        let opened = !current.subtracting(activeIDs).isEmpty
        let closedEverything = current.isEmpty && !activeIDs.isEmpty
        activeIDs = current
        blocker.setScheduledGroups(scheduledGroupIDs())

        if opened {
            startedByScheduler = true
            Task { await blocker.startBlocking() }
        } else if closedEverything, startedByScheduler {
            startedByScheduler = false
            // A focus session owns the block while it runs; closing a window
            // underneath one would hand back the very sites it's holding shut.
            guard !blocker.isSessionManaged else { return }
            Task { await blocker.stopBlocking() }
        }
    }

    /// The lists every open window asks for. A schedule naming no lists means
    /// all of them, so it keeps working as lists are added and renamed.
    private func scheduledGroupIDs() -> Set<UUID> {
        var ids = Set<UUID>()
        for schedule in schedules where activeIDs.contains(schedule.id) {
            if schedule.groupIDs.isEmpty { return Set(blocker.groups.map(\.id)) }
            ids.formUnion(schedule.groupIDs)
        }
        return ids
    }
}
