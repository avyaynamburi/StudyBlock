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
        dropDuplicateIDs()
        migrateLegacySeries()
        recomputeAutoColumns()
    }

    /// Two tasks sharing an id is unrecoverable for the board — `ForEach`
    /// needs them unique, and a lookup by id would reach whichever came
    /// first — so any repeat is dropped at load. Nothing should produce one;
    /// this is a floor under the bugs that would.
    private func dropDuplicateIDs() {
        var seen = Set<UUID>()
        let deduplicated = items.filter { seen.insert($0.id).inserted }
        guard deduplicated.count != items.count else { return }
        items = deduplicated
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
                items[index].repeatInterval = task.repeatInterval
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

    /// The board's categories paired with the CSV color word each one uses,
    /// for the AI prompt — so a generated file joins the categories already
    /// in use instead of inventing near-duplicates of them.
    var csvCategories: [(name: String, color: String)] {
        courses.map { (name: $0, color: TaskCSV.nearestColorName(for: hue(for: $0))) }
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
        add(title: parsed.title, course: parsed.course ?? courseOverride, dueDate: parsed.dueDate)
    }

    /// Creates a task from the editor — the one entry point for both kinds.
    /// With a repeat rule set it's materialised: every occurrence becomes a
    /// real, independent task on the board sharing one `seriesID`. A series
    /// with an end date is expanded in full (up to `RepeatRule.maxCount`); a
    /// perpetual one gets `RepeatRule.perpetualCount` occurrences of runway,
    /// which `topUpSeries` extends as they're completed.
    ///
    /// Returns how many tasks actually landed on the board.
    @discardableResult
    func add(title: String, notes: String = "", course: String? = nil, dueDate: Date? = nil,
             repeatRule: RepeatRule = .none, repeatWeekdays: Set<Int> = [],
             repeatInterval: Int = 1, seriesEndDate: Date? = nil) -> Int {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        var template = TodoItem(title: trimmed, notes: notes, course: course, dueDate: dueDate,
                                repeatRule: repeatRule, repeatWeekdays: repeatWeekdays)
        template.repeatInterval = repeatInterval
        template.seriesEndDate = seriesEndDate

        // A repeat rule counts from a start date, so an undated task is a
        // single plain card no matter which rule came in.
        guard repeatRule != .none, let dueDate else {
            template.repeatRule = .none
            template.repeatWeekdays = []
            template.repeatInterval = 1
            template.seriesEndDate = nil
            template.column = defaultColumn(for: dueDate)
            template.manualOrder = TodoItem.dateOrderValue(for: dueDate)
            items.append(template)
            return 1
        }

        template.seriesID = UUID()
        let created = template.materializedSeries(from: dueDate)
        // A rule that yields no dates (an end date on or before the start)
        // would otherwise swallow the task whole.
        guard !created.isEmpty else { return 0 }
        items.append(contentsOf: created)
        return created.count
    }

    /// Saves an edit to a single task. Turning on a repeat rule for a task
    /// that isn't already part of a series promotes it into one, replacing
    /// the single card with the whole materialised run — the same thing
    /// checking "Repeats" in the task editor asks for.
    @discardableResult
    func update(_ item: TodoItem) -> Int {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return 0 }

        if item.seriesID == nil, item.repeatRule != .none,
           !item.isCompleted, let due = item.dueDate {
            var template = item
            template.seriesID = UUID()
            let created = template.materializedSeries(from: due)
            guard !created.isEmpty else {
                // The rule produced no dates (an end date on or before the
                // start). Keep the task, but drop the repeat rule: a task
                // carrying a rule with no series id is exactly what
                // `migrateLegacySeries` expands on the next launch, so leaving
                // it would turn one card into a whole series behind the
                // user's back.
                var plain = item
                plain.repeatRule = .none
                plain.repeatWeekdays = []
                plain.repeatInterval = 1
                plain.seriesEndDate = nil
                items[index] = plain
                return 0
            }
            items.remove(at: index)
            items.append(contentsOf: created)
            return created.count
        }

        var updated = item
        // An occurrence saved without a repeat rule is no longer part of the
        // schedule — it's a one-off pulled out of the series. Cutting the link
        // now keeps a later "edit/delete the whole series" from sweeping it up,
        // and matches what `migrateLegacySeries` does to that shape on load.
        if updated.repeatRule == .none, !updated.isCompleted {
            updated.seriesID = nil
            updated.seriesEndDate = nil
        }
        if !updated.isCompleted, !updated.columnIsManual {
            updated.column = defaultColumn(for: updated.dueDate)
        }
        // The board is one date-ordered list now, so changing a due date has
        // to move the card. A task the user dragged into a particular spot
        // keeps it: dragging is what makes `manualOrder` stop matching the due
        // date, and that mismatch is the only record we have that the
        // placement was deliberate.
        let existing = items[index]
        if updated.dueDate != existing.dueDate,
           existing.manualOrder == TodoItem.dateOrderValue(for: existing.dueDate) {
            updated.manualOrder = TodoItem.dateOrderValue(for: updated.dueDate)
        }
        items[index] = updated
        return 1
    }

    /// Rewrites a whole recurring series. Completed occurrences are left
    /// exactly as they are — they're a record of work actually done — while
    /// every pending one is replaced by a freshly materialised run from the
    /// new start date, so changing the schedule reshapes the future without
    /// rewriting the past.
    ///
    /// Clearing the repeat rule (or the due date) collapses the run back into
    /// a single plain task, which is what unchecking "Repeats" in the editor
    /// means.
    func updateSeries(seriesID: UUID, title: String, notes: String? = nil, course: String?,
                      dueDate: Date?, repeatRule: RepeatRule, repeatWeekdays: Set<Int>,
                      repeatInterval: Int = 1, seriesEndDate: Date?) {
        let members = items.filter { $0.seriesID == seriesID }
        guard let reference = members.first else { return }

        var template = reference
        template.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        template.course = course
        template.repeatRule = repeatRule
        template.repeatWeekdays = repeatWeekdays
        template.repeatInterval = repeatInterval
        template.seriesEndDate = seriesEndDate
        if let notes { template.notes = notes }
        guard !template.title.isEmpty else { return }

        // Keep the completed history, but bring its wording in line with the
        // edit so the series reads consistently on the board.
        for index in items.indices where items[index].seriesID == seriesID && items[index].isCompleted {
            items[index].title = template.title
            items[index].course = course
            items[index].repeatRule = repeatRule
            items[index].repeatWeekdays = repeatWeekdays
            items[index].repeatInterval = repeatInterval
            items[index].seriesEndDate = seriesEndDate
            if let notes { items[index].notes = notes }
        }

        let hadPending = members.contains { !$0.isCompleted }
        items.removeAll { $0.seriesID == seriesID && !$0.isCompleted }

        guard repeatRule != .none, let dueDate else {
            // Repeats switched off: what was a run becomes one ordinary task.
            // A series with nothing left to do has no future to collapse, so
            // it just keeps its history rather than resurrecting a card.
            guard hadPending else { return }
            var single = template
            single.id = UUID()
            single.seriesID = nil
            single.repeatRule = .none
            single.repeatWeekdays = []
            single.repeatInterval = 1
            single.seriesEndDate = nil
            single.dueDate = dueDate
            single.isCompleted = false
            single.completedAt = nil
            single.column = defaultColumn(for: dueDate)
            single.columnIsManual = false
            single.manualOrder = TodoItem.dateOrderValue(for: dueDate)
            items.append(single)
            return
        }

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

    // MARK: - Canvas

    /// The one category every imported assignment lands in, so Canvas work is
    /// filterable as a group and visibly distinct from tasks you wrote.
    static let canvasCategory = "Canvas"

    struct CanvasSyncSummary: Equatable {
        var added = 0
        var updated = 0
        var unchanged = 0
        /// Feed entries that were course events, not assignments. Counted
        /// rather than imported — a room booking isn't something to tick off.
        var skippedEvents = 0

        var headline: String {
            var parts: [String] = []
            if added > 0 { parts.append("\(added) added") }
            if updated > 0 { parts.append("\(updated) updated") }
            if parts.isEmpty { return "Already up to date" }
            return parts.joined(separator: ", ")
        }

        var detail: String {
            var lines: [String] = []
            if unchanged > 0 {
                lines.append("\(unchanged) assignment\(unchanged == 1 ? " was" : "s were") already on the board.")
            }
            if skippedEvents > 0 {
                lines.append("Skipped \(skippedEvents) calendar event\(skippedEvents == 1 ? "" : "s") \u{2014} "
                             + "only assignments are imported.")
            }
            return lines.joined(separator: " ")
        }
    }

    /// Folds a fetched Canvas feed into the board.
    ///
    /// Identity is the feed's UID, which is what makes a re-sync idempotent:
    /// an assignment already here is updated in place rather than duplicated.
    /// The stored content hash is what separates "seen again" from "actually
    /// changed", so a professor moving a deadline moves the card, while a
    /// sync of an unchanged feed does nothing at all.
    ///
    /// Two things it deliberately never does: it never reopens a task you
    /// have completed, and it never deletes a task that has dropped out of
    /// the feed. Both would destroy your own work on the strength of a feed
    /// Canvas only regenerates on a cache interval.
    /// The category course events land in when `includeEvents` is on. Kept
    /// separate from the assignment category so the feed's due/starts
    /// distinction survives onto the board — an event is something that
    /// starts, never something that is "due".
    static let canvasEventCategory = "Canvas Events"

    @discardableResult
    func mergeCanvas(_ items: [CanvasItem], includeEvents: Bool = false,
                     now: Date = Date(),
                     calendar: Calendar = .current) -> CanvasSyncSummary {
        var summary = CanvasSyncSummary()
        // Built once per sync, so a feed of 300 assignments isn't a linear
        // scan apiece.
        var existing: [String: Int] = [:]
        for (index, task) in self.items.enumerated() {
            if let uid = task.canvasUID { existing[uid] = index }
        }

        for item in items {
            guard item.kind == .assignment || includeEvents else {
                summary.skippedEvents += 1
                continue
            }
            guard let when = item.when,
                  let due = CanvasNormalizer.localDueDate(when, calendar: calendar) else { continue }
            let category = item.kind == .assignment ? Self.canvasCategory : Self.canvasEventCategory

            guard let index = existing[item.sourceID] else {
                var task = TodoItem(title: item.qualifiedTitle,
                                    course: category,
                                    dueDate: due)
                task.canvasUID = item.sourceID
                task.canvasHash = item.contentHash
                task.column = defaultColumn(for: due, now: now, calendar: calendar)
                task.manualOrder = TodoItem.dateOrderValue(for: due)
                self.items.append(task)
                summary.added += 1
                continue
            }

            guard self.items[index].canvasHash != item.contentHash else {
                summary.unchanged += 1
                continue
            }

            var task = self.items[index]
            let previousDue = task.dueDate
            task.title = item.qualifiedTitle
            task.course = category
            task.dueDate = due
            task.canvasHash = item.contentHash
            // A completed assignment stays completed even when its deadline
            // moves; the hash is still refreshed so it stops re-reporting.
            if !task.isCompleted {
                if !task.columnIsManual {
                    task.column = defaultColumn(for: due, now: now, calendar: calendar)
                }
                // The same rule the task editor uses: a card the user dragged
                // into a particular spot keeps it, because that mismatch is
                // the only record that the placement was deliberate.
                if previousDue != due,
                   task.manualOrder == TodoItem.dateOrderValue(for: previousDue) {
                    task.manualOrder = TodoItem.dateOrderValue(for: due)
                }
            }
            self.items[index] = task
            summary.updated += 1
        }
        return summary
    }

    /// How many tasks on the board came from Canvas.
    var canvasCount: Int {
        items.filter(\.isFromCanvas).count
    }

    // MARK: - Merging

    /// Folds two cards into one: the survivor is rewritten with the merged
    /// fields and the absorbed card is removed.
    ///
    /// Because the merged card inherits the Canvas UID, a later sync matches
    /// it by identity and updates it in place — which is what stops the
    /// duplicate coming straight back on the next pull.
    @discardableResult
    func applyMerge(_ plan: TaskMergePlan) -> TodoItem? {
        guard let index = items.firstIndex(where: { $0.id == plan.primary.id }),
              items.contains(where: { $0.id == plan.secondary.id }) else { return nil }
        let merged = plan.merged()
        items[index] = merged
        items.removeAll { $0.id == plan.secondary.id }
        return merged
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

    /// "Delete all" as asked from one occurrence: every pending occurrence,
    /// plus `item` itself even when it's already completed — whichever card
    /// the user hit delete on should always be the one that disappears.
    /// Other completed occurrences stay as a record of work done.
    func deleteSeries(containing item: TodoItem) {
        guard let seriesID = item.seriesID else {
            delete(item)
            return
        }
        items.removeAll { $0.seriesID == seriesID && (!$0.isCompleted || $0.id == item.id) }
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

    /// Whether a perpetual series needs another occurrence appended: only once
    /// nothing is left to do in it.
    ///
    /// This used to fire on *every* completion, which is what let a single
    /// checkbox breed. Completing a card appended a replacement; reopening it
    /// handed the original back without withdrawing that replacement; so each
    /// check/uncheck cycle left the series one card longer — one going to
    /// Completed and a brand new one appearing in All Tasks, over and over.
    ///
    /// Running dry is the only threshold that can't do that. Any higher
    /// low-water mark grows a series whose pending count already sits below
    /// it, which is exactly the case for a series that reached the board with
    /// only a card or two in the first place.
    nonisolated static func needsRunwayTopUp(members: [TodoItem]) -> Bool {
        !members.contains { !$0.isCompleted }
    }

    /// Appends one more occurrence to a perpetual series that has run out, so
    /// it never dries up. A series with an end date was materialised in full
    /// up front and is deliberately left alone.
    private func topUpSeries(_ seriesID: UUID, now: Date = Date(), calendar: Calendar = .current) {
        let members = seriesMembers(seriesID)
        guard Self.needsRunwayTopUp(members: members),
              let template = members.last,
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
                interval: template.repeatInterval, calendar: calendar) else { return }
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

    /// Drag a card onto another card: joins that card's column and is
    /// inserted immediately before it. Manual from then on.
    ///
    /// Dropping onto a card used to adopt its category too, because a card's
    /// position only meant something inside its category's group. Now that a
    /// column is one flat list, moving a card is just a move — rewriting the
    /// category from underneath the user would be a surprise.
    func reorder(_ id: UUID, before targetID: UUID) {
        guard id != targetID,
              let sourceIndex = items.firstIndex(where: { $0.id == id }),
              let target = items.first(where: { $0.id == targetID }) else { return }

        let siblings = items
            .filter { $0.column == target.column && $0.id != id }
            .sorted { $0.manualOrder < $1.manualOrder }
        let targetPosition = siblings.firstIndex(where: { $0.id == targetID }) ?? 0
        let before = targetPosition > 0 ? siblings[targetPosition - 1].manualOrder : nil
        let newOrder = before.map { ($0 + target.manualOrder) / 2 } ?? (target.manualOrder - 1)

        if items[sourceIndex].isCompleted, target.column != .completed {
            reopen(at: sourceIndex)
        }
        items[sourceIndex].manualOrder = newOrder
        items[sourceIndex].column = target.column
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

    func count(in column: TaskColumn, course: String?) -> Int {
        items.filter { $0.column == column && (course == nil || $0.course == course) }.count
    }

    /// Tasks in a column as one flat, chronological list: soonest due first,
    /// undated last, or most recently finished first in Completed.
    ///
    /// The sort key is `manualOrder` rather than the due date itself. It
    /// starts out *as* the due date, so the default order is chronological
    /// anyway, and it only diverges where the user has dragged a card into a
    /// particular spot — which is what keeps drag-to-reorder meaningful and
    /// what "Sort by Date" resets.
    func tasks(in column: TaskColumn, course: String?) -> [TodoItem] {
        items
            .filter { $0.column == column && (course == nil || $0.course == course) }
            .sorted { lhs, rhs in
                if column == .completed {
                    return (lhs.completedAt ?? .distantPast) > (rhs.completedAt ?? .distantPast)
                }
                if lhs.manualOrder != rhs.manualOrder { return lhs.manualOrder < rhs.manualOrder }
                return lhs.createdAt < rhs.createdAt
            }
    }

    var completedCount: Int {
        items.filter(\.isCompleted).count
    }

    func completedCount(since startDate: Date) -> Int {
        items.filter { $0.isCompleted && ($0.completedAt ?? .distantPast) >= startDate }.count
    }
}
