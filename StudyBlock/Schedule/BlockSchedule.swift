import Foundation

/// A recurring window during which a set of block lists switches itself on.
///
/// Deliberately *not* a locked session. The schedule turns blocking on when a
/// window opens and off when the last one closes, and does nothing in between:
/// switch it off by hand mid-window and it stays off until the next window
/// opens. Re-asserting on every tick would be a lock in all but name, which is
/// the one thing a schedule must not be.
struct BlockSchedule: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    /// 1 = Sunday … 7 = Saturday, matching `Calendar.component(.weekday:)`.
    var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    /// Minutes from midnight. Storing the time of day rather than a `Date`
    /// keeps a window comparable without dragging a particular day along
    /// with it.
    var startMinute = 9 * 60
    var endMinute = 12 * 60
    /// Which block lists this window switches on. Empty means every list —
    /// the useful reading of "block during class" when you only have one.
    var groupIDs: Set<UUID> = []
    var isEnabled = true

    /// Whether `date` falls inside one of this schedule's windows.
    ///
    /// A window whose end is before its start runs overnight: 22:00–02:00 on
    /// Friday means Friday night into Saturday morning. The weekday a window
    /// belongs to is the day it *starts*, which is what stops "Fri 22:00–02:00"
    /// from also firing on Saturday night.
    func isActive(at date: Date, calendar: Calendar = .current) -> Bool {
        guard isEnabled, !weekdays.isEmpty, startMinute != endMinute else { return false }
        let weekday = calendar.component(.weekday, from: date)
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)

        if startMinute < endMinute {
            return weekdays.contains(weekday) && minute >= startMinute && minute < endMinute
        }
        let previousWeekday = weekday == 1 ? 7 : weekday - 1
        return (weekdays.contains(weekday) && minute >= startMinute)
            || (weekdays.contains(previousWeekday) && minute < endMinute)
    }

    /// The bars to draw on the week grid, split so an overnight window shows
    /// as one bar at the end of its own day and another at the start of the
    /// next — the same shape the calendar app you're used to draws.
    var segments: [(weekday: Int, start: Int, end: Int)] {
        guard !weekdays.isEmpty, startMinute != endMinute else { return [] }
        if startMinute < endMinute {
            return weekdays.sorted().map { (weekday: $0, start: startMinute, end: endMinute) }
        }
        return weekdays.sorted().flatMap { day -> [(weekday: Int, start: Int, end: Int)] in
            let next = day == 7 ? 1 : day + 1
            return [(weekday: day, start: startMinute, end: 24 * 60),
                    (weekday: next, start: 0, end: endMinute)]
        }
    }

    var daysLabel: String {
        guard !weekdays.isEmpty else { return "Never" }
        if weekdays == [2, 3, 4, 5, 6] { return "Weekdays" }
        if weekdays == [1, 7] { return "Weekends" }
        if weekdays.count == 7 { return "Every day" }
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return weekdays.sorted().map { names[$0 - 1] }.joined(separator: " ")
    }

    var timeLabel: String {
        let overnight = endMinute <= startMinute
        return "\(Self.clockLabel(startMinute))\u{2013}\(Self.clockLabel(endMinute))"
            + (overnight ? " (overnight)" : "")
    }

    static func clockLabel(_ minutes: Int) -> String {
        let total = ((minutes % (24 * 60)) + 24 * 60) % (24 * 60)
        var components = DateComponents()
        components.hour = total / 60
        components.minute = total % 60
        guard let date = Calendar.current.date(from: components) else { return "" }
        return date.formatted(date: .omitted, time: .shortened)
    }
}
