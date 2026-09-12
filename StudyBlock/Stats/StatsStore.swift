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

    /// Everything the stats page reads, in one value.
    ///
    /// Task counts come in from outside rather than being looked up here: the
    /// focus log and the board are separate stores, and this one has no
    /// business holding a reference to the other.
    func summary(goalMinutes: Double, tasksToday: Int = 0, tasksYesterday: Int = 0,
                 now: Date = Date()) -> StatsSummary {
        StatsSummary(records: records, tasksCompletedToday: tasksToday,
                     tasksCompletedYesterday: tasksYesterday,
                     goalMinutes: goalMinutes, now: now)
    }

    var completedSessionCount: Int {
        records.filter(\.completed).count
    }

    var currentStreak: Int {
        Self.streak(recordDates: records.filter(\.completed).map(\.date))
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
