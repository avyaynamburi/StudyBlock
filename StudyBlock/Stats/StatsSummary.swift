import Foundation

/// Minutes attributed to one subject.
struct CourseMinutes: Identifiable, Equatable {
    var course: String
    var minutes: Double
    var id: String { course }
}

/// One day on the trend chart.
struct DayTotal: Identifiable, Equatable {
    var day: Date
    var minutes: Double
    /// Whether the day's total cleared the goal *that* is being asked about —
    /// stored rather than recomputed so the chart, the week strip and the
    /// counter can't disagree about what "hit" means.
    var metGoal: Bool
    var id: Date { day }
}

/// How today is going, in the one word that decides the page's colour and the
/// shape of its headline.
enum StatsTone: Equatable {
    /// Goal cleared, or a record broken.
    case ahead
    /// Work is happening and it's keeping up with the recent past.
    case onTrack
    /// Behind yesterday's pace, or a streak about to be lost.
    case behind
    /// Nothing logged and nothing to compare against yet.
    case idle
}

/// The headline under the hero number.
///
/// Kept as data rather than a formatted string built in the view so the tone
/// and the sentence can't drift apart, and so every branch of what is
/// essentially a small argument with the user is covered by a test.
struct StatsVerdict: Equatable {
    var tone: StatsTone
    var headline: String
    /// The second line, when there is something worth adding. Empty is normal.
    var detail: String
}

/// Everything the stats page shows, derived in one pass from the focus log.
///
/// All of it is computed from `[FocusRecord]` plus a clock, with no store and
/// no `@MainActor`, because the interesting part of this page is arithmetic
/// about time-of-day comparisons and that is worth testing directly.
struct StatsSummary: Equatable {
    /// The day's target, in minutes.
    var goalMinutes: Double

    var minutesToday: Double
    /// Yesterday's *whole* day.
    var minutesYesterday: Double
    /// Yesterday up to the same clock time as now. The honest comparison: at
    /// 9am, measuring today against all of yesterday says nothing except that
    /// the day is young.
    var minutesYesterdayToDate: Double

    var sessionsToday: Int
    var finishedSessionsToday: Int
    var tasksToday: Int
    var tasksYesterday: Int

    var byCourseToday: [CourseMinutes]
    /// Oldest first, one entry per day including the empty ones.
    var recentDays: [DayTotal]
    var weekDays: [DayTotal]

    var streak: Int
    /// True when a streak exists, today hasn't contributed to it yet, and the
    /// evening is far enough along that saying so is a warning rather than
    /// nagging at breakfast.
    var streakAtRisk: Bool

    var minutesThisWeekToDate: Double
    var minutesLastWeekToDate: Double

    /// Share of logged minutes that came from sessions actually seen through,
    /// over the trailing window. Abandoning a timer costs you here.
    var followThrough: Double
    var bestDayMinutes: Double
    var bestDayDate: Date?
    var totalHours: Double

    var verdict: StatsVerdict

    /// 0 through 1, clamped — the ring never overfills, because a ring that
    /// wraps past its own start reads as *less* progress, not more.
    var goalProgress: Double {
        guard goalMinutes > 0 else { return minutesToday > 0 ? 1 : 0 }
        return min(1, minutesToday / goalMinutes)
    }

    var goalMet: Bool { minutesToday >= goalMinutes && goalMinutes > 0 }

    /// Minutes still to do. Zero once the goal is met.
    var remainingToGoal: Double { max(0, goalMinutes - minutesToday) }

    /// Today minus yesterday-at-this-hour: the number the headline is about.
    var paceDelta: Double { minutesToday - minutesYesterdayToDate }

    /// Days this week whose total cleared the goal.
    var goalDaysThisWeek: Int { weekDays.filter(\.metGoal).count }

    /// The average over the days that had *any* work in the trailing window.
    /// Dividing by 14 instead would quietly reward a fortnight off with a
    /// lower bar to clear.
    var averageActiveDayMinutes: Double {
        let active = recentDays.filter { $0.minutes > 0 }
        guard !active.isEmpty else { return 0 }
        return active.reduce(0) { $0 + $1.minutes } / Double(active.count)
    }
}

enum StatsMath {
    /// How far into its day a moment is. The whole point of comparing "today
    /// so far" with "yesterday by this time" is this one number.
    static func secondsIntoDay(_ date: Date, calendar: Calendar) -> TimeInterval {
        date.timeIntervalSince(calendar.startOfDay(for: date))
    }

    /// Minutes logged on `day`, optionally only those before `cutoff` seconds
    /// into that day.
    static func minutes(in records: [FocusRecord], on day: Date,
                        before cutoff: TimeInterval? = nil,
                        calendar: Calendar = .current) -> Double {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return 0 }
        let limit = cutoff.map { start.addingTimeInterval($0) } ?? end
        return records
            .filter { $0.date >= start && $0.date < end && $0.date < limit }
            .reduce(0) { $0 + $1.minutes }
    }

    /// Minutes per subject over a half-open range, most first. Sessions
    /// started outside a task have no course and are grouped under "General",
    /// the same name the weekly chart has always used for them.
    static func byCourse(_ records: [FocusRecord], from start: Date, to end: Date) -> [CourseMinutes] {
        let inRange = records.filter { $0.date >= start && $0.date < end }
        let buckets = Dictionary(grouping: inRange) { $0.course ?? "General" }
        return buckets
            .map { CourseMinutes(course: $0.key, minutes: $0.value.reduce(0) { $0 + $1.minutes }) }
            .sorted { ($0.minutes, $1.course) > ($1.minutes, $0.course) }
    }

    /// Keeps the largest `limit` subjects and folds the rest into one bar.
    ///
    /// A chart that grows a new colour per subject stops being readable at
    /// about seven, and the tail is by definition the part you didn't spend
    /// the day on — it belongs in a single "Other" rather than in six slivers.
    static func capped(_ courses: [CourseMinutes], limit: Int = 6,
                       otherLabel: String = "Other") -> [CourseMinutes] {
        guard courses.count > limit else { return courses }
        let head = Array(courses.prefix(limit - 1))
        let tail = courses.dropFirst(limit - 1).reduce(0) { $0 + $1.minutes }
        return head + [CourseMinutes(course: otherLabel, minutes: tail)]
    }

    /// One entry per day for the last `days` days, oldest first, zeroes
    /// included so a gap in the work shows up as a gap in the chart.
    static func dailyTotals(_ records: [FocusRecord], days: Int, goalMinutes: Double,
                            now: Date = Date(), calendar: Calendar = .current) -> [DayTotal] {
        let today = calendar.startOfDay(for: now)
        return (0..<max(0, days)).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let total = minutes(in: records, on: day, calendar: calendar)
            return DayTotal(day: day, minutes: total,
                            metGoal: goalMinutes > 0 && total >= goalMinutes)
        }
    }

    /// The days of the current week so far, starting on the calendar's own
    /// first weekday.
    static func weekToDate(_ records: [FocusRecord], goalMinutes: Double,
                           now: Date = Date(), calendar: Calendar = .current) -> [DayTotal] {
        let today = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: today)
        let elapsed = (weekday - calendar.firstWeekday + 7) % 7
        return dailyTotals(records, days: elapsed + 1, goalMinutes: goalMinutes,
                           now: now, calendar: calendar)
    }

    /// Minutes over the `days` days ending at the same point of the day
    /// `weeksAgo` weeks back — so a Wednesday lunchtime is only ever compared
    /// with a Wednesday lunchtime.
    static func weekToDateMinutes(_ records: [FocusRecord], weeksAgo: Int,
                                  now: Date = Date(), calendar: Calendar = .current) -> Double {
        guard let anchor = calendar.date(byAdding: .day, value: -7 * weeksAgo, to: now) else { return 0 }
        let anchorDay = calendar.startOfDay(for: anchor)
        let weekday = calendar.component(.weekday, from: anchorDay)
        let elapsed = (weekday - calendar.firstWeekday + 7) % 7
        let cutoff = secondsIntoDay(anchor, calendar: calendar)
        return (0...elapsed).reduce(0) { running, offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: anchorDay) else { return running }
            // Only the most recent day is cut off mid-way; the days before it
            // are counted whole.
            let limit: TimeInterval? = offset == 0 ? cutoff : nil
            return running + minutes(in: records, on: day, before: limit, calendar: calendar)
        }
    }

    /// Share of minutes in the window that came from sessions run to the end.
    /// Zero sessions is reported as 1: there is no failure to show yet, and a
    /// fresh install shouldn't open on 0%.
    static func followThrough(_ records: [FocusRecord], since start: Date) -> Double {
        let window = records.filter { $0.date >= start }
        let total = window.reduce(0) { $0 + $1.minutes }
        guard total > 0 else { return 1 }
        return window.filter(\.completed).reduce(0) { $0 + $1.minutes } / total
    }

    /// The heaviest single day on record.
    static func bestDay(_ records: [FocusRecord], calendar: Calendar = .current) -> (day: Date, minutes: Double)? {
        let totals = Dictionary(grouping: records) { calendar.startOfDay(for: $0.date) }
            .mapValues { $0.reduce(0) { $0 + $1.minutes } }
        guard let best = totals.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) else { return nil }
        return (best.key, best.value)
    }
}

extension StatsSummary {
    /// How much of the evening has to be gone before an unfinished day is
    /// called out as a streak at risk. 5pm is early enough to act on and late
    /// enough not to be a lecture over breakfast.
    static let streakWarningHour = 17

    /// Days of history the trend chart and the averages look at.
    static let trailingDays = 14

    init(records: [FocusRecord], tasksCompletedToday: Int = 0, tasksCompletedYesterday: Int = 0,
         goalMinutes: Double, now: Date = Date(), calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let cutoff = StatsMath.secondsIntoDay(now, calendar: calendar)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? now

        self.goalMinutes = goalMinutes
        minutesToday = StatsMath.minutes(in: records, on: today, calendar: calendar)
        minutesYesterday = StatsMath.minutes(in: records, on: yesterday, calendar: calendar)
        minutesYesterdayToDate = StatsMath.minutes(in: records, on: yesterday,
                                                   before: cutoff, calendar: calendar)

        let todays = records.filter { $0.date >= today && $0.date < tomorrow }
        sessionsToday = todays.count
        finishedSessionsToday = todays.filter(\.completed).count
        tasksToday = tasksCompletedToday
        tasksYesterday = tasksCompletedYesterday

        byCourseToday = StatsMath.capped(StatsMath.byCourse(records, from: today, to: tomorrow))
        recentDays = StatsMath.dailyTotals(records, days: Self.trailingDays,
                                           goalMinutes: goalMinutes, now: now, calendar: calendar)
        weekDays = StatsMath.weekToDate(records, goalMinutes: goalMinutes,
                                        now: now, calendar: calendar)

        streak = StatsStore.streak(recordDates: records.filter(\.completed).map(\.date),
                                   calendar: calendar, today: now)
        let workedToday = todays.contains(where: \.completed)
        streakAtRisk = streak > 0 && !workedToday
            && calendar.component(.hour, from: now) >= Self.streakWarningHour

        minutesThisWeekToDate = StatsMath.weekToDateMinutes(records, weeksAgo: 0,
                                                            now: now, calendar: calendar)
        minutesLastWeekToDate = StatsMath.weekToDateMinutes(records, weeksAgo: 1,
                                                            now: now, calendar: calendar)

        let windowStart = calendar.date(byAdding: .day, value: -Self.trailingDays, to: today) ?? today
        followThrough = StatsMath.followThrough(records, since: windowStart)

        let best = StatsMath.bestDay(records, calendar: calendar)
        bestDayMinutes = best?.minutes ?? 0
        bestDayDate = best?.day
        totalHours = records.reduce(0) { $0 + $1.minutes } / 60

        verdict = Self.verdict(minutesToday: minutesToday,
                               minutesYesterdayToDate: minutesYesterdayToDate,
                               minutesYesterday: minutesYesterday,
                               goalMinutes: goalMinutes,
                               bestDayMinutes: bestDayMinutes,
                               isBestDayToday: best.map { calendar.isDate($0.day, inSameDayAs: now) } ?? false,
                               streak: streak,
                               streakAtRisk: streakAtRisk,
                               hasHistory: !records.isEmpty)
    }

    /// Below this, a difference between two days is noise and saying it out
    /// loud makes the page look obsessive.
    private static let meaningfulGap: Double = 5

    // swiftlint:disable:next function_parameter_count
    static func verdict(minutesToday: Double, minutesYesterdayToDate: Double,
                        minutesYesterday: Double, goalMinutes: Double,
                        bestDayMinutes: Double, isBestDayToday: Bool,
                        streak: Int, streakAtRisk: Bool, hasHistory: Bool) -> StatsVerdict {
        let delta = minutesToday - minutesYesterdayToDate
        let remaining = max(0, goalMinutes - minutesToday)

        // Nothing to stand on yet. Anything comparative here would be
        // comparing a new install with itself.
        guard hasHistory else {
            return StatsVerdict(tone: .idle, headline: "No focus sessions yet.",
                                detail: "One 25-minute block starts a streak.")
        }

        if minutesToday <= 0 {
            if streakAtRisk {
                return StatsVerdict(
                    tone: .behind,
                    headline: "Your \(streak)-day streak ends at midnight.",
                    detail: "One finished session tonight is all it takes to keep it.")
            }
            if minutesYesterdayToDate >= Self.meaningfulGap {
                return StatsVerdict(
                    tone: .behind,
                    headline: "Nothing logged yet today.",
                    detail: "By this time yesterday you'd done \(compact(minutesYesterdayToDate)).")
            }
            return StatsVerdict(tone: .idle, headline: "Nothing logged yet today.",
                                detail: "Goal is \(compact(goalMinutes)).")
        }

        if goalMinutes > 0, minutesToday >= goalMinutes {
            if isBestDayToday, bestDayMinutes > 0 {
                return StatsVerdict(tone: .ahead, headline: "Best day you've ever logged.",
                                    detail: "\(compact(minutesToday)) focused. Nothing else comes close.")
            }
            if delta >= Self.meaningfulGap {
                return StatsVerdict(tone: .ahead, headline: "Goal met, and ahead of yesterday.",
                                    detail: "\(compact(delta)) more than you'd done by this time.")
            }
            return StatsVerdict(tone: .ahead, headline: "Goal met.",
                                detail: "\(compact(minutesToday)) focused today.")
        }

        let goalLine = remaining > 0 ? "\(compact(remaining)) to go." : ""
        if delta >= Self.meaningfulGap {
            return StatsVerdict(tone: .onTrack,
                                headline: "\(compact(delta)) ahead of yesterday's pace.",
                                detail: goalLine)
        }
        if delta <= -Self.meaningfulGap {
            return StatsVerdict(tone: .behind,
                                headline: "\(compact(-delta)) behind yesterday's pace.",
                                detail: goalLine)
        }
        return StatsVerdict(tone: .onTrack, headline: "Level with yesterday.", detail: goalLine)
    }

    /// "1h 20m", "45m" — the one place minutes become words, so the headline
    /// and the chart labels can never disagree about how to say the same
    /// length of time.
    static func compact(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        guard total >= 60 else { return "\(total)m" }
        let hours = total / 60
        let rest = total % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }
}
