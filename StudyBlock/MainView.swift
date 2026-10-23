import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case focus = "Focus"
    case schedule = "Schedule"
    case tasks = "Tasks"
    case events = "Events"
    case flashcards = "Flashcards"
    case notes = "Notes"
    case stats = "Stats"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .focus: return "timer"
        case .schedule: return "calendar"
        case .tasks: return "checklist"
        case .events: return "graduationcap"
        case .flashcards: return "rectangle.on.rectangle.angled"
        case .notes: return "note.text"
        case .stats: return "chart.bar"
        }
    }
}

struct MainView: View {
    @State private var section: AppSection = .focus
    @EnvironmentObject private var timer: FocusTimerController
    @EnvironmentObject private var blocker: BlockerViewModel
    @EnvironmentObject private var stats: StatsStore
    @EnvironmentObject private var tasks: TaskStore
    @EnvironmentObject private var decks: DeckStore
    @State private var confettiTrigger = 0
    /// The running stopwatch's task, once that task has been ticked off — the
    /// question in `StopwatchDoneSheet`, waiting to be asked.
    @State private var stopwatchDone: StopwatchDonePrompt?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            content
        }
        .frame(minWidth: 860, minHeight: 600)
        .background(Theme.bg)
        // The window, not the Focus page: a session can be finished from the
        // menu bar while any tab is open, and the question has to find you
        // wherever you are.
        .sheet(item: $timer.finishedPrompt) { prompt in
            SessionFinishSheet(prompt: prompt) { finished in
                answerFinishedSession(prompt, finished: finished)
            }
        }
        .sheet(item: $stopwatchDone) { prompt in
            StopwatchDoneSheet(taskTitle: prompt.taskTitle, elapsedLabel: timer.elapsedLabel) { stop in
                if stop { timer.stopStopwatchForCompletedTask() }
            }
        }
        .overlay { ScreenConfettiOverlay(trigger: confettiTrigger) }
        // Every route to a completed task ends up here — the checkbox, a drag
        // into Completed, an import — because the store reports the
        // completion rather than each caller remembering to.
        // A task is in Currently Doing for exactly as long as a session is
        // running on it. Done here rather than at each of the four places a
        // session can start, so no route can forget.
        .onChange(of: timer.currentTaskID) { started in
            guard let started,
                  let task = tasks.items.first(where: { $0.id == started }),
                  !task.isCompleted, task.column != .doing else { return }
            tasks.move(started, to: .doing)
        }
        .onChange(of: timer.taskToRestore) { placement in
            guard let placement else { return }
            timer.taskToRestore = nil
            restorePlacement(placement)
        }
        .onChange(of: tasks.lastCompletedTaskID) { completed in
            guard let completed,
                  timer.isRunning, timer.isStopwatch,
                  timer.currentTaskID == completed else { return }
            stopwatchDone = timer.currentTaskTitle.map(StopwatchDonePrompt.init)
        }
    }

    /// Returns a finished session's task to the column it came from.
    ///
    /// A task the user completed *during* the session keeps its completion:
    /// pulling a ticked card back out of Completed because a timer happened
    /// to end would undo an answer they already gave — and it makes the
    /// question below pointless, so that gets dropped too.
    private func restorePlacement(_ placement: SessionTaskPlacement) {
        let completed = tasks.items.first { $0.id == placement.taskID }?.isCompleted ?? false
        guard !completed else {
            timer.finishedPrompt = nil
            return
        }
        tasks.restorePlacement(placement.taskID, to: placement.column, manual: placement.wasManual)
    }

    /// Applies the answer to "did you finish it?".
    ///
    /// Only "done" moves anything: by the time this is asked the task is
    /// already back in the column the session took it from.
    private func answerFinishedSession(_ prompt: FinishedSessionPrompt, finished: Bool) {
        guard finished, tasks.items.contains(where: { $0.id == prompt.taskID }) else { return }
        tasks.move(prompt.taskID, to: .completed)
        confettiTrigger += 1
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            logo
                .padding(.top, 52)
                .padding(.horizontal, 18)
                .padding(.bottom, 26)

            VStack(spacing: 3) {
                ForEach(AppSection.allCases) { item in
                    SidebarItem(section: item,
                                isSelected: section == item,
                                badge: badge(for: item)) {
                        section = item
                    }
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            sidebarFooter
                .padding(12)
        }
        .frame(width: 218)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.stroke).frame(width: 1)
        }
        .ignoresSafeArea()
    }

    private var logo: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Theme.accentFill)
                    .frame(width: 34, height: 34)
                Image(systemName: "shield.lefthalf.filled")
                    .font(Theme.ui(16, .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("StudyBlock")
                    .font(Theme.ui(16, .semibold))
                Text(blocker.isBlocking ? "Shields up" : "Shields down")
                    .font(Theme.ui(10, .medium))
                    .foregroundStyle(blocker.isBlocking ? Theme.success : .secondary)
            }
        }
    }

    private func badge(for item: AppSection) -> String? {
        switch item {
        case .tasks:
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: .now)
            let due = tasks.items.filter { task in
                guard !task.isCompleted, let dueDate = task.dueDate else { return false }
                return calendar.startOfDay(for: dueDate) <= today
            }.count
            return due > 0 ? "\(due)" : nil
        case .flashcards:
            let due = decks.decks.reduce(0) { $0 + $1.dueCount() }
            return due > 0 ? "\(due)" : nil
        default:
            return nil
        }
    }

    /// The session, wherever you are in the app.
    ///
    /// Tapping it goes to the Focus page, and the one button does whatever
    /// the session most needs next — so a stopwatch you started an hour ago
    /// can be stopped from the Notes tab without hunting for it.
    @ViewBuilder
    private var sidebarFooter: some View {
        if timer.isRunning || timer.isPending {
            VStack(spacing: 8) {
                Button {
                    section = .focus
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .stroke(dockTint.opacity(0.22), lineWidth: 3.5)
                            if timer.isRunning {
                                Circle()
                                    .trim(from: 0, to: timer.ringProgress)
                                    .stroke(dockTint, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                            }
                            Image(systemName: dockIcon)
                                .font(Theme.ui(10, .semibold))
                                .foregroundStyle(dockTint)
                        }
                        .frame(width: 30, height: 30)
                        .animation(.linear(duration: 1), value: timer.ringProgress)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(timer.isPending ? timer.pendingLabel : timer.displayLabel)
                                .font(Theme.number(15, weight: .semibold))
                                .monospacedDigit()
                            Text(dockCaption)
                                .font(Theme.ui(10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Go to the focus session")

                if let action = dockAction {
                    Button(action: action.run) {
                        Text(action.title).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SoftPillButtonStyle(tint: action.tint))
                }
            }
            .padding(11)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
        } else if stats.currentStreak > 0 {
            HStack(spacing: 8) {
                Image(systemName: "flame.fill")
                    .foregroundStyle(Theme.amber)
                Text("\(stats.currentStreak)-day streak")
                    .font(Theme.ui(10, .semibold))
                Spacer(minLength: 0)
            }
            .padding(11)
            .background(Theme.amberSoft, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    /// Amber while a session is only pending or has run out; the accent
    /// while it is actually running. The colour is the state, at a glance,
    /// from any tab.
    private var dockTint: Color {
        if timer.isPending || timer.isAwaitingConfirmation { return Theme.amber }
        return Theme.accent
    }

    private var dockIcon: String {
        if timer.isPending { return "hourglass" }
        if timer.isAwaitingConfirmation { return "checkmark.circle" }
        if timer.isLockedSession { return "lock.fill" }
        return timer.isStopwatch ? "stopwatch" : "timer"
    }

    private var dockCaption: String {
        if timer.isPending {
            return timer.pendingStart?.task?.title ?? "Starting soon"
        }
        if timer.isAwaitingConfirmation { return "Time's up — finish or extend" }
        return timer.currentTaskTitle ?? (timer.isStopwatch ? "Stopwatch" : "Focus session")
    }

    /// What this session needs next, as one button. A locked session gets
    /// none: the whole point of it is that there is nothing to press.
    private var dockAction: (title: String, tint: Color, run: () -> Void)? {
        if timer.isPending {
            return ("Cancel", Theme.danger, { timer.cancelPendingStart() })
        }
        if timer.isAwaitingConfirmation {
            return ("Finish Session", Theme.accent, { timer.finishAwaited() })
        }
        if timer.isLockedSession { return nil }
        if timer.isStopwatch {
            return ("Stop & Bank", Theme.accent, { timer.stopStopwatch() })
        }
        return ("Give Up", Theme.danger, { timer.giveUp() })
    }

    // MARK: - Content

    private var content: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            Group {
                switch section {
                case .focus: FocusView()
                case .schedule: ScheduleView()
                case .tasks: TasksView()
                case .events: EventsView()
                case .flashcards: FlashcardsView()
                case .notes: NotesView()
                case .stats: StatsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .id(section)
        .transition(.opacity)
        .animation(.easeOut(duration: 0.15), value: section)
    }
}

private struct SidebarItem: View {
    let section: AppSection
    let isSelected: Bool
    let badge: String?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .font(Theme.ui(14, .semibold))
                    .foregroundStyle(isSelected ? Theme.accent : .secondary)
                    .frame(width: 22)
                Text(section.rawValue)
                    .font(Theme.ui(13.5, isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                Spacer(minLength: 0)
                if let badge {
                    Text(badge)
                        .font(Theme.ui(10, .semibold))
                        .foregroundStyle(isSelected ? Theme.accent : .secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((isSelected ? Theme.accentSoft : Theme.surfaceLow), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Theme.accentSoft : (hovering ? Theme.surfaceLow.opacity(0.7) : .clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }
}
