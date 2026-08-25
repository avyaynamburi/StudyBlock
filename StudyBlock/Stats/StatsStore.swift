import Foundation

struct FocusRecord: Identifiable, Codable, Equatable {
    var id = UUID()
    var date: Date
    var minutes: Double
    var completed: Bool
    var course: String?
    var taskTitle: String?
}

@MainActor
final class StatsStore: ObservableObject {
    @Published private(set) var records: [FocusRecord] = [] {
        didSet { JSONStore.save(records, to: "focus-history.json") }
    }

    init() {
        records = JSONStore.load([FocusRecord].self, from: "focus-history.json") ?? []
    }

    func record(minutes: Double, completed: Bool, course: String? = nil, taskTitle: String? = nil) {
        guard minutes >= 0.5 else { return }
        records.append(FocusRecord(date: Date(), minutes: minutes, completed: completed,
                                   course: course, taskTitle: taskTitle))
    }

    /// Focused minutes per course since `startDate`, most-studied first.
    /// Sessions without a task/course land in "General".
    func minutesByCourse(since startDate: Date) -> [(course: String, minutes: Double)] {
        let recent = records.filter { $0.date >= startDate }
        guard !recent.isEmpty else { return [] }
        let buckets = Dictionary(grouping: recent) { $0.course ?? "General" }
        return buckets
            .map { (course: $0.key, minutes: $0.value.reduce(0) { $0 + $1.minutes }) }
            .sorted { $0.minutes > $1.minutes }
    }

    var minutesToday: Double {
        let today = Calendar.current.startOfDay(for: .now)
        return records.filter { $0.date >= today }.reduce(0) { $0 + $1.minutes }
    }

    var completedSessionCount: Int {
        records.filter(\.completed).count
    }

    var currentStreak: Int {
        Self.streak(recordDates: records.filter(\.completed).map(\.date))
    }

    /// Focused minutes per day for the last `days` days, oldest first,
    /// including zero days so charts show gaps honestly.
    func dailyMinutes(days: Int) -> [(day: Date, minutes: Double)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        return (0..<days).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today),
                  let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            let total = records.filter { $0.date >= day && $0.date < next }.reduce(0) { $0 + $1.minutes }
            return (day, total)
        }
    }

    /// Consecutive days with at least one completed session, counting back
    /// from today — or from yesterday, so the streak isn't shown as broken
    /// before today's studying has happened.
    nonisolated static func streak(recordDates: [Date], calendar: Calendar = .current, today: Date = Date()) -> Int {
        let days = Set(recordDates.map { calendar.startOfDay(for: $0) })
        guard !days.isEmpty else { return 0 }

        var cursor = calendar.startOfDay(for: today)
        if !days.contains(cursor) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) else { return 0 }
            cursor = yesterday
        }

        var streak = 0
        while days.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }
}
