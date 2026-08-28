import Foundation
import SwiftUI

@MainActor
final class TaskStore: ObservableObject {
    @Published var items: [TodoItem] = [] {
        didSet { JSONStore.save(items, to: "tasks.json") }
    }

    /// Category name -> hue (0..<360), chosen when the category is created.
    /// A category without an entry (e.g. typed via a `#tag` before this
    /// feature existed) still gets a stable color from `color(for:)`.
    @Published var courseHues: [String: Double] = [:] {
        didSet { JSONStore.save(courseHues, to: "courseColors.json") }
    }

    init() {
        items = JSONStore.load([TodoItem].self, from: "tasks.json") ?? []
        courseHues = JSONStore.load([String: Double].self, from: "courseColors.json") ?? [:]
        migrateLegacySeries()
        recomputeAutoColumns()
    }

    /// Recurring tasks used to be stored as a *single* live task that rolled
    /// its own due date forward on completion, with finished occurrences
    /// archived alongside it pointing back at it by id. They're materialised
    /// now — one real task per occurrence — so expand any of the old shape
    /// still on disk into the copies the rest of the app expects.
    ///
    /// The live task's own id becomes the series id, which is exactly what its
    /// historical occurrences already store, so the past re-links for free.
    private func migrateLegacySeries(now: Date = Date()) {
        // A pending member of a series always carries the series' repeat rule
        // now. One that doesn't is an old archived occurrence the user
        // reopened — a one-off task pulled back out of the series, not a
        // future occurrence — so detach it rather than let it be swept up by
        // a later edit or delete of the series.
        for index in items.indices where items[index].seriesID != nil
            && items[index].repeatRule == .none && !items[index].isCompleted {
            items[index].seriesID = nil
        }

        let legacy = items.filter {
            $0.repeatRule != .none && $0.seriesID == nil && !$0.isCompleted && $0.dueDate != nil
        }
        guard !legacy.isEmpty else { return }

        for task in legacy {
            guard let due = task.dueDate else { continue }
            var template = task
            template.seriesID = task.id
            let created = template.materializedSeries(from: due, now: now)
            guard !created.isEmpty else { continue }

            items.removeAll { $0.id == task.id }
            items.append(contentsOf: created)
            // Give the already-completed occurrences the same repeat details,
            // so the series is internally consistent from here on.
            for index in items.indices where items[index].seriesID == task.id && items[index].isCompleted {
                items[index].repeatRule = task.repeatRule
                items[index].repeatWeekdays = task.repeatWeekdays
                items[index].seriesEndDate = task.seriesEndDate
            }
        }
    }

    func setHue(_ hue: Double, for course: String) {
        courseHues[course] = hue
    }

    /// The color every task/chip for this category should use — the
    /// user-picked hue if set, otherwise a stable hash-derived fallback so
    /// every category still has *a* color.
    func color(for course: String) -> Color {
        Theme.categoryInk(hue: hue(for: course))
    }

    private func hue(for course: String) -> Double {
        if let stored = courseHues[course] { return stored }
        var hash: UInt64 = 5381
        for byte in course.lowercased().utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return Double(hash % 360)
    }

    // MARK: - CSV

    func exportCSV() -> String {
        TaskCSV.encode(items: items, hues: courseHues)
    }

    struct ImportSummary {
        var added = 0
        var updated = 0
        var warnings: [String] = []

        var headline: String {
            var parts: [String] = []
            if added > 0 { parts.append("\(added) task\(added == 1 ? "" : "s") added") }
            if updated > 0 { parts.append("\(updated) updated") }
            return parts.isEmpty ? "Nothing to import" : parts.joined(separator: ", ")
        }
    }

    /// Merges a CSV into the board. Rows carrying an `id` that's already here
    /// update that task in place (so re-importing an export is idempotent
    /// rather than duplicating everything); everything else is added.
    @discardableResult
    func importCSV(_ text: String) throws -> ImportSummary {
        try apply(TaskCSV.decode(text))
    }

    /// Import from text pasted out of a chat window, which may be wrapped in
    /// prose or ``` fences rather than being a clean file.
    @discardableResult
    func importPastedCSV(_ text: String) throws -> ImportSummary {
        try apply(TaskCSV.decode(table: TaskCSV.table(fromPasted: text)))
    }

    private func apply(_ decoded: TaskCSV.DecodeResult) -> ImportSummary {
        let merged = TaskCSV.merge(rows: decoded.rows, into: items, hues: courseHues)
        items = merged.items
        courseHues = merged.hues

        // Expanding one "weekly" line into 100 cards is a big, surprising
        // change to the board — say so explicitly rather than just reporting
        // a large "added" number.
        var warnings = decoded.warnings
        for series in merged.expanded {
            warnings.append("\u{201C}\(series.title)\u{201D} repeats \u{2014} created \(series.count) copies.")
        }
        for title in merged.expandedEmpty {
            warnings.append("\u{201C}\(title)\u{201D} repeats, but its repeat_until is on or before its due_date \u{2014} nothing created.")
        }
        return ImportSummary(added: merged.added, updated: merged.updated, warnings: warnings)
    }

    func quickAdd(_ input: String, courseOverride: String? = nil) {
        let parsed = QuickAddParser.parse(input)
        guard !parsed.title.isEmpty else { return }
        var task = TodoItem(title: parsed.title, course: parsed.course ?? courseOverride,
                             dueDate: parsed.dueDate, priority: parsed.priority)
        task.column = defaultColumn(for: task.dueDate)
        task.manualOrder = TodoItem.dateOrderValue(for: task.dueDate)
        items.append(task)
    }

    /// Creates a recurring task by materialising it: every occurrence becomes
    /// a real, independent task on the board sharing one `seriesID`. A series
    /// with an end date is expanded in full (up to `RepeatRule.maxCount`); a
    /// perpetual one gets `RepeatRule.perpetualCount` occurrences of runway,
    /// which `topUpSeries` extends as they're completed.
    @discardableResult
    func addRecurring(title: String, course: String?, dueDate: Date, priority: TaskPriority,
                      repeatRule: RepeatRule, repeatWeekdays: Set<Int>,
                      seriesEndDate: Date? = nil, notes: String = "") -> Int {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        var template = TodoItem(title: trimmed, notes: notes, course: course, dueDate: dueDate,
                                priority: priority, repeatRule: repeatRule,
                                repeatWeekdays: repeatWeekdays)
        template.seriesID = UUID()
        template.seriesEndDate = seriesEndDate

        guard repeatRule != .none else {
            // "Never" isn't a series — fall back to a single plain task.
            template.seriesID = nil
            template.column = defaultColumn(for: dueDate)
            template.manualOrder = TodoItem.dateOrderValue(for: dueDate)
            items.append(template)
            return 1
        }

        let created = template.materializedSeries(from: dueDate)
        items.append(contentsOf: created)
        return created.count
    }

    /// Saves an edit to a single task. Turning on a repeat rule for a task
    /// that isn't already part of a series promotes it into one, replacing
    /// the single card with the whole materialised run — the same thing the
    /// Recurring Task sheet would have produced.
    @discardableResult
    func update(_ item: TodoItem) -> Int {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return 0 }

        if item.seriesID == nil, item.repeatRule != .none,
           !item.isCompleted, let due = item.dueDate {
            var template = item
            template.seriesID = UUID()
            let created = template.materializedSeries(from: due)
            guard !created.isEmpty else { return 0 }
            items.remove(at: index)
            items.append(contentsOf: created)
            return created.count
        }

        var updated = item
        if !updated.isCompleted, !updated.columnIsManual {
            updated.column = defaultColumn(for: updated.dueDate)
        }
        items[index] = updated
        return 1
    }

    /// Rewrites a whole recurring series. Completed occurrences are left
    /// exactly as they are — they're a record of work actually done — while
    /// every pending one is replaced by a freshly materialised run from the
    /// new start date, so changing the schedule reshapes the future without
    /// rewriting the past.
    func updateSeries(seriesID: UUID, title: String, course: String?, dueDate: Date,
                      priority: TaskPriority, repeatRule: RepeatRule, repeatWeekdays: Set<Int>,
                      seriesEndDate: Date?, notes: String? = nil) {
        let members = items.filter { $0.seriesID == seriesID }
        guard let reference = members.first else { return }

        var template = reference
        template.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        template.course = course
        template.priority = priority
        template.repeatRule = repeatRule
        template.repeatWeekdays = repeatWeekdays
        template.seriesEndDate = seriesEndDate
        if let notes { template.notes = notes }
        guard !template.title.isEmpty else { return }

        // Keep the completed history, but bring its wording in line with the
        // edit so the series reads consistently on the board.
        for index in items.indices where items[index].seriesID == seriesID && items[index].isCompleted {
            items[index].title = template.title
            items[index].course = course
            items[index].priority = priority
            items[index].repeatRule = repeatRule
            items[index].repeatWeekdays = repeatWeekdays
            items[index].seriesEndDate = seriesEndDate
            if let notes { items[index].notes = notes }
        }

        items.removeAll { $0.seriesID == seriesID && !$0.isCompleted }
        guard repeatRule != .none else { return }
        items.append(contentsOf: template.materializedSeries(from: dueDate))
    }

    /// Every task belonging to a series, earliest due date first.
    func seriesMembers(_ seriesID: UUID) -> [TodoItem] {
        items.filter { $0.seriesID == seriesID }
            .sorted { ($0.dueDate ?? .distantPast) < ($1.dueDate ?? .distantPast) }
    }

    /// A representative occurrence to open the series editor on: the next one
    /// still pending, or the last completed one if the run is finished.
    func seriesTemplate(for seriesID: UUID) -> TodoItem? {
        let members = seriesMembers(seriesID)
        return members.first { !$0.isCompleted } ?? members.last
    }

    /// How many occurrences of a series are still pending — shown when
    /// editing or deleting the series so the scale of the change is clear.
    func pendingCount(inSeries seriesID: UUID) -> Int {
        items.filter { $0.seriesID == seriesID && !$0.isCompleted }.count
    }

    func delete(_ item: TodoItem) {
        items.removeAll { $0.id == item.id }
    }

    /// Deletes every occurrence of a series. Completed ones are kept unless
    /// `includingCompleted` is set, so removing a series doesn't erase the
    /// record of work already finished.
    func deleteSeries(_ seriesID: UUID, includingCompleted: Bool = false) {
        items.removeAll { $0.seriesID == seriesID && (includingCompleted || !$0.isCompleted) }
    }

    func toggleCompletion(_ item: TodoItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        if items[index].isCompleted {
            reopen(at: index)
        } else {
            complete(at: index)
        }
    }

    /// Drag-and-drop between board columns. Dropping onto Completed marks the
    /// task done (running any repeat rollover); dragging a completed task
    /// somewhere else reopens it first.
    func move(_ id: UUID, to column: TaskColumn) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if column == .completed {
            complete(at: index)
            return
        }
        if items[index].isCompleted {
            reopen(at: index)
        }
        items[index].column = column
        items[index].columnIsManual = true
    }

    // MARK: - Completion internals

    private func complete(at index: Int) {
        var task = items[index]
        task.isCompleted = true
        task.completedAt = Date()
        task.column = .completed
        task.columnIsManual = true
        items[index] = task

        // Every occurrence is a real task, so completing one just completes
        // it. What keeps a perpetual series from running dry is extending the
        // runway by one each time.
        if let seriesID = task.seriesID { topUpSeries(seriesID) }
    }

    /// Appends one more occurrence to the end of a perpetual series, so the
    /// board always holds roughly `RepeatRule.perpetualCount` pending copies
    /// no matter how many get completed. A series with an end date was
    /// materialised in full up front and is deliberately left alone.
    private func topUpSeries(_ seriesID: UUID, now: Date = Date(), calendar: Calendar = .current) {
        let members = seriesMembers(seriesID)
        guard let template = members.last,
              template.repeatRule != .none,
              template.seriesEndDate == nil,
              let start = members.first?.dueDate,
              let latest = members.compactMap(\.dueDate).max() else { return }

        // The next index is however many occurrences the series already has;
        // nudge it forward if some were deleted, so the new due date is
        // always strictly after the latest one already on the board.
        var index = members.count
        let ceiling = index + RepeatRule.maxCount
        while index < ceiling {
            guard let candidate = template.repeatRule.occurrence(
                index: index, from: start, weekdays: template.repeatWeekdays,
                calendar: calendar) else { return }
            if candidate > latest {
                var next = template
                next.id = UUID()
                next.dueDate = candidate
                next.isCompleted = false
                next.completedAt = nil
                next.createdAt = now
                next.column = TaskColumn.automatic(forDueDate: candidate, now: now, calendar: calendar)
                next.columnIsManual = false
                next.manualOrder = TodoItem.dateOrderValue(for: candidate)
                items.append(next)
                return
            }
            index += 1
        }
    }

    private func reopen(at index: Int) {
        var task = items[index]
        task.isCompleted = false
        task.completedAt = nil
        task.columnIsManual = false
        task.column = defaultColumn(for: task.dueDate)
        task.manualOrder = TodoItem.dateOrderValue(for: task.dueDate)
        items[index] = task
    }

    // MARK: - Columns

    /// Where a task lands by default: Upcoming if due within 7 days
    /// (overdue counts as due), otherwise the backlog ("All Tasks").
    private func defaultColumn(for dueDate: Date?, now: Date = Date(), calendar: Calendar = .current) -> TaskColumn {
        TaskColumn.automatic(forDueDate: dueDate, now: now, calendar: calendar)
    }

    /// Promotes backlog tasks into Upcoming once their due date comes within
    /// 7 days. Never touches a task the user has manually placed, and never
    /// demotes — it's a one-way, additive check safe to call often.
    func recomputeAutoColumns(now: Date = Date()) {
        for index in items.indices {
            let task = items[index]
            guard !task.columnIsManual, !task.isCompleted, task.column == .backlog else { continue }
            let target = defaultColumn(for: task.dueDate, now: now)
            if target != .backlog { items[index].column = target }
        }
    }

    // MARK: - Reordering

    /// Drag a card onto another card: joins that card's column + subject
    /// group and is inserted immediately before it. Manual from then on.
    func reorder(_ id: UUID, before targetID: UUID) {
        guard id != targetID,
              let sourceIndex = items.firstIndex(where: { $0.id == id }),
              let target = items.first(where: { $0.id == targetID }) else { return }

        let siblings = items
            .filter { $0.column == target.column && $0.course == target.course && $0.id != id }
            .sorted { $0.manualOrder < $1.manualOrder }
        let targetPosition = siblings.firstIndex(where: { $0.id == targetID }) ?? 0
        let before = targetPosition > 0 ? siblings[targetPosition - 1].manualOrder : nil
        let newOrder = before.map { ($0 + target.manualOrder) / 2 } ?? (target.manualOrder - 1)

        if items[sourceIndex].isCompleted, target.column != .completed {
            reopen(at: sourceIndex)
        }
        items[sourceIndex].manualOrder = newOrder
        items[sourceIndex].column = target.column
        items[sourceIndex].course = target.course
        items[sourceIndex].columnIsManual = true
    }

    /// Resets every task's sort position back to chronological (due-date)
    /// order, discarding any manual drag-reordering.
    func resetSortToDate() {
        for index in items.indices {
            items[index].manualOrder = TodoItem.dateOrderValue(for: items[index].dueDate)
        }
    }

    // MARK: - Queries

    var courses: [String] {
        Array(Set(items.compactMap(\.course))).sorted()
    }

    struct SubjectGroup: Identifiable {
        let subject: String
        let tasks: [TodoItem]
        var id: String { subject }
    }

    static let noCategoryLabel = "No Category"

    func count(in column: TaskColumn, course: String?) -> Int {
        items.filter { $0.column == column && (course == nil || $0.course == course) }.count
    }

    /// Tasks in a column, grouped by subject (course) — subjects alphabetical
    /// with "No Category" last, tasks within a group in manual/date order
    /// (or by completion recency for the Completed column).
    func groupedTasks(in column: TaskColumn, course: String?) -> [SubjectGroup] {
        let filtered = items.filter { $0.column == column && (course == nil || $0.course == course) }
        let buckets = Dictionary(grouping: filtered) { $0.course ?? Self.noCategoryLabel }
        let subjects = buckets.keys.sorted { lhs, rhs in
            if lhs == Self.noCategoryLabel { return false }
            if rhs == Self.noCategoryLabel { return true }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
        return subjects.map { subject in
            let tasks = (buckets[subject] ?? []).sorted { lhs, rhs in
                if column == .completed {
                    return (lhs.completedAt ?? .distantPast) > (rhs.completedAt ?? .distantPast)
                }
                if lhs.manualOrder != rhs.manualOrder { return lhs.manualOrder < rhs.manualOrder }
                return lhs.createdAt < rhs.createdAt
            }
            return SubjectGroup(subject: subject, tasks: tasks)
        }
    }

    var completedCount: Int {
        items.filter(\.isCompleted).count
    }

    func completedCount(since startDate: Date) -> Int {
        items.filter { $0.isCompleted && ($0.completedAt ?? .distantPast) >= startDate }.count
    }
}
