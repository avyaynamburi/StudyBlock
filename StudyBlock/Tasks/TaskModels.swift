import Foundation

enum TaskPriority: Int, Codable, CaseIterable, Comparable {
    case none = 0, low, medium, high

    static func < (lhs: TaskPriority, rhs: TaskPriority) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }
}

enum RepeatRule: String, Codable, CaseIterable {
    case none, daily, weekly, monthly

    var label: String {
        switch self {
        case .none: return "Never"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        }
    }

    /// How many occurrences a series with no end date materialises up front.
    /// A perpetual task can't be expanded forever, so the board carries a
    /// deep-but-finite runway that `TaskStore` tops back up each time one of
    /// them is completed.
    static let perpetualCount = 100

    /// Hard cap for a series that *does* have an end date, so "daily until I
    /// graduate" can't materialise thousands of cards in one go.
    static let maxCount = 400

    /// The first occurrence on or after `start`. Only `.weekly` with an
    /// explicit weekday set can push this later than `start` itself — picking
    /// "starting Thursday, repeats Mon/Wed/Fri" means the series really
    /// begins that Friday.
    private func firstOccurrence(onOrAfter start: Date, weekdays: Set<Int>,
                                 calendar: Calendar) -> Date? {
        guard self != .none else { return nil }
        guard case .weekly = self, !weekdays.isEmpty else { return start }
        var candidate = start
        for _ in 0..<7 {
            if weekdays.contains(calendar.component(.weekday, from: candidate)) { return candidate }
            guard let next = calendar.date(byAdding: .day, value: 1, to: candidate) else { return nil }
            candidate = next
        }
        return nil
    }

    private func nextSelectedWeekday(after date: Date, in weekdays: Set<Int>,
                                     calendar: Calendar) -> Date? {
        var candidate = date
        for _ in 0..<7 {
            guard let next = calendar.date(byAdding: .day, value: 1, to: candidate) else { return nil }
            candidate = next
            if weekdays.contains(calendar.component(.weekday, from: candidate)) { return candidate }
        }
        return nil
    }

    /// The `index`-th due date of a series beginning at `start` (index 0 is
    /// the first occurrence). Every date is derived from `start` rather than
    /// from the previous one, which is what keeps a monthly series pinned to
    /// the 31st instead of walking back to the 28th after a short month, and
    /// keeps the time of day exactly as the user set it.
    ///
    /// `weekdays` (1 = Sunday … 7 = Saturday) narrows `.weekly` to specific
    /// days; empty means "the same weekday `start` falls on".
    func occurrence(index: Int, from start: Date, weekdays: Set<Int> = [],
                    calendar: Calendar = .current) -> Date? {
        guard index >= 0, self != .none else { return nil }
        guard let first = firstOccurrence(onOrAfter: start, weekdays: weekdays, calendar: calendar) else {
            return nil
        }
        if index == 0 { return first }

        switch self {
        case .none:
            return nil
        case .daily:
            return calendar.date(byAdding: .day, value: index, to: first)
        case .monthly:
            return calendar.date(byAdding: .month, value: index, to: first)
        case .weekly:
            guard !weekdays.isEmpty else {
                return calendar.date(byAdding: .day, value: 7 * index, to: first)
            }
            // A weekday selection repeats on an exact 7-day cycle with
            // `weekdays.count` hits per cycle, so whole cycles are one jump
            // and only the remainder has to be walked a day at a time.
            let perWeek = weekdays.count
            guard var candidate = calendar.date(byAdding: .day, value: 7 * (index / perWeek), to: first) else {
                return nil
            }
            for _ in 0..<(index % perWeek) {
                guard let next = nextSelectedWeekday(after: candidate, in: weekdays, calendar: calendar) else {
                    return nil
                }
                candidate = next
            }
            return candidate
        }
    }

    /// Every due date in a series, in order. `endDate` stops it on that day
    /// (inclusive); `limit` caps how many are produced either way, which is
    /// what makes a perpetual series finite.
    func occurrences(startingAt start: Date, weekdays: Set<Int> = [], endDate: Date? = nil,
                     limit: Int = RepeatRule.perpetualCount,
                     calendar: Calendar = .current) -> [Date] {
        guard self != .none, limit > 0 else { return [] }
        let cutoff = endDate.map { calendar.startOfDay(for: $0) }
        var dates: [Date] = []
        for index in 0..<limit {
            guard let date = occurrence(index: index, from: start, weekdays: weekdays,
                                        calendar: calendar) else { break }
            if let cutoff, calendar.startOfDay(for: date) > cutoff { break }
            dates.append(date)
        }
        return dates
    }

    /// How many occurrences to materialise for a series: the full run when it
    /// has an end date (capped), otherwise a fixed perpetual runway.
    static func materializedCount(hasEndDate: Bool) -> Int {
        hasEndDate ? maxCount : perpetualCount
    }
}

/// Which column of the Tasks board a task sits in. Backlog/Upcoming are
/// normally automatic (driven by due date); Doing/Completed are always
/// entered explicitly (drag or the completion checkbox).
enum TaskColumn: String, Codable, CaseIterable, Identifiable {
    case backlog = "All Tasks"
    case upcoming = "Upcoming"
    case doing = "Currently Doing"
    case completed = "Completed"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .backlog: return "tray.full"
        case .upcoming: return "calendar"
        case .doing: return "bolt.fill"
        case .completed: return "checkmark.circle.fill"
        }
    }

    /// Where a task lands by default: Upcoming if due within 7 days (overdue
    /// counts as due), otherwise the backlog ("All Tasks"). Pure, so both the
    /// store and CSV import place tasks by exactly the same rule.
    static func automatic(forDueDate dueDate: Date?, now: Date = Date(),
                          calendar: Calendar = .current) -> TaskColumn {
        guard let dueDate else { return .backlog }
        let day = calendar.startOfDay(for: dueDate)
        let today = calendar.startOfDay(for: now)
        guard let weekOut = calendar.date(byAdding: .day, value: 7, to: today) else { return .backlog }
        return day < weekOut ? .upcoming : .backlog
    }
}

struct TodoItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var notes = ""
    var course: String?
    var dueDate: Date?
    var priority: TaskPriority = .none
    var repeatRule: RepeatRule = .none
    /// 1 = Sunday … 7 = Saturday. Only meaningful when `repeatRule == .weekly`.
    var repeatWeekdays: Set<Int> = []
    var isCompleted = false
    var completedAt: Date?
    var createdAt = Date()
    /// Shared by every task materialised from the same recurring definition.
    /// Each occurrence is a real, independent task — completing one doesn't
    /// move the others — and this is the only thing tying them together, so
    /// the series can be edited or deleted as a whole.
    var seriesID: UUID?
    /// Last day the series runs, inclusive. `nil` on a series that repeats in
    /// perpetuity, which is topped back up as its occurrences get completed.
    /// Only meaningful alongside a non-`none` `repeatRule`.
    var seriesEndDate: Date?
    var column: TaskColumn = .backlog
    /// Once true, automatic due-date-driven column promotion leaves this
    /// task alone — the user (drag, or the completion checkbox) is in charge.
    var columnIsManual = false
    /// Sort key within a column+subject group. Starts equal to the due date
    /// (so the default order is chronological) and only changes when the
    /// user drags the task to a new position, or hits "Sort by Date".
    var manualOrder: Double = 0

    var isOverdue: Bool {
        guard !isCompleted, let due = dueDate else { return false }
        return Calendar.current.startOfDay(for: due) < Calendar.current.startOfDay(for: .now)
    }

    /// True for a task that is one occurrence of a recurring series.
    var isRecurring: Bool { seriesID != nil && repeatRule != .none }

    /// Expands this task, used as a template, into one real task per
    /// occurrence of its series — the "recurring tasks are literally
    /// duplicated" rule in one place, so the Recurring Task sheet and CSV
    /// import build byte-identical sets of tasks.
    ///
    /// Every copy is independent: completing one leaves the rest untouched.
    /// A series with `seriesEndDate` is expanded over its full range (capped
    /// at `RepeatRule.maxCount`); a perpetual one gets
    /// `RepeatRule.perpetualCount` occurrences of runway.
    func materializedSeries(from start: Date, now: Date = Date(),
                            calendar: Calendar = .current) -> [TodoItem] {
        guard repeatRule != .none else { return [] }
        let dates = repeatRule.occurrences(
            startingAt: start,
            weekdays: repeatWeekdays,
            endDate: seriesEndDate,
            limit: RepeatRule.materializedCount(hasEndDate: seriesEndDate != nil),
            calendar: calendar)

        return dates.map { date in
            var occurrence = self
            occurrence.id = UUID()
            occurrence.dueDate = date
            occurrence.isCompleted = false
            occurrence.completedAt = nil
            occurrence.column = TaskColumn.automatic(forDueDate: date, now: now, calendar: calendar)
            occurrence.columnIsManual = false
            occurrence.manualOrder = TodoItem.dateOrderValue(for: date)
            return occurrence
        }
    }

    static func dateOrderValue(for dueDate: Date?) -> Double {
        dueDate?.timeIntervalSince1970 ?? .greatestFiniteMagnitude
    }
}
