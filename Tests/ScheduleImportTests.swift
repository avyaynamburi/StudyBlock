import Foundation

/// Checks the calendar-to-block-window conversion. Run with
/// `TZ=America/New_York` so the fixture's wall-clock times and the assertions
/// agree regardless of the machine's own zone.
@main
struct ScheduleImportTests {
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

    static func main() {
        guard TimeZone.current.identifier == "America/New_York" else {
            print("run with TZ=America/New_York — got \(TimeZone.current.identifier)")
            exit(2)
        }
        guard let data = FileManager.default.contents(atPath: "Tests/timetable-sample.ics") else {
            print("cannot read Tests/timetable-sample.ics — run from the repo root")
            exit(2)
        }

        let outcome = ScheduleICSImport.read(data)
        let byName = Dictionary(uniqueKeysWithValues: outcome.candidates.map { ($0.name, $0) })

        print("\nweekly rules")
        let phys = byName["PHYS 221 Lecture"]
        equal(phys?.weekdays, [2, 4, 6], "BYDAY=MO,WE,FR becomes Mon/Wed/Fri")
        equal(phys?.startMinute, 9 * 60, "start is 09:00 local")
        equal(phys?.endMinute, 9 * 60 + 50, "end is 09:50 local")
        equal(phys?.fromRecurrenceRule, true, "flagged as genuinely recurring")

        let math = byName["MATH 201 Recitation"]
        equal(math?.weekdays, [3], "a weekly rule with no BYDAY uses DTSTART's weekday (Tue)")

        print("\nDURATION instead of DTEND")
        let chem = byName["CHEM 105 Seminar"]
        equal(chem?.startMinute, 13 * 60, "start is 13:00")
        equal(chem?.endMinute, 14 * 60 + 30, "PT1H30M gives a 14:30 end")
        equal(chem?.weekdays, [5], "BYDAY=TH is Thursday")

        print("\nfolding separately-listed entries")
        let lab = byName["CHEM 105 Lab"]
        equal(lab?.weekdays, [3, 5], "three one-off entries fold into Tue + Thu")
        equal(lab?.mergedCount, 3, "and remember how many they were")
        equal(lab?.fromRecurrenceRule, false, "flagged as inferred, not declared")
        equal(outcome.candidates.filter { $0.name == "CHEM 105 Lab" }.count, 1,
              "they become one window, not three")

        print("\ndaily and overnight")
        equal(byName["Morning Study"]?.weekdays, Set(1...7), "FREQ=DAILY is every day")
        let night = byName["Night Shift"]
        equal(night?.startMinute, 22 * 60, "overnight window starts at 22:00")
        equal(night?.endMinute, 2 * 60, "and ends at 02:00")
        check((night?.endMinute ?? 0) < (night?.startMinute ?? 0),
              "end before start is how BlockSchedule encodes overnight")
        let schedule = night!.schedule(groupIDs: [])
        let friday11pm = Calendar.current.date(from: DateComponents(
            year: 2026, month: 9, day: 4, hour: 23))!
        let saturday1am = Calendar.current.date(from: DateComponents(
            year: 2026, month: 9, day: 5, hour: 1))!
        let saturday3am = Calendar.current.date(from: DateComponents(
            year: 2026, month: 9, day: 5, hour: 3))!
        check(schedule.isActive(at: friday11pm), "the window is open Friday 23:00")
        check(schedule.isActive(at: saturday1am), "still open after midnight")
        check(!schedule.isActive(at: saturday3am), "closed again by 03:00")

        print("\nwhat gets left out")
        equal(outcome.skippedAllDay, 1, "the all-day holiday is skipped")
        equal(outcome.skippedNoEnd, 1, "the entry with no end time is skipped")
        equal(outcome.skippedTooLong, 1, "the multi-day break is skipped")
        check(!outcome.skippedSummary.isEmpty, "and all of it is reported")
        check(byName["Labor Day"] == nil && byName["Fall Break"] == nil
              && byName["Advising drop-in"] == nil, "none of them reached the board")

        print("\ntimezone conversion")
        // The same file read by someone sitting in Chicago: a 9am New York
        // class is an 8am block for them.
        var chicago = Calendar(identifier: .gregorian)
        chicago.timeZone = TimeZone(identifier: "America/Chicago")!
        let elsewhere = ScheduleICSImport.candidates(
            from: ICSParser.events(from: data), calendar: chicago)
        let physThere = elsewhere.candidates.first { $0.name == "PHYS 221 Lecture" }
        equal(physThere?.startMinute, 8 * 60, "TZID is honoured, not assumed to be local")
        equal(physThere?.weekdays, [2, 4, 6], "and the weekdays are unchanged")

        print("\nshape of the result")
        equal(outcome.candidates.count, 6, "six windows from eleven calendar entries")
        let starts = outcome.candidates.map(\.startMinute)
        equal(starts, starts.sorted(), "listed in time order")

        print("\n\(checks - failures)/\(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
