import Foundation

/// Checks the merge autofill rules and what the merged card carries over.
@main
struct TaskMergeTests {
    static var failures = 0
    static var checks = 0

    static func check(_ c: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
        checks += 1
        if c { print("  ok   \(label)") }
        else {
            failures += 1
            let extra = detail()
            print("  FAIL \(label)" + (extra.isEmpty ? "" : "\n         \(extra)"))
        }
    }

    static func equal<T: Equatable>(_ a: T, _ b: T, _ label: String) {
        check(a == b, label, "expected \(b), got \(a)")
    }

    static let friday = Date(timeIntervalSince1970: 4_102_444_800)
    static let fridayNight = Date(timeIntervalSince1970: 4_102_531_140)

    static func mine(_ title: String, course: String? = "CSDS330", due: Date? = friday,
                     notes: String = "") -> TodoItem {
        var t = TodoItem(title: title, notes: notes, course: course, dueDate: due)
        t.manualOrder = TodoItem.dateOrderValue(for: due)
        return t
    }

    static func fromCanvas(_ title: String, due: Date? = fridayNight,
                           notes: String = "") -> TodoItem {
        var t = TodoItem(title: title, notes: notes,
                         course: TaskStore.canvasCategory, dueDate: due)
        t.canvasUID = "event-assignment-77@canvas.edu"
        t.canvasHash = "abc123"
        t.manualOrder = TodoItem.dateOrderValue(for: due)
        return t
    }

    @MainActor
    static func main() {
        // Touches a real TaskStore below, which writes through JSONStore.
        guard NSHomeDirectory().contains("mp-sandbox") else {
            print("refusing to run outside the sandbox HOME — got \(NSHomeDirectory())")
            exit(2)
        }

        print("\nhand-made + Canvas: the four rules")
        let user = mine("CSDS330 homework 1", notes: "start with the reading")
        let canvas = fromCanvas("CSDS 330: HW1")
        var plan = TaskMergePlan.autofilled(user, canvas)

        equal(plan.primary.id, user.id, "the hand-made card is the survivor")
        equal(plan.resolvedTitle, "CSDS330 homework 1", "your title wins over the Canvas one")
        equal(plan.resolvedDueDate, fridayNight, "the Canvas deadline wins when both have one")
        equal(plan.resolvedCourse, "CSDS330", "your course tag wins; the Canvas tag is dropped")
        check(plan.resolvedCourse != TaskStore.canvasCategory, "the result is not tagged Canvas")

        print("\nthe merged card")
        let merged = plan.merged()
        equal(merged.id, user.id, "keeps the survivor's identity")
        equal(merged.canvasUID, canvas.canvasUID, "inherits the Canvas UID, so syncs find it")
        equal(merged.canvasHash, canvas.canvasHash, "and the hash, so it isn't reported changed")
        equal(merged.notes, "start with the reading", "notes survive")
        equal(merged.manualOrder, TodoItem.dateOrderValue(for: fridayNight),
              "sort position follows the adopted due date")

        print("\norder of arguments doesn't matter")
        let flipped = TaskMergePlan.autofilled(canvas, user)
        equal(flipped.primary.id, user.id, "the hand-made card survives either way round")
        equal(flipped.resolvedTitle, "CSDS330 homework 1", "same title either way round")
        equal(flipped.resolvedDueDate, fridayNight, "same due date either way round")

        print("\nonly one side has a due date")
        plan = TaskMergePlan.autofilled(mine("HW1", due: nil), fromCanvas("CSDS 330: HW1"))
        equal(plan.resolvedDueDate, fridayNight, "the only date in the pair is taken automatically")
        plan = TaskMergePlan.autofilled(mine("HW1", due: friday), fromCanvas("X", due: nil))
        equal(plan.resolvedDueDate, friday, "including when it's the hand-made one that has it")
        plan = TaskMergePlan.autofilled(mine("HW1", due: nil), fromCanvas("X", due: nil))
        equal(plan.resolvedDueDate, nil, "no date on either side stays no date")

        print("\nno Canvas card in the pair")
        let a = mine("Read chapter 4", course: "HIST101", due: friday)
        let b = mine("chapter 4 reading", course: "History", due: fridayNight)
        plan = TaskMergePlan.autofilled(a, b)
        equal(plan.primary.id, a.id, "the card dropped onto is the survivor")
        equal(plan.resolvedTitle, "Read chapter 4", "autofill picks one rather than asking")
        equal(plan.resolvedCourse, "HIST101", "and one category, arbitrarily but stably")
        equal(TaskMergePlan.autofilled(a, b), plan, "the same pair always resolves the same way")
        check(plan.canvasSide == nil, "no Canvas side is reported")
        equal(plan.merged().canvasUID, nil, "and the result gains no Canvas identity")

        print("\nnotes are joined, never dropped")
        equal(TaskMergePlan.joinedNotes("one", "two"), "one\n\ntwo", "both sets are kept")
        equal(TaskMergePlan.joinedNotes("", "two"), "two", "an empty side contributes nothing")
        equal(TaskMergePlan.joinedNotes("same", "same"), "same", "identical notes don't double up")
        plan = TaskMergePlan.autofilled(mine("a", notes: "mine"), fromCanvas("b", notes: "theirs"))
        equal(plan.notes, "mine\n\ntheirs", "the plan starts with both")

        print("\noverrides")
        plan = TaskMergePlan.autofilled(user, canvas)
        plan.titleSide = .secondary
        plan.courseSide = .secondary
        equal(plan.resolvedTitle, "CSDS 330: HW1", "the title choice can be flipped")
        equal(plan.resolvedCourse, TaskStore.canvasCategory, "so can the category")

        print("\nmerging one occurrence of a series")
        var series = mine("Discussion post")
        series.seriesID = UUID()
        series.repeatRule = .weekly
        series.repeatWeekdays = [3]
        series.repeatInterval = 2
        series.seriesEndDate = friday
        check(TaskMergePlan.refusal(series, canvas) == nil, "a recurring occurrence is allowed")

        let seriesPlan = TaskMergePlan.autofilled(series, canvas)
        check(seriesPlan.detachesFromSeries, "the sheet is told it will leave the series")
        let detached = seriesPlan.merged()
        equal(detached.seriesID, nil, "the merged card leaves the series")
        equal(detached.repeatRule, RepeatRule.none, "and drops the repeat rule with it")
        equal(detached.repeatWeekdays, [], "weekdays cleared")
        equal(detached.repeatInterval, 1, "interval reset")
        equal(detached.seriesEndDate, nil, "end date cleared")
        check(!detached.isRecurring, "so it is no longer an occurrence of anything")
        // A pending task holding a repeat rule with no series id is the exact
        // shape migrateLegacySeries expands on the next launch. Clearing the
        // id alone would breed a whole new series from this one card.
        check(!(detached.seriesID == nil && detached.repeatRule != .none && !detached.isCompleted),
              "it cannot be re-expanded into a new series at next launch")
        equal(detached.canvasUID, canvas.canvasUID, "and it still inherits the Canvas link")

        print("\nwhat still can't be merged")
        check(TaskMergePlan.refusal(user, user) != nil, "a task can't merge with itself")
        check(TaskMergePlan.refusal(user, canvas) == nil, "an ordinary pair is allowed")

        print("\nagreement flags drive the UI")
        let twin = mine("Same", course: "X", due: friday)
        var other = twin
        other.id = UUID()
        let same = TaskMergePlan.autofilled(twin, other)
        check(same.titlesAgree && same.duesAgree && same.coursesAgree,
              "identical fields are reported as agreeing, so no choice is shown")
        check(!plan.titlesAgree, "differing fields are reported as differing")

        print("\napplied to a real board")
        let store = TaskStore()
        store.items.removeAll()
        let created = store.add(title: "Discussion post", course: "HIST101",
                                dueDate: friday, repeatRule: .weekly, repeatInterval: 1)
        check(created > 1, "a series was materialised", "created \(created)")
        store.add(title: "hist discussion wk1", course: "HIST101", dueDate: friday)

        let occurrence = store.items.first { $0.isRecurring }!
        let seriesID = occurrence.seriesID!
        let siblingsBefore = store.pendingCount(inSeries: seriesID)
        let standalone = store.items.first { !$0.isRecurring }!

        let applied = store.applyMerge(TaskMergePlan.autofilled(occurrence, standalone))
        check(applied != nil, "the merge applied")
        equal(store.items.contains { $0.id == standalone.id }, false, "the absorbed card is gone")
        let survivor = store.items.first { $0.id == occurrence.id }
        check(survivor != nil, "the survivor is still on the board")
        equal(survivor?.seriesID, nil, "and has left the series")
        equal(store.pendingCount(inSeries: seriesID), siblingsBefore - 1,
              "the series lost exactly the one occurrence, and nothing else")
        check(store.items.filter { $0.seriesID == seriesID }.allSatisfy { $0.isRecurring },
              "every remaining occurrence is still a proper series member")

        print("\n\(checks - failures)/\(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
