import Foundation

@MainActor
final class TaskStore: ObservableObject {
    @Published var items: [TodoItem] = [] {
        didSet { JSONStore.save(items, to: "tasks.json") }
    }

    init() {
        items = JSONStore.load([TodoItem].self, from: "tasks.json") ?? []
    }

    func quickAdd(_ input: String) {
        let parsed = QuickAddParser.parse(input)
        guard !parsed.title.isEmpty else { return }
        items.append(TodoItem(title: parsed.title, course: parsed.course,
                              dueDate: parsed.dueDate, priority: parsed.priority))
    }

    func update(_ item: TodoItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
    }

    func delete(_ item: TodoItem) {
        items.removeAll { $0.id == item.id }
    }

    func toggleCompletion(_ item: TodoItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        var task = items[index]

        if !task.isCompleted, task.repeatRule != .none, let due = task.dueDate,
           let nextDue = task.repeatRule.nextDueDate(after: due) {
            // Repeating task: archive this occurrence as completed and roll
            // the live task forward to its next due date.
            var occurrence = task
            occurrence.id = UUID()
            occurrence.repeatRule = .none
            occurrence.isCompleted = true
            occurrence.completedAt = Date()
            task.dueDate = nextDue
            items[index] = task
            items.append(occurrence)
            return
        }

        task.isCompleted.toggle()
        task.completedAt = task.isCompleted ? Date() : nil
        items[index] = task
    }

    var courses: [String] {
        Array(Set(items.compactMap(\.course))).sorted()
    }

    /// Open tasks bucketed for display, in fixed group order, sorted by due
    /// date then priority within each group.
    func groupedOpenTasks(course: String?) -> [(group: TaskGroup, tasks: [TodoItem])] {
        let open = items.filter { !$0.isCompleted && (course == nil || $0.course == course) }
        let buckets = Dictionary(grouping: open) { TaskGroup.group(for: $0.dueDate) }
        return TaskGroup.allCases.compactMap { group in
            guard let tasks = buckets[group], !tasks.isEmpty else { return nil }
            let sorted = tasks.sorted {
                if let a = $0.dueDate, let b = $1.dueDate, a != b { return a < b }
                if $0.priority != $1.priority { return $0.priority > $1.priority }
                return $0.createdAt < $1.createdAt
            }
            return (group, sorted)
        }
    }

    func completedTasks(course: String?) -> [TodoItem] {
        items.filter { $0.isCompleted && (course == nil || $0.course == course) }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    func completedCount(since startDate: Date) -> Int {
        items.filter { $0.isCompleted && ($0.completedAt ?? .distantPast) >= startDate }.count
    }
}
