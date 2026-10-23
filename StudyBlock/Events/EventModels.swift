import Foundation

/// A date with no time of day and no timezone — "14 October", wherever you
/// are standing when you read it.
///
/// Exams are kept this way rather than as a `Date` at midnight. A midnight
/// `Date` is a moment, and read back somewhere west of where it was written
/// it falls on the evening before: the exam moves a day.
///
/// The fields are always Gregorian, whatever calendar the Mac displays, so
/// the file means the same thing on every machine.
struct CalendarDay: Codable, Hashable, Comparable {
    var year: Int
    var month: Int
    var day: Int

    static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

/// One month of the grid, named by its Gregorian year and month.
struct CalendarMonth: Hashable {
    var year: Int
    var month: Int

    init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    init(containing day: CalendarDay) {
        self.init(year: day.year, month: day.month)
    }

    var firstDay: CalendarDay { CalendarDay(year: year, month: month, day: 1) }

    func adding(months: Int) -> CalendarMonth {
        let index = year * 12 + (month - 1) + months
        return CalendarMonth(year: index / 12, month: index % 12 + 1)
    }
}

/// An exam on the Events page.
struct StudyEvent: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var course: String?
    var day: CalendarDay
}
