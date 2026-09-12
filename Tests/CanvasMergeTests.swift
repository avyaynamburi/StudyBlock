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
        equal(store.items.first { $0.canvasUID == "uid-1" }?.course, "PHYS 221",
              "an import is tagged with its own course")
        equal(store.items.first { $0.canvasUID == "uid-2" }?.course, "HIST 101",
              "and a second course is a second tag, not one shared Canvas pile")
        equal(store.items.first { $0.canvasUID == "uid-1" }?.title, "Problem Set 5",
              "the course is the tag, so it is not repeated in the title")

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
        equal(after.title, "Essay (revised)", "its title still follows the feed")
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

        print("\nan entry with no course")
        let untagged = item("uid-4", "Orientation reading", nil, due: .instant(day))
        _ = store.mergeCanvas(feed + [untagged])
        equal(store.items.first { $0.canvasUID == "uid-4" }?.course, TaskStore.canvasCategory,
              "with no course to tag it, it falls back to the Canvas category")

        print("\na board imported under the old shape is re-tagged")
        // Exactly what a stored hash from before this change looks like: the
        // item is unchanged in the feed, but the way it was written onto the
        // board is stale, and only the hash mismatch can surface that.
        if let index = store.items.firstIndex(where: { $0.canvasUID == "uid-1" }) {
            store.items[index].course = "Canvas"
            store.items[index].title = "PHYS 221: Problem Set 5"
            store.items[index].canvasHash = "stale"
        }
        _ = store.mergeCanvas(feed)
        let retagged = store.items.first { $0.canvasUID == "uid-1" }!
        equal(retagged.course, "PHYS 221", "the old Canvas tag becomes the course")
        equal(retagged.title, "Problem Set 5", "and the prefix comes back off the title")

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

        print("\nthe colour ladder")
        let firstTwelve = (0..<12).map { Theme.categoryHue(index: $0) }
        equal(Set(firstTwelve), Set(Theme.categoryHueSteps),
              "the first twelve are exactly the picker's own stops")
        equal(firstTwelve.count, Set(firstTwelve).count, "and none of them repeats")
        let firstFortyEight = (0..<48).map { Theme.categoryHue(index: $0) }
        equal(Set(firstFortyEight).count, 48, "forty-eight categories, forty-eight colours")
        let neighbourGap = zip(firstTwelve, firstTwelve.dropFirst()).map { a, b -> Double in
            let raw = abs(a - b)
            return min(raw, 360 - raw)
        }
        check(neighbourGap.allSatisfy { $0 >= 60 },
              "consecutive categories are never neighbours on the wheel",
              "closest pair was \(neighbourGap.min() ?? 0)°")

        print("\nevery category on the board has its own colour")
        let onBoard = store.courses
        check(onBoard.count > 1, "the board has several categories to colour")
        let hues = onBoard.map { store.courseHues[$0] }
        check(hues.allSatisfy { $0 != nil }, "a sync colours every course it imports")
        equal(Set(hues.compactMap { $0 }).count, onBoard.count,
              "and no two of them landed on the same hue")
        check(Set(hues.compactMap { $0 }).isSubset(of: Set(firstFortyEight)),
              "every colour comes off the ladder, not from a hash")
        check(!Set(hues.compactMap { $0 }).contains(store.nextCategoryHue),
              "the colour offered to the next new category is one nothing is using")

        print("\ntwo categories that shared a colour")
        // Written straight to the file the next store will load, which is the
        // only way to reach the load-time cleanup.
        store.setHue(210, for: "Shared A")
        store.setHue(210, for: "Shared B")
        let reloaded = TaskStore()
        let a = reloaded.courseHues["Shared A"]
        let b = reloaded.courseHues["Shared B"]
        equal(a, 210, "the first holder in name order keeps the colour")
        check(b != nil && b != a, "the other is moved off it", "got \(String(describing: b))")
        let again = TaskStore()
        equal(again.courseHues["Shared B"], b, "and a second launch moves nothing further")

        print("\n\(checks - failures)/\(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
