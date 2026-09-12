import Foundation

/// Standalone checks for the Canvas pipeline. Compiled against the parsing
/// and normalizing sources only — no SwiftUI, no app, no network, no
/// credential — which is the point of keeping those two files pure.
///
///     swiftc -parse-as-library -o /tmp/canvastests \
///         StudyBlock/Canvas/ICSParser.swift StudyBlock/Canvas/CanvasItem.swift \
///         Tests/CanvasTests.swift && /tmp/canvastests
@main
struct CanvasTests {
    static var failures = 0
    static var checks = 0

    static func check(_ condition: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
        checks += 1
        if condition {
            print("  ok   \(label)")
        } else {
            failures += 1
            let extra = detail()
            print("  FAIL \(label)" + (extra.isEmpty ? "" : "\n         \(extra)"))
        }
    }

    static func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        check(actual == expected, label, "expected \(expected), got \(actual)")
    }

    /// A fixed zone well west of UTC — the one where a mishandled all-day
    /// date visibly slides to the previous day.
    static let newYork: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    static func main() {
        let path = "Tests/canvas-sample.ics"
        guard let data = FileManager.default.contents(atPath: path) else {
            print("cannot read \(path) — run from the repo root")
            exit(2)
        }

        let events = ICSParser.events(from: data)
        let items = CanvasNormalizer.normalize(events)

        print("\nparsing")
        equal(events.count, 8, "every VEVENT is parsed, CRLF and all")

        let folded = items.first { $0.course == "HIST 101" }
        check(folded != nil, "folded line is rejoined (course reads HIST 101, not HIST 10)",
              "courses seen: \(items.compactMap(\.course))")
        equal(folded?.title, "Essay on the Reformation, draft one; with sources",
              "escaped comma and semicolon are unescaped")

        let lab = items.first { $0.course == "CHEM 101" }
        equal(lab?.title, "Lab 3 [revised] handout",
              "course regex is end-anchored, so a middle bracket survives")

        print("\nclassification")
        let readingDay = items.first { $0.title == "Reading Day" }
        equal(readingDay?.kind, .event, "calendar?event_id URL classifies as an event")
        check(readingDay?.startsAt != nil && readingDay?.dueAt == nil,
              "an event fills startsAt and never dueAt")
        let problemSet = items.first { $0.title == "Problem Set 5" }
        equal(problemSet?.kind, .assignment, "/assignments/ URL classifies as an assignment")
        check(problemSet?.dueAt != nil && problemSet?.startsAt == nil,
              "an assignment fills dueAt and never startsAt")
        let quiz = items.first { $0.title == "Quiz 2" }
        equal(quiz?.kind, .assignment, "a missing UID still classifies from the URL")
        equal(quiz?.sourceID, "https://canvas.case.edu/courses/4/assignments/4",
              "identity falls back to the URL when there is no UID")

        print("\ndropped, not defaulted")
        equal(items.count, 7, "the event with no DTSTART is dropped, not given a date")
        check(!items.contains { $0.title == "Undated placeholder" },
              "the undated entry is genuinely absent")

        print("\nall-day handling")
        equal(readingDay?.startsAt, .day(year: 2099, month: 12, day: 15),
              "VALUE=DATE parses as a calendar day, not an instant")
        if case .day = readingDay?.startsAt {} else { check(false, "all-day stays a .day case") }

        let readingLocal = CanvasNormalizer.localDueDate(readingDay!.startsAt!, calendar: newYork)!
        let parts = newYork.dateComponents([.year, .month, .day, .hour], from: readingLocal)
        equal(parts.day, 15, "all-day date does NOT slide to the 14th in America/New_York")
        equal(parts.month, 12, "all-day month is unchanged")
        equal(parts.hour, 0, "all-day lands at local midnight")

        let portfolio = items.first { $0.title == "Portfolio upload" }
        let portfolioLocal = CanvasNormalizer.localDueDate(portfolio!.dueAt!, calendar: newYork)!
        let portfolioParts = newYork.dateComponents([.day, .hour, .minute], from: portfolioLocal)
        equal(portfolioParts.day, 20, "all-day ASSIGNMENT keeps its date")
        check(portfolioParts.hour == 0 && portfolioParts.minute == 0,
              "no clock time is fabricated for a date-only assignment",
              "got \(portfolioParts.hour ?? -1):\(portfolioParts.minute ?? -1)")

        print("\ntimed instants")
        let due = CanvasNormalizer.localDueDate(problemSet!.dueAt!, calendar: newYork)!
        let dueParts = newYork.dateComponents([.month, .day, .hour, .minute], from: due)
        check(dueParts.month == 12 && dueParts.day == 1
              && dueParts.hour == 18 && dueParts.minute == 59,
              "23:59Z renders as 18:59 local on Dec 1 in New York",
              "got \(dueParts.month ?? 0)/\(dueParts.day ?? 0) \(dueParts.hour ?? 0):\(dueParts.minute ?? 0)")

        print("\nimport window")
        let farFuture = newYork.date(from: DateComponents(year: 2099, month: 1, day: 1))!
        let future = CanvasNormalizer.recentOrUpcoming(items, now: farFuture, calendar: newYork)
        check(!future.contains { $0.title == "Ancient homework" },
              "an assignment due in 2020 is far outside the window")
        equal(future.count, 6, "everything else is in")

        // The morning of Reading Day, after midnight UTC has already passed.
        let thatMorning = newYork.date(from: DateComponents(
            year: 2099, month: 12, day: 15, hour: 8))!
        let stillThere = CanvasNormalizer.recentOrUpcoming(items, now: thatMorning, calendar: newYork)
        check(stillThere.contains { $0.title == "Reading Day" },
              "all-day item survives the morning it matters (no premature expiry)")

        print("\noverdue work is kept, not dropped")
        // Problem Set 5 is due Dec 1; two weeks later it is overdue but very
        // much still something you owe.
        check(stillThere.contains { $0.title == "Problem Set 5" },
              "an assignment two weeks overdue is still imported")
        let longAfter = newYork.date(from: DateComponents(year: 2100, month: 2, day: 1))!
        let stale = CanvasNormalizer.recentOrUpcoming(items, now: longAfter, calendar: newYork)
        check(!stale.contains { $0.title == "Problem Set 5" },
              "but two months overdue is outside the 30-day window")

        print("\nthe window boundary, to the day")
        // Reading Day is an all-day entry on Dec 15: exactly 30 days later it
        // is the oldest thing still in, and a day after that it is out.
        let day30 = newYork.date(from: DateComponents(year: 2100, month: 1, day: 14, hour: 9))!
        let day31 = newYork.date(from: DateComponents(year: 2100, month: 1, day: 15, hour: 9))!
        check(CanvasNormalizer.recentOrUpcoming(items, now: day30, calendar: newYork)
                .contains { $0.title == "Reading Day" },
              "an all-day item exactly 30 days old is still in")
        check(!CanvasNormalizer.recentOrUpcoming(items, now: day31, calendar: newYork)
                .contains { $0.title == "Reading Day" },
              "31 days old is out")
        check(CanvasNormalizer.recentOrUpcoming(items, now: thatMorning, lookbackDays: 0,
                                                calendar: newYork)
                .contains { $0.title == "Reading Day" },
              "with no lookback at all, today's all-day item is still kept")

        print("\ncontent hash")
        let a = items.first { $0.title == "Problem Set 5" }!
        var b = a
        equal(a.contentHash, b.contentHash, "same content hashes the same")
        b.dueAt = .instant(Date(timeIntervalSince1970: 4102444800))
        check(a.contentHash != b.contentHash,
              "a moved deadline changes the hash, so it resurfaces as changed")
        var c = a
        c.title = "Problem Set 5 (revised)"
        check(a.contentHash != c.contentHash, "a retitled assignment changes the hash")
        // Printed so a second process run can be diffed against this one:
        // Swift's built-in Hasher is seeded per process and would differ here.
        print("  hash(Problem Set 5) = \(a.contentHash)")

        print("\ncourse")
        equal(problemSet?.course, "PHYS 221",
              "the bracketed course is kept as its own field, to tag the task with")
        equal(problemSet?.title, "Problem Set 5", "and is off the title")
        equal(readingDay?.course, nil, "an entry with no course has none to tag with")

        print("\n\(checks - failures)/\(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
