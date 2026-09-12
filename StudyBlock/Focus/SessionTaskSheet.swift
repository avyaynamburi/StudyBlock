import SwiftUI

/// Which tasks to offer when a session is starting, and in what order.
///
/// Pure and separate from the sheet because the ordering is the part with
/// opinions in it — what you are already doing, then what is closest to being
/// late — and opinions are worth a test.
enum SessionTaskSuggestions {
    /// Tasks to show for `query`, best first.
    ///
    /// An empty query is the interesting case: the list has to be useful
    /// before a single character is typed, or the field is just a chore
    /// between you and the Start button.
    static func matches(_ query: String, in tasks: [TodoItem], limit: Int = 6) -> [TodoItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let open = tasks.filter { !$0.isCompleted }
        let pool = needle.isEmpty ? open : open.filter { task in
            task.title.lowercased().contains(needle)
                || (task.course?.lowercased().contains(needle) ?? false)
        }
        return Array(pool.sorted { rank($0, needle) < rank($1, needle) }.prefix(max(0, limit)))
    }

    /// True when nothing offered is already called exactly this, so the sheet
    /// should offer to make it. Compared case-insensitively: two tasks whose
    /// titles differ only in capitals are the same task to a human.
    static func canCreate(_ query: String, in tasks: [TodoItem]) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !tasks.contains { $0.title.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// Sort key. Swift tuples compare left to right, which is exactly the
    /// priority order: a title that *starts* with what you typed, then what
    /// you already said you were doing, then the nearest deadline, then the
    /// title so the order never wobbles between two equal tasks.
    private static func rank(_ task: TodoItem, _ needle: String) -> (Int, Int, Double, String) {
        let startsWith = !needle.isEmpty && task.title.lowercased().hasPrefix(needle)
        return (startsWith ? 0 : 1,
                task.column == .doing ? 0 : 1,
                TodoItem.dateOrderValue(for: task.dueDate),
                task.title.lowercased())
    }
}

/// Asked before a session starts: what are you working on?
///
/// The point is not bookkeeping. A session with a task on it accrues to that
/// subject in the stats, and has something to ask about when it ends — a
/// session without one can do neither.
struct SessionTaskSheet: View {
    let tasks: [TodoItem]
    let courseColor: (String) -> Color
    /// Hands back the task to run the session on, or nil for "just focus".
    /// A brand-new task arrives here already on the board.
    let onStart: (TodoItem?) -> Void
    let onCreate: (String) -> TodoItem?

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: UUID?
    @FocusState private var fieldFocused: Bool

    private var suggestions: [TodoItem] {
        SessionTaskSuggestions.matches(query, in: tasks)
    }

    private var canCreate: Bool {
        SessionTaskSuggestions.canCreate(query, in: tasks)
    }

    private var selectedTask: TodoItem? {
        suggestions.first { $0.id == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What are you working on?")
                    .font(Theme.ui(17, .semibold))
                Text("Pick something from your board, or type what you're about to do.")
                    .font(Theme.ui(11))
                    .foregroundStyle(.secondary)
            }

            TextField("e.g. Problem Set 5", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.ui(13))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Theme.surfaceLow, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1))
                .focused($fieldFocused)
                .onSubmit(start)
                // Typing is a new intention: whatever was highlighted before
                // is no longer what the list is showing.
                .onChange(of: query) { _ in selection = nil }

            if canCreate {
                createRow
            }

            if suggestions.isEmpty && !canCreate {
                Text("Nothing on the board yet. Type what you're working on and it becomes a task.")
                    .font(Theme.ui(11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
            } else {
                VStack(spacing: 0) {
                    ForEach(suggestions) { task in
                        taskRow(task)
                        if task.id != suggestions.last?.id {
                            Divider().overlay(Theme.stroke)
                        }
                    }
                }
                .background(Theme.surfaceLow, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1))
            }

            HStack(spacing: 10) {
                Button("Just Focus") { dismiss(); onStart(nil) }
                    .buttonStyle(SoftPillButtonStyle())
                    .help("Start without linking the session to a task")
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SoftPillButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(action: start) {
                    Label("Start", systemImage: "play.fill")
                }
                .buttonStyle(ProminentPillButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(Theme.surface)
        .onAppear { fieldFocused = true }
    }

    private var createRow: some View {
        Button {
            selection = nil
            start()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(Theme.accent)
                Text("Start on a new task \u{201C}\(query.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}")
                    .font(Theme.ui(12, .medium))
                    .lineLimit(1)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func taskRow(_ task: TodoItem) -> some View {
        Button {
            selection = task.id
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selection == task.id ? "largecircle.fill.circle" : "circle")
                    .font(Theme.ui(12))
                    .foregroundStyle(selection == task.id ? Theme.accent : .secondary)
                Text(task.title)
                    .font(Theme.ui(12))
                    .lineLimit(1)
                if let course = task.course {
                    TagChip(text: course, color: courseColor(course))
                }
                Spacer()
                if task.column == .doing {
                    Text("doing")
                        .font(Theme.ui(9, .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    /// Start on whatever is selected, else on what was typed, else on
    /// nothing — the same order the sheet reads top to bottom.
    private func start() {
        // Dismiss first: starting the session is what pulls the presenting
        // card off screen.
        dismiss()
        if let selectedTask {
            onStart(selectedTask)
        } else if canCreate {
            onStart(onCreate(query))
        } else {
            // Typed a title that already exists: run on that task rather than
            // making a second one with the same name.
            onStart(suggestions.first { $0.title.caseInsensitiveCompare(
                query.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame })
        }
    }
}
