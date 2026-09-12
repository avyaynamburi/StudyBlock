import Foundation

/// The three ages of a finished task.
///
/// The Completed column is the only one where *when* something happened is the
/// interesting part — the rest of the board is about what's still to do. Cut
/// into these, the column answers "how much did I get through today?" at a
/// glance instead of burying today's three cards under last month's forty.
enum CompletedSection: String, CaseIterable, Identifiable {
    case today = "Today"
    case week = "This week"
    case earlier = "Earlier"

    var id: String { rawValue }
}

/// One section's worth of the Completed column.
struct CompletedGroup: Identifiable, Equatable {
    var section: CompletedSection
    var tasks: [TodoItem]
    var id: String { section.id }
}

enum CompletedSections {
    /// Which section a task completed at `date` belongs in.
    ///
    /// "This week" runs from the calendar's own first weekday, the same week
    /// the stats page counts, rather than a rolling seven days: two pages
    /// disagreeing about what "this week" means is worse than either
    /// definition being wrong. A task with no completion date — imported, or
    /// saved before the app recorded one — is old news by definition.
    static func section(for date: Date?, now: Date = Date(), calendar: Calendar = .current) -> CompletedSection {
        guard let date else { return .earlier }
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        let today = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: today)
        let daysIn = (weekday - calendar.firstWeekday + 7) % 7
        guard let weekStart = calendar.date(byAdding: .day, value: -daysIn, to: today) else { return .earlier }
        return date >= weekStart ? .week : .earlier
    }

    /// Splits the column, keeping the order it was handed in and dropping any
    /// section that would be empty — an empty heading is a heading that costs
    /// a line and says nothing.
    static func split(_ tasks: [TodoItem], now: Date = Date(),
                      calendar: Calendar = .current) -> [CompletedGroup] {
        CompletedSection.allCases.compactMap { section in
            let matching = tasks.filter {
                CompletedSections.section(for: $0.completedAt, now: now, calendar: calendar) == section
            }
            return matching.isEmpty ? nil : CompletedGroup(section: section, tasks: matching)
        }
    }
}
