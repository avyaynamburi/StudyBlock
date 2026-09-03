import Foundation

/// Which of the two cards a merged field came from.
enum MergeSide: String, CaseIterable, Identifiable, Equatable {
    case primary, secondary
    var id: String { rawValue }
}

/// Two cards that are really the same piece of work, and the choices that
/// turn them into one.
///
/// Every field is pre-decided by `autofilled`, and every decision is
/// overridable — the merge sheet always opens, so nothing here is ever
/// applied behind the user's back.
struct TaskMergePlan: Equatable {
    /// The card that survives: it keeps its id, its place on the board, and
    /// its creation date, so a merge doesn't look like a delete and an add.
    var primary: TodoItem
    /// The card that is absorbed and then removed.
    var secondary: TodoItem

    var titleSide: MergeSide
    var dueSide: MergeSide
    var courseSide: MergeSide
    /// Notes are joined rather than chosen — a merge should never be the
    /// reason a paragraph you wrote disappears.
    var notes: String

    // MARK: Autofill

    /// Builds the plan with every field pre-decided.
    ///
    /// The survivor is the hand-made card whenever exactly one side came from
    /// Canvas. That is what makes the merge self-correcting: the Canvas UID
    /// moves onto the card you actually keep, so the next sync updates it in
    /// place instead of re-importing the duplicate.
    static func autofilled(_ a: TodoItem, _ b: TodoItem) -> TaskMergePlan {
        // Order the pair so `primary` is the survivor.
        let primary: TodoItem
        let secondary: TodoItem
        if a.isFromCanvas && !b.isFromCanvas {
            primary = b
            secondary = a
        } else {
            // Neither is from Canvas, or both are: no rule prefers one, so
            // the card that was dropped onto wins. Arbitrary, but stable —
            // the same pair always resolves the same way, and the sheet is
            // right there to change it.
            primary = a
            secondary = b
        }

        let canvasSide: MergeSide? = primary.isFromCanvas ? .primary
            : (secondary.isFromCanvas ? .secondary : nil)

        func side(_ which: MergeSide) -> TodoItem { which == .primary ? primary : secondary }

        // Title: whatever you typed, not what Canvas calls it. With no Canvas
        // card in the pair there's nothing to prefer, so the survivor's wins.
        let titleSide: MergeSide = {
            guard let canvasSide else { return .primary }
            return canvasSide == .primary ? .secondary : .primary
        }()

        // Due date: Canvas is authoritative when both have one. When only one
        // side has a date at all, that side wins outright — a merge should
        // never throw away the only deadline in the pair.
        let dueSide: MergeSide = {
            let primaryHas = primary.dueDate != nil
            let secondaryHas = secondary.dueDate != nil
            if primaryHas != secondaryHas { return primaryHas ? .primary : .secondary }
            guard primaryHas, let canvasSide else { return .primary }
            return canvasSide
        }()

        // Category: drop the Canvas tag, keep your own course tag. If the
        // hand-made card never had one, the result has none either — the
        // point is to be rid of "Canvas", not to reinstate it.
        let courseSide: MergeSide = {
            guard let canvasSide else { return .primary }
            return canvasSide == .primary ? .secondary : .primary
        }()

        return TaskMergePlan(primary: primary, secondary: secondary,
                             titleSide: titleSide, dueSide: dueSide, courseSide: courseSide,
                             notes: joinedNotes(primary.notes, secondary.notes))
    }

    /// Both sets of notes, in order, with a blank line between. Identical or
    /// empty ones collapse rather than doubling up.
    static func joinedNotes(_ first: String, _ second: String) -> String {
        let a = first.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = second.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return b }
        if b.isEmpty || a == b { return a }
        return a + "\n\n" + b
    }

    // MARK: Reading the choices

    func task(on side: MergeSide) -> TodoItem { side == .primary ? primary : secondary }

    /// The side that came from Canvas, if exactly one did.
    var canvasSide: MergeSide? {
        if primary.isFromCanvas && !secondary.isFromCanvas { return .primary }
        if secondary.isFromCanvas && !primary.isFromCanvas { return .secondary }
        return nil
    }

    var resolvedTitle: String { task(on: titleSide).title }
    var resolvedDueDate: Date? { task(on: dueSide).dueDate }
    var resolvedCourse: String? { task(on: courseSide).course }

    /// True when both cards say the same thing for this field, so there is no
    /// choice to present.
    var titlesAgree: Bool { primary.title == secondary.title }
    var duesAgree: Bool { primary.dueDate == secondary.dueDate }
    var coursesAgree: Bool { primary.course == secondary.course }

    /// The single card the two become.
    ///
    /// It is the survivor with fields replaced, so its id, column, drag
    /// position, completion and creation date all carry through untouched.
    /// The Canvas identity is inherited from whichever side had it, which is
    /// the whole point: future syncs land on this card.
    func merged() -> TodoItem {
        var result = primary
        result.title = resolvedTitle
        result.notes = notes
        result.course = resolvedCourse
        result.dueDate = resolvedDueDate
        if let canvasSide {
            let source = task(on: canvasSide)
            result.canvasUID = source.canvasUID
            result.canvasHash = source.canvasHash
        }
        // A merged occurrence leaves its series. The rest of the run is
        // untouched, but this card can't stay a member: `updateSeries`
        // rebuilds every pending occurrence from scratch, which would throw
        // the merge away the next time the series was edited.
        //
        // Clearing the rule matters as much as clearing the id. A pending
        // task carrying a repeat rule with no series id is exactly the shape
        // `migrateLegacySeries` expands on the next launch — leaving it would
        // turn this one card into a whole new series behind the user's back.
        if result.seriesID != nil {
            result.seriesID = nil
            result.repeatRule = .none
            result.repeatWeekdays = []
            result.repeatInterval = 1
            result.seriesEndDate = nil
        }
        // A due date that changed has to move the card, unless it was dragged
        // somewhere deliberately — the same rule the task editor follows.
        if result.dueDate != primary.dueDate,
           primary.manualOrder == TodoItem.dateOrderValue(for: primary.dueDate) {
            result.manualOrder = TodoItem.dateOrderValue(for: result.dueDate)
        }
        return result
    }

    /// Why a pair can't be merged, or nil when it can.
    ///
    /// An occurrence of a recurring series is fair game: only that one card
    /// is folded in, and `merged()` detaches it so the other occurrences
    /// carry on exactly as they were.
    static func refusal(_ a: TodoItem, _ b: TodoItem) -> String? {
        a.id == b.id ? "That\u{2019}s the same task." : nil
    }

    /// True when merging will pull the surviving card out of a repeating
    /// series, which the sheet says out loud before anything happens.
    var detachesFromSeries: Bool { primary.seriesID != nil }
}
