import Foundation

/// Covers the arithmetic behind the stats page: time-of-day comparisons,
/// week alignment, and every branch of the headline it writes.
///
/// All of it runs on a fixed UTC calendar and fixed instants, because the
/// whole subject here is "what time is it" and a suite that asked the machine
/// would pass or fail depending on when it ran.
@main
struct StatsTests {
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
        calendar.firstWeekday = 1 // Sunday, the macOS default in the US locale.
        return calendar
    }()

    /// A moment on a fixed Wednesday.
    static func moment(day: Int, hour: Int, minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = 2100
        components.month = 1
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }

    static func session(day: Int, hour: Int, minutes: Double,
                        completed: Bool = true, course: String? = nil) -> FocusRecord {
        FocusRecord(date: moment(day: day, hour: hour), minutes: minutes,
                    completed: completed, course: course)
    }

    static func summary(_ records: [FocusRecord], now: Date, goal: Double = 120,
                        tasksToday: Int = 0, tasksYesterday: Int = 0) -> StatsSummary {
        StatsSummary(records: records, tasksCompletedToday: tasksToday,
                     tasksCompletedYesterday: tasksYesterday,
                     goalMinutes: goal, now: now, calendar: calendar)
    }

    static func main() {
        // 2100-01-08 is a Friday; the week it sits in starts on Sunday the 3rd.
        let today = 8
        let noon = moment(day: today, hour: 12)

        print("\nsaying a length of time")
        equal(StatsSummary.compact(45), "45m", "under an hour is just minutes")
        equal(StatsSummary.compact(60), "1h", "a round hour drops the zero")
        equal(StatsSummary.compact(95), "1h 35m", "and an odd one keeps the rest")
        equal(StatsSummary.compact(0), "0m", "nothing is still said in minutes")

        print("\ntoday against yesterday at the same hour")
        let pace = [
            session(day: today - 1, hour: 9, minutes: 60),   // before noon yesterday
            session(day: today - 1, hour: 20, minutes: 90),  // after noon yesterday
            session(day: today, hour: 10, minutes: 75),      // today, before now
        ]
        var stats = summary(pace, now: noon)
        equal(stats.minutesToday, 75, "today counts only what has happened")
        equal(stats.minutesYesterday, 150, "yesterday's whole day is available")
        equal(stats.minutesYesterdayToDate, 60,
              "but the comparison uses only yesterday up to this hour")
        equal(stats.paceDelta, 15, "so the pace delta is today minus that")

        print("\nthe goal ring")
        equal(stats.goalProgress, 75.0 / 120.0, "progress is the plain ratio")
        equal(stats.remainingToGoal, 45, "and the remainder is what's left")
        check(!stats.goalMet, "75 minutes does not clear a two-hour goal")
        stats = summary(pace + [session(day: today, hour: 11, minutes: 200)], now: noon)
        equal(stats.goalProgress, 1, "a ring never fills past its own start")
        check(stats.goalMet, "an overshoot still counts as met")

        print("\nsubjects today")
        let subjects = [
            session(day: today, hour: 8, minutes: 30, course: "PHYS 122"),
            session(day: today, hour: 9, minutes: 45, course: "CSDS 340"),
            session(day: today, hour: 10, minutes: 20, course: "PHYS 122"),
            session(day: today, hour: 11, minutes: 20, course: nil),
            session(day: today - 1, hour: 11, minutes: 300, course: "CSDS 391"),
        ]
        stats = summary(subjects, now: moment(day: today, hour: 23))
        equal(stats.byCourseToday.count, 3, "only today's subjects, one bar each")
        equal(stats.byCourseToday.first?.course, "PHYS 122", "biggest first")
        equal(stats.byCourseToday.first?.minutes, 50, "with its sessions added up")
        equal(stats.byCourseToday.last?.course, "General", "a session with no task is General")
        check(!stats.byCourseToday.contains { $0.course == "CSDS 391" },
              "yesterday's subject is not on today's chart")

        print("\ntoo many subjects for one chart")
        let many = (1...9).map { CourseMinutes(course: "C\($0)", minutes: Double(100 - $0)) }
        let capped = StatsMath.capped(many, limit: 6)
        equal(capped.count, 6, "the chart is capped")
        equal(capped.last?.course, "Other", "with a single bar for the tail")
        equal(capped.last?.minutes, many.suffix(4).reduce(0) { $0 + $1.minutes },
              "carrying every minute the tail held")
        equal(StatsMath.capped(Array(many.prefix(4)), limit: 6).count, 4,
              "a short list is left exactly as it is")

        print("\nthe last fourteen days")
        stats = summary(pace, now: noon)
        equal(stats.recentDays.count, 14, "one entry per day")
        equal(stats.recentDays.last?.day, calendar.startOfDay(for: noon), "today is last")
        equal(stats.recentDays.first?.minutes, 0, "an empty day is a real zero, not a gap")
        equal(stats.recentDays.filter { $0.minutes > 0 }.count, 2, "two days had work")
        equal(stats.averageActiveDayMinutes, (75 + 150) / 2,
              "the average is over days worked, not over the whole fortnight")

        print("\nthis week against last week, to the same point")
        // Friday noon. This week runs from Sunday the 3rd; last week from the
        // 27th of December, and only up to *its* Friday noon.
        let weeks = [
            session(day: today - 1, hour: 9, minutes: 30),    // Thursday, this week
            session(day: today, hour: 10, minutes: 20),       // Friday morning, this week
            session(day: today, hour: 20, minutes: 999),      // Friday evening — not yet
            session(day: today - 7, hour: 9, minutes: 45),    // last Friday morning
            session(day: today - 7, hour: 20, minutes: 111),  // last Friday evening
            session(day: today - 8, hour: 9, minutes: 25),    // last Thursday
        ]
        stats = summary(weeks, now: noon)
        equal(stats.minutesThisWeekToDate, 50, "this week counts up to right now")
        equal(stats.minutesLastWeekToDate, 70,
              "last week stops at the same hour of the same weekday")

        print("\nfollow-through")
        let mixed = [
            session(day: today, hour: 9, minutes: 60, completed: true),
            session(day: today, hour: 10, minutes: 20, completed: false),
        ]
        stats = summary(mixed, now: noon)
        equal(stats.followThrough, 0.75, "a session given up on costs its minutes")
        equal(stats.sessionsToday, 2, "both sessions are today's")
        equal(stats.finishedSessionsToday, 1, "one of them was seen through")
        equal(summary([], now: noon).followThrough, 1,
              "an empty log opens at full marks, not at zero")

        print("\nthe best day on record")
        stats = summary(weeks, now: noon)
        equal(stats.bestDayMinutes, 1019, "the heaviest day wins")
        equal(stats.bestDayDate, calendar.startOfDay(for: noon), "and is dated")

        print("\nwhat the page says to you")
        var verdict = summary([], now: noon).verdict
        equal(verdict.tone, .idle, "an empty log is not a failure")
        check(verdict.headline.contains("No focus sessions yet"), "and says so plainly")

        verdict = summary([session(day: today - 1, hour: 9, minutes: 90)], now: noon).verdict
        equal(verdict.tone, .behind, "nothing today, with yesterday to compare, is behind")
        check(verdict.detail.contains("1h 30m"), "and names what you'd done by now yesterday",
              verdict.detail)

        // A streak of completed days, none of them today, late enough to warn.
        let streaked = (1...4).map { session(day: today - $0, hour: 9, minutes: 60) }
        stats = summary(streaked, now: moment(day: today, hour: 21))
        equal(stats.streak, 4, "four days in a row")
        check(stats.streakAtRisk, "and nothing yet tonight")
        equal(stats.verdict.tone, .behind, "which is a warning")
        check(stats.verdict.headline.contains("4-day streak"), "naming what's about to be lost",
              stats.verdict.headline)
        check(!summary(streaked, now: moment(day: today, hour: 9)).streakAtRisk,
              "the same day at 9am is not yet a warning")

        // A heavier day already on record, so today clears the goal without
        // also being a personal best — those are two different headlines.
        let withRecord = streaked + [session(day: today - 3, hour: 11, minutes: 300)]
        verdict = summary(withRecord + [session(day: today, hour: 10, minutes: 130)],
                          now: noon).verdict
        equal(verdict.tone, .ahead, "clearing the goal reads as ahead")
        check(verdict.headline.contains("Goal met"), "and says so", verdict.headline)

        verdict = summary([session(day: today, hour: 10, minutes: 400)], now: noon).verdict
        equal(verdict.tone, .ahead, "a record day is ahead too")
        check(verdict.headline.contains("Best day"), "and is called what it is", verdict.headline)

        verdict = summary([session(day: today - 1, hour: 9, minutes: 100),
                           session(day: today, hour: 10, minutes: 20)], now: noon).verdict
        equal(verdict.tone, .behind, "well under yesterday's pace is behind")
        check(verdict.headline.contains("1h 20m behind"), "by the amount it is behind by",
              verdict.headline)

        verdict = summary([session(day: today - 1, hour: 9, minutes: 20),
                           session(day: today, hour: 10, minutes: 22)], now: noon).verdict
        equal(verdict.tone, .onTrack, "a two-minute difference is not news")
        check(verdict.headline.contains("Level"), "so it is called level", verdict.headline)

        print("\n\(checks - failures)/\(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
