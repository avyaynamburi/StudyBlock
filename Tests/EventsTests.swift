import Foundation

/// Covers the Events page: the month grid, day arithmetic across timezones,
/// countdowns, quick add, and the store that keeps exams on disk.
@main
struct EventsTests {
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

    static func events(firstWeekday: Int, zone: String = "UTC") -> EventCalendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.firstWeekday = firstWeekday
        return EventCalendar(calendar: calendar)
    }

    static func d(_ year: Int, _ month: Int, _ day: Int) -> CalendarDay {
        CalendarDay(year: year, month: month, day: day)
    }

    static func exam(_ title: String, _ day: CalendarDay, _ course: String? = nil) -> StudyEvent {
        StudyEvent(title: title, course: course, day: day)
    }

    @MainActor
    static func main() {
        guard NSHomeDirectory().contains("events-sandbox") else {
            print("refusing to run outside the sandbox HOME — got \(NSHomeDirectory())")
            exit(2)
        }

        let sunday = events(firstWeekday: 1)
        let monday = events(firstWeekday: 2)

        print("\nthe month grid")
        // September 2026 starts on a Tuesday.
        let september = sunday.weeks(in: CalendarMonth(year: 2026, month: 9))
        equal(september.first?.first, d(2026, 8, 30), "Sunday-first grid opens on the Sunday before the 1st")
        equal(september.count, 5, "September 2026 needs five rows starting Sunday")
        check(september.allSatisfy { $0.count == 7 }, "every row is a whole week")
        equal(september.last?.last, d(2026, 10, 3), "and closes on the Saturday after the 30th")
        let septemberMonday = monday.weeks(in: CalendarMonth(year: 2026, month: 9))
        equal(septemberMonday.first?.first, d(2026, 8, 31), "Monday-first grid opens on the Monday before")
        equal(septemberMonday.last?.last, d(2026, 10, 4), "and closes on a Sunday")
        let flat = september.flatMap { $0 }
        check(zip(flat, flat.dropFirst()).allSatisfy { sunday.days(from: $0, to: $1) == 1 },
              "the days run consecutively with no gaps or repeats")

        // February 2026 starts on a Sunday and has 28 days.
        equal(sunday.weeks(in: CalendarMonth(year: 2026, month: 2)).count, 4,
              "a February that starts on the first weekday fits in four rows")
        equal(sunday.weeks(in: CalendarMonth(year: 2026, month: 2)).first?.first, d(2026, 2, 1),
              "and opens on the 1st itself")
        equal(monday.weeks(in: CalendarMonth(year: 2026, month: 2)).count, 5,
              "the same month needs five rows starting Monday")
        // August 2026 starts on a Saturday and has 31 days.
        equal(sunday.weeks(in: CalendarMonth(year: 2026, month: 8)).count, 6, "a late-starting long month needs six rows")
        equal(sunday.weeks(in: CalendarMonth(year: 2028, month: 2)).last?.first, d(2028, 2, 27),
              "a leap February includes the 29th")

        print("\nweekday headers follow the first weekday")
        equal(sunday.weekdaySymbols.first, "Sun", "Sunday first")
        equal(monday.weekdaySymbols, ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"], "Monday first, Sunday last")

        print("\nmoving between months")
        equal(CalendarMonth(year: 2026, month: 12).adding(months: 1), CalendarMonth(year: 2027, month: 1), "December → January")
        equal(CalendarMonth(year: 2027, month: 1).adding(months: -1), CalendarMonth(year: 2026, month: 12), "January → December")
        equal(CalendarMonth(year: 2026, month: 9).adding(months: 13), CalendarMonth(year: 2027, month: 10), "thirteen months on")
        equal(CalendarMonth(year: 2026, month: 3).adding(months: -27), CalendarMonth(year: 2023, month: 12), "27 months back")

        print("\ndays don't drift with timezone or DST")
        let newYork = events(firstWeekday: 1, zone: "America/New_York")
        // 03:30 UTC on 9 March is still the evening of the 8th in New York.
        let lateEvening = Date(timeIntervalSince1970: 1_773_027_000)
        equal(newYork.day(of: lateEvening), d(2026, 3, 8), "'today' is the local day, not the UTC one")
        equal(newYork.days(from: d(2026, 3, 7), to: d(2026, 3, 9)), 2, "a 23-hour day still counts as one")
        equal(newYork.days(from: d(2026, 10, 31), to: d(2026, 11, 2)), 2, "so does a 25-hour one")
        equal(newYork.days(from: d(2026, 12, 25), to: d(2026, 12, 20)), -5, "earlier days count negative")
        equal(newYork.adding(1, to: d(2026, 12, 31)), d(2027, 1, 1), "adding a day crosses the year")
        // São Paulo once started DST at midnight, so 4 Nov 2018 had no 00:00.
        let saoPaulo = events(firstWeekday: 1, zone: "America/Sao_Paulo")
        equal(saoPaulo.day(of: saoPaulo.date(of: d(2018, 11, 4))), d(2018, 11, 4),
              "a day with no midnight still converts to itself")
        let tokyo = events(firstWeekday: 1, zone: "Asia/Tokyo")
        equal(newYork.day(of: newYork.date(of: d(2026, 10, 14))), d(2026, 10, 14), "round trip in New York")
        equal(tokyo.day(of: tokyo.date(of: d(2026, 10, 14))), d(2026, 10, 14), "round trip in Tokyo")

        print("\ncountdowns")
        let today = d(2026, 9, 16)
        equal(sunday.countdown(to: today, from: today), "Today", "today")
        equal(sunday.countdown(to: d(2026, 9, 17), from: today), "Tomorrow", "tomorrow")
        equal(sunday.countdown(to: d(2026, 10, 14), from: today), "In 28 days", "weeks away counts days")
        equal(sunday.countdown(to: d(2026, 9, 15), from: today), "Yesterday", "yesterday")
        equal(sunday.countdown(to: d(2026, 9, 10), from: today), "6 days ago", "days ago")
        equal(sunday.urgency(of: today, from: today), .imminent, "today is imminent")
        equal(sunday.urgency(of: d(2026, 9, 18), from: today), .imminent, "two days out is imminent")
        equal(sunday.urgency(of: d(2026, 9, 19), from: today), .soon, "three days out is soon")
        equal(sunday.urgency(of: d(2026, 9, 23), from: today), .soon, "a week out is soon")
        equal(sunday.urgency(of: d(2026, 9, 24), from: today), .later, "eight days out is later")
        equal(sunday.urgency(of: d(2026, 9, 15), from: today), .later, "a past exam isn't urgent")

        print("\nwhat's coming up")
        let past = exam("Past quiz", d(2026, 9, 15))
        let physics = exam("physics final", d(2026, 12, 10))
        let chemToday = exam("Chem quiz", today)
        let bio = exam("Bio midterm", d(2026, 10, 2))
        let algebra = exam("Algebra midterm", d(2026, 10, 2))
        let all = [past, physics, chemToday, bio, algebra]
        equal(EventCalendar.upcoming(all, from: today).map(\.title),
              ["Chem quiz", "Algebra midterm", "Bio midterm", "physics final"],
              "past exams drop out, today's stays, same-day exams sort by name")
        equal(EventCalendar.byDay(all)[d(2026, 10, 2)]?.map(\.title), ["Algebra midterm", "Bio midterm"],
              "a day lists its exams in name order")
        check(EventCalendar.byDay(all)[d(2026, 10, 3)] == nil, "an empty day has no entry")
        equal(sunday.headline(for: all, today: today), "Next: Chem quiz, today \u{00B7} 3 more after it",
              "the headline names the next exam")
        equal(sunday.headline(for: [physics], today: today), "Next: physics final, in 85 days",
              "a lone exam has no 'more after it'")
        equal(sunday.headline(for: [past], today: today), "No exams coming up", "only past exams means none coming up")

        print("\nquick add")
        let local = EventCalendar.current
        let selected = d(2031, 5, 20)
        let undated = local.quickAdd("history final #hist", course: nil, selectedDay: selected, knownCourses: [])
        equal(undated?.title, "history final", "the title keeps what isn't a tag or a date")
        equal(undated?.course, "hist", "the tag becomes the category")
        equal(undated?.day, selected, "no date typed puts the exam on the selected day")
        let dated = local.quickAdd("chem final october 14 2030", course: nil, selectedDay: selected, knownCourses: [])
        equal(dated?.day, d(2030, 10, 14), "a typed date wins over the selected day")
        equal(dated?.title, "chem final", "and is taken out of the title")
        let friday = local.quickAdd("physics friday", course: nil, selectedDay: selected, knownCourses: [])
        let fridayDate = friday.map { local.date(of: $0.day) }
        equal(fridayDate.map { local.calendar.component(.weekday, from: $0) }, 6, "a weekday name lands on that weekday")
        check((friday?.day ?? selected) >= local.today(), "and never in the past")
        equal(local.quickAdd("bio test #CHEM", course: nil, selectedDay: selected, knownCourses: ["Biology", "Chem"])?.course,
              "Chem", "a tag matching a known category apart from case takes its spelling")
        equal(local.quickAdd("bio test #bio", course: nil, selectedDay: selected, knownCourses: ["Biology"])?.course,
              "bio", "a tag that only partly matches stays as typed")
        equal(local.quickAdd("bio test", course: "Biology", selectedDay: selected, knownCourses: [])?.course,
              "Biology", "the picked category applies when nothing is tagged")
        equal(local.quickAdd("bio test #lab", course: "Biology", selectedDay: selected, knownCourses: [])?.course,
              "lab", "a typed tag beats the picked category")
        check(local.quickAdd("   ", course: "Biology", selectedDay: selected, knownCourses: []) == nil,
              "blank input adds nothing")

        print("\nthe store")
        let store = EventStore()
        equal(store.events.count, 0, "a fresh sandbox starts empty")
        check(!store.add(exam("   ", today)), "a blank title is refused")
        check(store.add(exam("  Calc midterm  ", d(2026, 10, 7), "Math")), "a real exam is added")
        check(store.add(exam("Chem quiz", d(2026, 10, 12), "Chem")), "a second one too")
        equal(store.events.map(\.title), ["Calc midterm", "Chem quiz"], "titles are trimmed")
        equal(store.courses, ["Chem", "Math"], "categories are listed once, sorted")

        var moved = store.events[0]
        moved.day = d(2026, 10, 9)
        moved.title = "Calc midterm 1"
        store.update(moved)
        equal(store.events[0].day, d(2026, 10, 9), "an edit moves the exam")
        equal(store.events[0].title, "Calc midterm 1", "and renames it")
        var blanked = store.events[0]
        blanked.title = "  "
        store.update(blanked)
        equal(store.events[0].title, "Calc midterm 1", "an edit can't blank the title")

        let reloaded = EventStore()
        equal(reloaded.events, store.events, "exams survive a relaunch")
        let onDisk = (try? String(contentsOf: JSONStore.directory.appendingPathComponent("events.json"))) ?? ""
        check(onDisk.contains("\"month\" : 10") && !onDisk.contains("T00:00"),
              "the file stores a plain day, not a moment", onDisk)

        store.delete(store.events[1].id)
        equal(store.events.map(\.title), ["Calc midterm 1"], "delete removes only that exam")
        equal(EventStore().events.count, 1, "and the deletion is saved")

        print("\nexam categories get their own colour")
        let tasks = TaskStore()
        tasks.setHue(Theme.categoryHue(index: 0), for: "Math")
        tasks.claimHue(for: "Chem")
        let chemHue = tasks.courseHues["Chem"]
        check(chemHue != nil, "a category used only by exams gets a hue")
        check(chemHue != tasks.courseHues["Math"], "and not one already taken")
        tasks.claimHue(for: "Math")
        equal(tasks.courseHues["Math"], Theme.categoryHue(index: 0), "claiming never overwrites a chosen hue")
        tasks.claimHue(for: "Chem")
        equal(tasks.courseHues["Chem"], chemHue, "claiming twice changes nothing")

        print("\n\(checks - failures)/\(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
