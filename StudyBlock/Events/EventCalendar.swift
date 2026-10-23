import Foundation

/// Every decision the Events page makes about dates: which days fill a
/// month's grid, how far away an exam is, what the quick-add box means.
///
/// The page itself only lays these out. Timezone and first weekday come in
/// through `calendar`, so tests can pin both.
struct EventCalendar {
    /// Gregorian, because `CalendarDay` is, and in the Mac's timezone, since
    /// "today" is the one question that depends on where you are.
    let calendar: Calendar

    /// Day arithmetic runs in UTC, where every day is 24 hours long. Counting
    /// days in local time would come up short across a DST change.
    private let utc: Calendar

    init(calendar: Calendar) {
        self.calendar = calendar
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        utc.firstWeekday = calendar.firstWeekday
        self.utc = utc
    }

    /// The Mac's own settings. Read afresh each time rather than cached, so
    /// changing the first day of the week in System Settings reaches a
    /// window that is already open.
    static var current: EventCalendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .autoupdatingCurrent
        calendar.timeZone = .autoupdatingCurrent
        // After the locale, which would otherwise reset it to the region's
        // default and ignore a first weekday chosen by hand.
        calendar.firstWeekday = Calendar.autoupdatingCurrent.firstWeekday
        return EventCalendar(calendar: calendar)
    }

    // MARK: - Converting

    func day(of date: Date) -> CalendarDay {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return CalendarDay(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// Local midnight on `day` — for the date picker and for formatting,
    /// never for arithmetic.
    func date(of day: CalendarDay) -> Date {
        calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) ?? .distantPast
    }

    func today(now: Date = .now) -> CalendarDay {
        day(of: now)
    }

    // MARK: - Arithmetic

    private func utcDate(_ day: CalendarDay) -> Date {
        utc.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) ?? .distantPast
    }

    private func utcDay(_ date: Date) -> CalendarDay {
        let parts = utc.dateComponents([.year, .month, .day], from: date)
        return CalendarDay(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    func adding(_ days: Int, to day: CalendarDay) -> CalendarDay {
        utcDay(utcDate(day).addingTimeInterval(TimeInterval(days) * 86_400))
    }

    /// Whole days from `start` to `end`; negative when `end` is earlier.
    func days(from start: CalendarDay, to end: CalendarDay) -> Int {
        Int((utcDate(end).timeIntervalSince(utcDate(start)) / 86_400).rounded())
    }

    // MARK: - The grid

    /// Short weekday names in the order the grid's columns run.
    var weekdaySymbols: [String] {
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// The month as whole weeks: it opens on the first weekday on or before
    /// the 1st, and runs until the week holding the last day is complete.
    /// Four, five or six rows, depending on how the month falls.
    func weeks(in month: CalendarMonth) -> [[CalendarDay]] {
        let first = month.firstDay
        let weekday = utc.component(.weekday, from: utcDate(first))
        let leading = (weekday - utc.firstWeekday + 7) % 7
        let length = utc.range(of: .day, in: .month, for: utcDate(first))?.count ?? 30
        let rows = (leading + length + 6) / 7
        let start = adding(-leading, to: first)
        return (0..<rows).map { row in
            (0..<7).map { column in adding(row * 7 + column, to: start) }
        }
    }

    // MARK: - Reading exams

    /// Exams from today onwards, soonest first. Today's stay in the list
    /// until the day is over: an exam this afternoon is not behind you yet.
    static func upcoming(_ events: [StudyEvent], from today: CalendarDay) -> [StudyEvent] {
        events.filter { $0.day >= today }.sorted(by: chronological)
    }

    static func byDay(_ events: [StudyEvent]) -> [CalendarDay: [StudyEvent]] {
        Dictionary(grouping: events, by: \.day).mapValues { $0.sorted(by: chronological) }
    }

    private static func chronological(_ lhs: StudyEvent, _ rhs: StudyEvent) -> Bool {
        if lhs.day != rhs.day { return lhs.day < rhs.day }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    func countdown(to day: CalendarDay, from today: CalendarDay) -> String {
        let away = days(from: today, to: day)
        switch away {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case ..<0: return "\(-away) days ago"
        default: return "In \(away) days"
        }
    }

    /// How loudly a countdown should be shown.
    enum Urgency: Equatable {
        /// Today, tomorrow, or the day after — too late to plan, only to revise.
        case imminent
        /// Within the week.
        case soon
        case later
    }

    func urgency(of day: CalendarDay, from today: CalendarDay) -> Urgency {
        let away = days(from: today, to: day)
        if away < 0 { return .later }
        if away <= 2 { return .imminent }
        if away <= 7 { return .soon }
        return .later
    }

    /// The page subtitle: the next exam, and how long is left.
    func headline(for events: [StudyEvent], today: CalendarDay) -> String {
        let upcoming = Self.upcoming(events, from: today)
        guard let next = upcoming.first else { return "No exams coming up" }
        let when = countdown(to: next.day, from: today)
        let also = upcoming.count - 1
        let rest = also > 0 ? " \u{00B7} \(also) more after it" : ""
        return "Next: \(next.title), \(when.lowercased())\(rest)"
    }

    // MARK: - Quick add

    /// Reads what was typed into the quick-add box, the same way the task
    /// board does: `#tag` for the category, a date anywhere in the text.
    ///
    /// With no date typed, the exam goes on `selectedDay` — the day that is
    /// highlighted in the grid — so clicking a day and typing a name is enough.
    /// A `#tag` that matches an existing category apart from case takes that
    /// category's spelling, so `#chem` joins "Chem" rather than starting a
    /// second category in a second colour.
    func quickAdd(_ input: String, course override: String?, selectedDay: CalendarDay,
                  knownCourses: [String]) -> StudyEvent? {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let parsed = QuickAddParser.parse(input)
        let typed = parsed.course.map { tag in
            knownCourses.first { $0.caseInsensitiveCompare(tag) == .orderedSame } ?? tag
        }
        return StudyEvent(title: parsed.title,
                          course: typed ?? override,
                          day: parsed.dueDate.map(day(of:)) ?? selectedDay)
    }
}
