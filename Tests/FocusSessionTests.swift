import Foundation

/// Covers what a focus session asks of the board: which tasks it offers when
/// it starts, and what it does to one when it ends.
@main
struct FocusSessionTests {
    static var failures = 0
    static var checks = 0

    static func check(_ condition: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
        checks += 1
        if condition { print("  ok   \(label)") }
        else {
            failures += 1
            let extra = detail()
            print("  FAIL \(label)" + (extra.isEmpty ? "" : "\n         \(extra)"))
        }
    }

    static func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        check(actual == expected, label, "expected \(expected), got \(actual)")
    }

    static func task(_ title: String, course: String? = nil, column: TaskColumn = .backlog,
                     due: Date? = nil, completed: Bool = false) -> TodoItem {
        var item = TodoItem(title: title, course: course, dueDate: due)
        item.column = column
        item.isCompleted = completed
        if completed { item.completedAt = Date() }
        return item
    }

    @MainActor
    static func main() {
        guard NSHomeDirectory().contains("focus-sandbox") else {
            print("refusing to run outside the sandbox HOME — got \(NSHomeDirectory())")
            exit(2)
        }

        let soon = Date(timeIntervalSince1970: 4_102_444_800)
        let later = soon.addingTimeInterval(86_400 * 3)
        let board = [
            task("Read chapter 4", course: "HIST 101", due: later),
            task("Problem Set 5", course: "PHYS 122", column: .doing, due: later),
            task("Rewrite the intro", course: "HIST 101", due: soon),
            task("Old thing", completed: true),
            task("Practice problems", course: "PHYS 122"),
        ]

        print("\nwhat the sheet offers before you type")
        var offered = SessionTaskSuggestions.matches("", in: board)
        equal(offered.first?.title, "Problem Set 5", "what you're already doing comes first")
        equal(offered.dropFirst().first?.title, "Rewrite the intro", "then the nearest deadline")
        check(!offered.contains { $0.title == "Old thing" }, "a finished task is never offered")
        equal(offered.count, 4, "everything else is still there to pick from")
        equal(SessionTaskSuggestions.matches("", in: board, limit: 2).count, 2,
              "and the list is capped where the sheet runs out of room")

        print("\nwhat it offers once you do")
        offered = SessionTaskSuggestions.matches("pro", in: board)
        equal(offered.first?.title, "Problem Set 5", "a title starting with what you typed wins")
        equal(offered.count, 2, "a title merely containing it still shows")
        check(offered.contains { $0.title == "Practice problems" }, "including mid-word matches")
        offered = SessionTaskSuggestions.matches("hist", in: board)
        equal(offered.count, 2, "typing a subject finds that subject's work")
        check(offered.allSatisfy { $0.course == "HIST 101" }, "and only that subject's")
        equal(SessionTaskSuggestions.matches("nothing like this", in: board).count, 0,
              "a query matching nothing offers nothing")

        print("\noffering to make a new one")
        check(SessionTaskSuggestions.canCreate("Lab writeup", in: board),
              "a title the board doesn't have can be created")
        check(!SessionTaskSuggestions.canCreate("Problem Set 5", in: board),
              "one it already has is not offered twice")
        check(!SessionTaskSuggestions.canCreate("problem SET 5", in: board),
              "and capitals don't make it a different task")
        check(!SessionTaskSuggestions.canCreate("   ", in: board), "whitespace is not a task")

        print("\nstarting on something new")
        let store = TaskStore()
        let before = store.items.count
        let created = store.addWorkingOn(title: "  Draft the abstract  ")
        equal(created?.title, "Draft the abstract", "the title is trimmed")
        equal(created?.column, .doing, "a task you start a session on is a task you're doing")
        equal(created?.columnIsManual, true, "and it stays where it was put")
        equal(store.items.count, before + 1, "exactly one task lands on the board")
        check(store.items.contains { $0.id == created?.id }, "the one that was handed back")
        equal(store.addWorkingOn(title: "   "), nil, "an empty title creates nothing")
        equal(store.items.count, before + 1, "and leaves the board alone")

        print("\nanswering the question a finished session asks")
        guard let created else { exit(1) }
        store.move(created.id, to: .completed)
        var back = store.items.first { $0.id == created.id }
        equal(back?.isCompleted, true, "\u{201C}done\u{201D} completes the task")
        check(back?.completedAt != nil, "and dates it, so it counts on the stats page")
        store.move(created.id, to: .doing)
        back = store.items.first { $0.id == created.id }
        equal(back?.isCompleted, false, "\u{201C}still working on it\u{201D} reopens it")
        equal(back?.column, .doing, "and leaves it in Currently Doing")

        print("\nthe board reporting what was just finished")
        equal(store.lastCompletedTaskID, created.id,
              "completing a task says which one, so a running stopwatch can notice")
        let other = store.addWorkingOn(title: "Something else")!
        store.toggleCompletion(other)
        equal(store.lastCompletedTaskID, other.id, "the checkbox route reports it too")
        store.toggleCompletion(other)
        equal(store.lastCompletedTaskID, other.id,
              "reopening reports nothing — there is no new completion to react to")

        print("\nhow a delayed start is written")
        equal(FocusTimerController.delayLabel(0), "Now", "no delay says so in words")
        equal(FocusTimerController.delayLabel(5), "5 min", "and a delay says how long")
        check(FocusTimerController.startDelayChoices.first == 0,
              "starting now is the first choice, so it stays the default")
        check(FocusTimerController.startDelayChoices.allSatisfy { $0 <= 30 },
              "nothing on offer is long enough to be a reminder rather than a run-up")

        print("\nhow a cooldown is written")
        equal(BlockerViewModel.cooldownLabel(0), "Off", "no cooldown says so in words")
        equal(BlockerViewModel.cooldownLabel(30), "30s", "seconds under a minute")
        equal(BlockerViewModel.cooldownLabel(60), "1m", "and minutes past it")
        equal(BlockerViewModel.cooldownLabel(300), "5m", "up to the longest on offer")
        check(BlockerViewModel.cooldownChoices.contains(30), "30 seconds is one of the choices")
        check(BlockerViewModel.cooldownChoices.contains(0), "so is switching it off")

        print("\n\(checks - failures)/\(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
