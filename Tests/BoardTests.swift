import Foundation

/// Covers how the board groups finished work, and how it takes a task back
/// from a focus session.
@main
struct BoardTests {
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

    static var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 1
        return calendar
    }()

    static func moment(day: Int, hour: Int = 12) -> Date {
        var components = DateComponents()
        components.year = 2100
        components.month = 1
        components.day = day
        components.hour = hour
        return calendar.date(from: components)!
    }

    static func done(_ title: String, at date: Date?) -> TodoItem {
        var task = TodoItem(title: title)
        task.isCompleted = true
        task.completedAt = date
        task.column = .completed
        return task
    }

    @MainActor
    static func main() {
        guard NSHomeDirectory().contains("board-sandbox") else {
            print("refusing to run outside the sandbox HOME — got \(NSHomeDirectory())")
            exit(2)
        }

        // Friday 2100-01-08. The week it sits in began on Sunday the 3rd.
        let now = moment(day: 8, hour: 14)

        print("\nwhich section a finished task falls in")
        func section(_ date: Date?) -> CompletedSection {
            CompletedSections.section(for: date, now: now, calendar: calendar)
        }
        equal(section(moment(day: 8, hour: 9)), .today, "earlier today is still today")
        equal(section(moment(day: 8, hour: 23)), .today, "so is later today")
        equal(section(moment(day: 7)), .week, "yesterday is this week")
        equal(section(moment(day: 3)), .week, "and so is the day the week started")
        equal(section(moment(day: 2)), .earlier, "the day before that is not")
        equal(section(moment(day: 1)), .earlier, "nor is anything older")
        equal(section(nil), .earlier, "a task with no completion date is old news")

        print("\ncutting the column up")
        let column = [
            done("Finished this morning", at: moment(day: 8, hour: 9)),
            done("Finished Tuesday", at: moment(day: 5)),
            done("Finished last month", at: moment(day: 1)),
            done("Finished at lunch", at: moment(day: 8, hour: 13)),
            done("Imported", at: nil),
        ]
        let groups = CompletedSections.split(column, now: now, calendar: calendar)
        equal(groups.count, 3, "three sections in this column")
        equal(groups.map(\.section), [.today, .week, .earlier], "in that order, newest first")
        equal(groups[0].tasks.count, 2, "both of today's land under Today")
        equal(groups[0].tasks.first?.title, "Finished this morning",
              "and keep the order the column handed them over in")
        equal(groups[1].tasks.count, 1, "this week's one card")
        equal(groups[2].tasks.count, 2, "the old one and the undated one are both Earlier")
        equal(groups.map(\.tasks).joined().count, column.count, "no card is lost between sections")

        print("\na column with only today's work")
        let todayOnly = CompletedSections.split([column[0]], now: now, calendar: calendar)
        equal(todayOnly.count, 1, "empty sections get no heading at all")
        equal(todayOnly.first?.section, .today, "just the one that has something in it")
        equal(CompletedSections.split([], now: now, calendar: calendar).count, 0,
              "and an empty column has no headings either")

        print("\ngiving a task back after a session")
        let store = TaskStore()
        let task = store.addWorkingOn(title: "Lab writeup")!
        equal(task.column, .doing, "a session takes its task into Currently Doing")
        store.restorePlacement(task.id, to: .upcoming, manual: false)
        var back = store.items.first { $0.id == task.id }
        equal(back?.column, .upcoming, "and puts it back where it came from")
        equal(back?.columnIsManual, false,
              "including whether the user had placed it there, so it can still be promoted")

        print("\na task finished during its own session")
        store.move(task.id, to: .completed)
        store.restorePlacement(task.id, to: .upcoming, manual: false)
        back = store.items.first { $0.id == task.id }
        equal(back?.isCompleted, true, "stays completed — the session doesn't undo that")
        equal(back?.column, .completed, "and stays in the Completed column")

        print("\n\(checks - failures)/\(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
