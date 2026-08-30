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

    /// The unit letter used by the CSV `repeat` code — `2w` is "every two
    /// weeks". Kept next to `label` so the two never drift apart.
    var unitCode: String {
        switch self {
        case .none: return ""
        case .daily: return "d"
        case .weekly: return "w"
        case .monthly: return "m"
        }
    }

    /// "day"/"days" etc., for spelling an interval out in the UI.
    func unitName(plural: Bool) -> String {
        switch self {
        case .none: return ""
        case .daily: return plural ? "days" : "day"
        case .weekly: return plural ? "weeks" : "week"
        case .monthly: return plural ? "months" : "month"
        }
    }

    /// "Every 2 weeks", "Every month" — the phrase the recurring sheet shows
    /// beside its interval stepper.
    func intervalLabel(_ interval: Int) -> String {
        guard self != .none else { return label }
        return interval <= 1
            ? "Every \(unitName(plural: false))"
            : "Every \(interval) \(unitName(plural: true))"
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

    /// The `index`-th due date of a series beginning at `start` (index 0 is
    /// the first occurrence). `interval` is how many periods separate
    /// occurrences, so `.weekly` with an interval of 2 is "every other week".
    ///
    /// Every date is derived from `start` rather than from the previous one,
    /// which is what keeps a monthly series pinned to the 31st instead of
    /// walking back to the 28th after a short month, and keeps the time of
    /// day exactly as the user set it.
    ///
    /// `weekdays` (1 = Sunday … 7 = Saturday) narrows `.weekly` to specific
    /// days; empty means "the same weekday `start` falls on".
    func occurrence(index: Int, from start: Date, weekdays: Set<Int> = [], interval: Int = 1,
                    calendar: Calendar = .current) -> Date? {
        guard index >= 0, self != .none else { return nil }
        let step = max(1, interval)
        guard let first = firstOccurrence(onOrAfter: start, weekdays: weekdays, calendar: calendar) else {
            return nil
        }
        if index == 0 { return first }

        switch self {
        case .none:
            return nil
        case .daily:
            return calendar.date(byAdding: .day, value: step * index, to: first)
        case .monthly:
            return calendar.date(byAdding: .month, value: step * index, to: first)
        case .weekly where weekdays.isEmpty:
            return calendar.date(byAdding: .day, value: 7 * step * index, to: first)
        case .weekly:
            guard let offset = weeklyDayOffset(index: index, from: first, weekdays: weekdays,
                                               interval: step, calendar: calendar) else { return nil }
            return calendar.date(byAdding: .day, value: offset, to: first)
        }
    }

    /// Days from the first occurrence to the `index`-th, for a weekly rule
    /// narrowed to specific weekdays.
    ///
    /// The series tiles the calendar in cycles of `interval` weeks, each
    /// cycle hitting every selected weekday. The cycle holding `first` is the
    /// exception: selected days earlier in that week have already gone by, so
    /// it contributes only the days from `first` onward. Anchoring the cycles
    /// to real calendar weeks — not to `first` — is what makes "every other
    /// Mon/Wed/Fri, starting Wednesday" skip the following Monday instead of
    /// treating it as part of the first cycle.
    private func weeklyDayOffset(index: Int, from first: Date, weekdays: Set<Int>,
                                 interval: Int, calendar: Calendar) -> Int? {
        // Each selected weekday's position within its calendar week.
        let weekStart = calendar.firstWeekday
        let offsets = weekdays.map { ($0 - weekStart + 7) % 7 }.sorted()
        guard !offsets.isEmpty else { return nil }
        let perCycle = offsets.count
        let firstOffset = (calendar.component(.weekday, from: first) - weekStart + 7) % 7

        // What's left of the first cycle, starting at `first` itself.
        let remainder = offsets.filter { $0 >= firstOffset }
        if index < remainder.count { return remainder[index] - firstOffset }

        let after = index - remainder.count
        let cycle = after / perCycle + 1
        return 7 * interval * cycle + offsets[after % perCycle] - firstOffset
    }

    /// Every due date in a series, in order. `endDate` stops it on that day
    /// (inclusive); `limit` caps how many are produced either way, which is
    /// what makes a perpetual series finite.
    func occurrences(startingAt start: Date, weekdays: Set<Int> = [], interval: Int = 1,
                     endDate: Date? = nil, limit: Int = RepeatRule.perpetualCount,
                     calendar: Calendar = .current) -> [Date] {
        guard self != .none, limit > 0 else { return [] }
        let cutoff = endDate.map { calendar.startOfDay(for: $0) }
        var dates: [Date] = []
        for index in 0..<limit {
            guard let date = occurrence(index: index, from: start, weekdays: weekdays,
                                        interval: interval, calendar: calendar) else { break }
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

    /// Where a task lands by default: Upcoming if it's due within 7 days
    /// (overdue counts as due) **or has no due date at all**, otherwise the
    /// backlog ("All Tasks"). Pure, so both the store and CSV import place
    /// tasks by exactly the same rule.
    ///
    /// An undated task is something to get to soon, not something scheduled
    /// for later, so Upcoming is where it belongs. That leaves "All Tasks"
    /// holding exactly two kinds of card: work genuinely dated more than a
    /// week out, and anything deliberately parked there — which
    /// `columnIsManual` keeps from being pulled back out.
    static func automatic(forDueDate dueDate: Date?, now: Date = Date(),
                          calendar: Calendar = .current) -> TaskColumn {
        guard let dueDate else { return .upcoming }
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
    /// Backing store for `repeatInterval`. Optional on purpose: `JSONStore`
    /// turns any decode failure into an empty board, so a new *non*-optional
    /// field would silently erase every task saved before this existed.
    /// Optionals decode as nil when the key is absent, which is exactly the
    /// "no interval recorded" case. Read and write it via `repeatInterval`.
    var repeatEvery: Int? = nil
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

    /// Periods between occurrences: 2 alongside `.weekly` is "every other
    /// week", 12 alongside `.monthly` is "every year". Always at least 1, and
    /// 1 is stored as nil so the common case adds nothing to the JSON.
    var repeatInterval: Int {
        get { max(1, repeatEvery ?? 1) }
        set { repeatEvery = newValue <= 1 ? nil : newValue }
    }

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
            interval: repeatInterval,
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
