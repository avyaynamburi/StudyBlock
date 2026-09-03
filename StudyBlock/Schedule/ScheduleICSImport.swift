import Foundation

/// One block window proposed by an imported calendar, before the user has
/// agreed to it. Reviewed in the import sheet, then turned into a real
/// `BlockSchedule`.
struct ScheduleCandidate: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var weekdays: Set<Int>
    var startMinute: Int
    var endMinute: Int
    /// How many calendar entries folded into this one row. A term's worth of
    /// individually-listed lectures collapses to a single weekly window, and
    /// this is what says so.
    var mergedCount = 1
    /// True when the calendar said outright that this repeats. False means
    /// the pattern was inferred by folding one-off entries together, which is
    /// worth flagging before it becomes a standing weekly block.
    var fromRecurrenceRule = false

    func schedule(groupIDs: Set<UUID>) -> BlockSchedule {
        BlockSchedule(name: name, weekdays: weekdays,
                      startMinute: startMinute, endMinute: endMinute,
                      groupIDs: groupIDs)
    }

    var daysLabel: String {
        BlockSchedule(name: name, weekdays: weekdays,
                      startMinute: startMinute, endMinute: endMinute).daysLabel
    }

    var timeLabel: String {
        BlockSchedule(name: name, weekdays: weekdays,
                      startMinute: startMinute, endMinute: endMinute).timeLabel
    }
}

/// Turns a calendar file into proposed block windows.
///
/// A `BlockSchedule` is a standing weekly pattern — weekdays plus a start and
/// end time of day — so this reads each event's *local wall clock* and the
/// weekdays it falls on, and throws the actual calendar dates away. That is
/// the whole conversion: a term's timetable becomes "block during class".
enum ScheduleICSImport {
    struct Outcome: Equatable {
        var candidates: [ScheduleCandidate] = []
        /// All-day entries: no time of day, so no window to build.
        var skippedAllDay = 0
        /// Neither `DTEND` nor `DURATION` — nothing says when it ends, and
        /// inventing a length would be inventing a block.
        var skippedNoEnd = 0
        /// Longer than a day, so it isn't a daily window at all.
        var skippedTooLong = 0
        /// Zero-length or backwards.
        var skippedEmpty = 0

        var skippedTotal: Int { skippedAllDay + skippedNoEnd + skippedTooLong + skippedEmpty }

        /// Plain-English account of everything left out, so a short import
        /// isn't a mystery.
        var skippedSummary: String {
            var parts: [String] = []
            if skippedAllDay > 0 { parts.append("\(skippedAllDay) all-day") }
            if skippedNoEnd > 0 { parts.append("\(skippedNoEnd) with no end time") }
            if skippedTooLong > 0 { parts.append("\(skippedTooLong) longer than a day") }
            if skippedEmpty > 0 { parts.append("\(skippedEmpty) empty") }
            guard !parts.isEmpty else { return "" }
            return "Skipped " + parts.joined(separator: ", ") + "."
        }
    }

    static func read(_ data: Data, calendar: Calendar = .current) -> Outcome {
        candidates(from: ICSParser.events(from: data), calendar: calendar)
    }

    static func candidates(from events: [ICSEvent], calendar: Calendar = .current) -> Outcome {
        var outcome = Outcome()
        // Keyed on name + times, so the same class listed once per week all
        // term becomes one window with every weekday it meets on.
        var merged: [String: ScheduleCandidate] = [:]
        var order: [String] = []

        for event in events {
            guard case .instant(let start)? = event.start else {
                if event.start != nil { outcome.skippedAllDay += 1 }
                continue
            }
            guard let end = endInstant(of: event, start: start) else {
                outcome.skippedNoEnd += 1
                continue
            }
            let length = end.timeIntervalSince(start)
            guard length > 0 else { outcome.skippedEmpty += 1; continue }
            guard length <= 24 * 3600 else { outcome.skippedTooLong += 1; continue }

            let startMinute = minuteOfDay(start, calendar: calendar)
            let endMinute = minuteOfDay(end, calendar: calendar)
            guard startMinute != endMinute else { outcome.skippedEmpty += 1; continue }

            let name = event.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = name.isEmpty ? "Untitled" : name
            let weekdays = weekdays(for: event, start: start, calendar: calendar)
            guard !weekdays.isEmpty else { continue }

            let key = "\(title)|\(startMinute)|\(endMinute)"
            let isRule = event.recurrence != nil
            if var existing = merged[key] {
                existing.weekdays.formUnion(weekdays)
                existing.mergedCount += 1
                existing.fromRecurrenceRule = existing.fromRecurrenceRule || isRule
                merged[key] = existing
            } else {
                merged[key] = ScheduleCandidate(name: title, weekdays: weekdays,
                                                startMinute: startMinute, endMinute: endMinute,
                                                mergedCount: 1, fromRecurrenceRule: isRule)
                order.append(key)
            }
        }

        outcome.candidates = order.compactMap { merged[$0] }
            .sorted { lhs, rhs in
                if lhs.startMinute != rhs.startMinute { return lhs.startMinute < rhs.startMinute }
                return lhs.name < rhs.name
            }
        return outcome
    }

    /// When the event ends: `DTEND` if given, otherwise `DTSTART` plus
    /// `DURATION`. Nothing is assumed when neither is present.
    private static func endInstant(of event: ICSEvent, start: Date) -> Date? {
        if case .instant(let end)? = event.end { return end }
        if let duration = event.duration, duration > 0 { return start.addingTimeInterval(duration) }
        return nil
    }

    private static func minuteOfDay(_ date: Date, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// Which weekdays this event should block on.
    ///
    /// A weekly rule names them outright in `BYDAY`; a daily rule means every
    /// day. Anything else — a monthly rule, or no rule at all — contributes
    /// only the day it actually falls on, and relies on folding to build the
    /// pattern from the entries themselves.
    private static func weekdays(for event: ICSEvent, start: Date,
                                 calendar: Calendar) -> Set<Int> {
        let own = Set([calendar.component(.weekday, from: start)])
        guard let recurrence = event.recurrence else { return own }
        switch recurrence.frequency {
        case "WEEKLY":
            return recurrence.weekdays.isEmpty ? own : recurrence.weekdays
        case "DAILY":
            return Set(1...7)
        default:
            return own
        }
    }
}
