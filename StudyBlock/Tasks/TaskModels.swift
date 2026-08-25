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
    case none, daily, weekly

    var label: String {
        switch self {
        case .none: return "Never"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        }
    }

    /// Next occurrence strictly after `today`, stepping from the task's due
    /// date so weekly homework stays on its weekday even when completed late.
    func nextDueDate(after dueDate: Date, today: Date = Date(), calendar: Calendar = .current) -> Date? {
        let step: DateComponents
        switch self {
        case .none: return nil
        case .daily: step = DateComponents(day: 1)
        case .weekly: step = DateComponents(day: 7)
        }
        var next = dueDate
        let todayStart = calendar.startOfDay(for: today)
        repeat {
            guard let advanced = calendar.date(byAdding: step, to: next) else { return nil }
            next = advanced
        } while next <= todayStart
        return next
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
    var isCompleted = false
    var completedAt: Date?
    var createdAt = Date()
}

enum TaskGroup: String, CaseIterable, Identifiable {
    case overdue = "Overdue"
    case today = "Today"
    case thisWeek = "This Week"
    case later = "Later"
    case noDate = "No Date"

    var id: String { rawValue }

    static func group(for dueDate: Date?, now: Date = Date(), calendar: Calendar = .current) -> TaskGroup {
        guard let dueDate else { return .noDate }
        let day = calendar.startOfDay(for: dueDate)
        let today = calendar.startOfDay(for: now)
        if day < today { return .overdue }
        if day == today { return .today }
        if let weekOut = calendar.date(byAdding: .day, value: 7, to: today), day < weekOut { return .thisWeek }
        return .later
    }
}
