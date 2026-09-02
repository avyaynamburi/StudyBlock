import Foundation

/// Exercises the real `TaskStore.mergeCanvas` against a throwaway board.
///
/// Compiled with every app source except the `@main` entry point, and run
/// with `HOME` pointed at a temporary directory so `JSONStore` writes into
/// the sandbox and never touches a real board.
@main
struct CanvasMergeTests {
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

    static func item(_ uid: String, _ title: String, _ course: String?,
                     due: ICSDate, kind: CanvasItemKind = .assignment) -> CanvasItem {
        CanvasItem(sourceID: uid, kind: kind, title: title, course: course,
                   dueAt: kind == .assignment ? due : nil,
                   startsAt: kind == .assignment ? nil : due,
                   url: "https://canvas.example.edu/courses/1/assignments/1")
    }

    @MainActor
    static func main() {
        guard NSHomeDirectory().contains("canvas-merge-sandbox") else {
            print("refusing to run outside the sandbox HOME — got \(NSHomeDirectory())")
            exit(2)
        }

        let day = Date(timeIntervalSince1970: 4_102_444_800)   // 2100-01-01T00:00Z
        let later = Date(timeIntervalSince1970: 4_102_531_200) // one day on
        let store = TaskStore()

        print("\nfirst sync")
        var feed = [
            item("uid-1", "Problem Set 5", "PHYS 221", due: .instant(day)),
            item("uid-2", "Essay", "HIST 101", due: .day(year: 2100, month: 1, day: 5)),
            item("uid-3", "Reading Day", nil, due: .day(year: 2100, month: 1, day: 9), kind: .event),
        ]
        var summary = store.mergeCanvas(feed)
        equal(summary.added, 2, "both assignments are added")
        equal(summary.skippedEvents, 1, "the course event is skipped, not imported")
        equal(store.items.count, 2, "board holds exactly the two assignments")
        equal(store.items.allSatisfy { $0.course == TaskStore.canvasCategory }, true,
              "every import lands in the Canvas category")
        equal(store.items.first { $0.canvasUID == "uid-1" }?.title, "PHYS 221: Problem Set 5",
              "course is folded into the title")

        print("\nsecond sync, unchanged feed")
        summary = store.mergeCanvas(feed)
        equal(summary.added, 0, "nothing is added a second time")
        equal(summary.updated, 0, "nothing is rewritten")
        equal(summary.unchanged, 2, "both are recognised as already present")
        equal(store.items.count, 2, "re-syncing does not duplicate the board")

        print("\ndeadline moves")
        feed[0] = item("uid-1", "Problem Set 5", "PHYS 221", due: .instant(later))
        summary = store.mergeCanvas(feed)
        equal(summary.updated, 1, "a moved deadline is reported as an update")
        equal(store.items.first { $0.canvasUID == "uid-1" }?.dueDate, later,
              "the card actually moves to the new date")
        let moved = store.items.first { $0.canvasUID == "uid-1" }!
        equal(moved.manualOrder, TodoItem.dateOrderValue(for: later),
              "sort position follows the new date")

        print("\ncompleted work is never disturbed")
        let target = store.items.first { $0.canvasUID == "uid-2" }!
        store.toggleCompletion(target)
        check(store.items.first { $0.canvasUID == "uid-2" }!.isCompleted,
              "assignment marked complete")
        feed[1] = item("uid-2", "Essay (revised)", "HIST 101",
                       due: .day(year: 2100, month: 1, day: 7))
        summary = store.mergeCanvas(feed)
        let after = store.items.first { $0.canvasUID == "uid-2" }!
        check(after.isCompleted, "a completed assignment is NOT reopened by a sync")
        equal(after.title, "HIST 101: Essay (revised)", "its title still follows the feed")
        equal(after.column, .completed, "it stays in the Completed column")

        print("\ndropping out of the feed")
        let shortFeed = [feed[0]]
        summary = store.mergeCanvas(shortFeed)
        equal(store.items.count, 2, "an assignment missing from the feed is NOT deleted")

        print("\na dragged card keeps its place")
        var dragged = store.items.first { $0.canvasUID == "uid-1" }!
        store.move(dragged.id, to: .doing)
        dragged = store.items.first { $0.canvasUID == "uid-1" }!
        check(dragged.columnIsManual, "card is now manually placed")
        feed[0] = item("uid-1", "Problem Set 5", "PHYS 221", due: .instant(day))
        _ = store.mergeCanvas([feed[0]])
        let stillThere = store.items.first { $0.canvasUID == "uid-1" }!
        equal(stillThere.column, .doing, "a sync does not yank a card out of Currently Doing")
        equal(stillThere.dueDate, day, "but the due date still updates")

        print("\nhand-made tasks are untouched")
        store.add(title: "My own task", dueDate: day)
        let mine = store.items.first { $0.title == "My own task" }!
        check(!mine.isFromCanvas, "a task you wrote has no Canvas identity")
        _ = store.mergeCanvas(feed)
        check(store.items.contains { $0.title == "My own task" }, "and survives a sync")

        print("\nevents when explicitly enabled")
        // Counted against this store's own delta rather than a board total:
        // a fresh TaskStore reloads whatever the previous one just saved.
        let store2 = TaskStore()
        let before = store2.items.count
        let eventSummary = store2.mergeCanvas(feed, includeEvents: true)
        equal(eventSummary.skippedEvents, 0, "nothing is skipped once events are on")
        check(store2.items.contains { $0.canvasUID == "uid-3" }, "the event becomes a task too")
        equal(store2.items.count, before + 1, "exactly one new card, the event")
        equal(store2.items.first { $0.canvasUID == "uid-3" }?.course,
              TaskStore.canvasEventCategory, "events land in their own category")

        print("\n\(checks - failures)/\(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
