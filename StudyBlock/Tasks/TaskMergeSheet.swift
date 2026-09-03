import SwiftUI

/// The menu that opens for every merge, without exception.
///
/// Each field arrives pre-decided by `TaskMergePlan.autofilled`, so the
/// common case is reading it and pressing Merge — but nothing is applied
/// until that press, and every choice can be flipped first.
struct TaskMergeSheet: View {
    /// The card the merge started from. When `partner` is nil the sheet opens
    /// on a picker instead, so "Merge with…" and a drop both land here.
    let primary: TodoItem
    var partner: TodoItem?
    let candidates: [TodoItem]
    var courseColor: (String) -> Color = { _ in Theme.accent }
    let onMerge: (TaskMergePlan) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var plan: TaskMergePlan?
    @State private var search = ""

    init(primary: TodoItem, partner: TodoItem? = nil, candidates: [TodoItem],
         courseColor: @escaping (String) -> Color = { _ in Theme.accent },
         onMerge: @escaping (TaskMergePlan) -> Void) {
        self.primary = primary
        self.partner = partner
        self.candidates = candidates
        self.courseColor = courseColor
        self.onMerge = onMerge
        _plan = State(initialValue: partner.map { TaskMergePlan.autofilled(primary, $0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(plan == nil ? "Merge With\u{2026}" : "Merge Tasks")
                    .font(Theme.ui(16, .semibold))
                Text(plan == nil
                     ? "Pick the other card holding the same piece of work."
                     : "Two cards become one. The other is removed.")
                    .font(Theme.ui(10))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            if let plan {
                resolutionPage(plan)
            } else {
                pickerPage
            }

            footer
        }
        .frame(width: 470, height: 560)
        .background(Theme.bg)
    }

    // MARK: Choosing the other card

    private var filtered: [TodoItem] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let pool = candidates.filter { $0.id != primary.id && TaskMergePlan.refusal(primary, $0) == nil }
        let matched = query.isEmpty ? pool : pool.filter {
            $0.title.lowercased().contains(query) || ($0.course?.lowercased().contains(query) ?? false)
        }
        // Likeliest partners first: the same category, then whatever is due
        // nearest this card's own deadline.
        return matched.sorted { lhs, rhs in
            let lhsCourse = lhs.course == primary.course
            let rhsCourse = rhs.course == primary.course
            if lhsCourse != rhsCourse { return lhsCourse }
            return distance(lhs) < distance(rhs)
        }
    }

    private func distance(_ task: TodoItem) -> TimeInterval {
        guard let a = task.dueDate, let b = primary.dueDate else { return .greatestFiniteMagnitude }
        return abs(a.timeIntervalSince(b))
    }

    private var pickerPage: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(Theme.ui(11))
                    .foregroundStyle(.secondary)
                TextField("Search tasks", text: $search).textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 1))

            ScrollView {
                VStack(spacing: 0) {
                    if filtered.isEmpty {
                        Text(candidates.count <= 1
                             ? "There\u{2019}s nothing else on the board to merge with."
                             : "No task matches that.")
                            .font(Theme.ui(11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 30)
                    }
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, task in
                        if index > 0 { Divider().overlay(Theme.stroke) }
                        Button {
                            plan = TaskMergePlan.autofilled(primary, task)
                        } label: {
                            HStack(spacing: 8) {
                                taskSummary(task)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(Theme.ui(10, .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1))
            }
        }
        .padding(.horizontal, 20)
    }

    private func taskSummary(_ task: TodoItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(task.title).font(Theme.ui(12, .medium)).lineLimit(1)
            HStack(spacing: 6) {
                if let course = task.course {
                    TagChip(text: course, color: courseColor(course))
                }
                if let due = task.dueDate {
                    Text(TaskCard.dueLabel(for: due))
                        .font(Theme.ui(10))
                        .foregroundStyle(.secondary)
                } else {
                    Text("No due date").font(Theme.ui(10)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: Resolving the fields

    private func resolutionPage(_ current: TaskMergePlan) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                field("Title", agree: current.titlesAgree,
                      selection: Binding(get: { plan?.titleSide ?? .primary },
                                         set: { plan?.titleSide = $0 })) { side in
                    Text(current.task(on: side).title).font(Theme.ui(12))
                }

                field("Due", agree: current.duesAgree,
                      selection: Binding(get: { plan?.dueSide ?? .primary },
                                         set: { plan?.dueSide = $0 })) { side in
                    if let due = current.task(on: side).dueDate {
                        Text(TaskCard.dueLabel(for: due)).font(Theme.ui(12))
                    } else {
                        Text("No due date").font(Theme.ui(12)).foregroundStyle(.secondary)
                    }
                }

                field("Category", agree: current.coursesAgree,
                      selection: Binding(get: { plan?.courseSide ?? .primary },
                                         set: { plan?.courseSide = $0 })) { side in
                    if let course = current.task(on: side).course {
                        TagChip(text: course, color: courseColor(course))
                    } else {
                        Text("No category").font(Theme.ui(12)).foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("NOTES").font(Theme.ui(10, .semibold)).foregroundStyle(.secondary).kerning(0.5)
                    TextField("Notes", text: Binding(get: { plan?.notes ?? "" },
                                                     set: { plan?.notes = $0 }),
                              axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(Theme.ui(12))
                        .lineLimit(2...5)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Theme.stroke, lineWidth: 1))
                }

                if current.detachesFromSeries {
                    Label("This card leaves its repeating series and becomes a single task. "
                          + "The other occurrences carry on untouched.",
                          systemImage: "repeat.circle")
                        .font(Theme.ui(10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if current.canvasSide != nil {
                    Label("Keeps the Canvas link, so future syncs update this card instead of "
                          + "importing the duplicate again.", systemImage: "link")
                        .font(Theme.ui(10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Label("\u{201C}\(current.secondary.title)\u{201D} is removed. Anything you keep "
                      + "above moves onto the card that stays.",
                      systemImage: "arrow.triangle.merge")
                    .font(Theme.ui(10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 4)
        }
    }

    /// One field: both candidate values as a pair of radio rows, or a single
    /// static row when the two cards already agree and there is no choice.
    @ViewBuilder
    private func field<Content: View>(_ label: String, agree: Bool,
                                      selection: Binding<MergeSide>,
                                      @ViewBuilder value: @escaping (MergeSide) -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(Theme.ui(10, .semibold))
                .foregroundStyle(.secondary)
                .kerning(0.5)

            VStack(spacing: 0) {
                if agree {
                    HStack {
                        value(.primary)
                        Spacer(minLength: 0)
                        Text("both the same").font(Theme.ui(10)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                } else {
                    ForEach(MergeSide.allCases) { side in
                        if side == .secondary { Divider().overlay(Theme.stroke) }
                        Button {
                            selection.wrappedValue = side
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: selection.wrappedValue == side
                                      ? "largecircle.fill.circle" : "circle")
                                    .font(Theme.ui(12))
                                    .foregroundStyle(selection.wrappedValue == side
                                                     ? Theme.accent : .secondary)
                                value(side)
                                Spacer(minLength: 0)
                                Text(sideLabel(side))
                                    .font(Theme.ui(10))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 1))
        }
    }

    /// Names a side by where it came from, which is what the choice actually
    /// turns on.
    private func sideLabel(_ side: MergeSide) -> String {
        guard let plan else { return "" }
        if plan.task(on: side).isFromCanvas { return "from Canvas" }
        return side == .primary ? "this card" : "other card"
    }

    private var footer: some View {
        HStack {
            if plan != nil, partner == nil {
                Button("Back") { plan = nil }
                    .buttonStyle(SoftPillButtonStyle())
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(SoftPillButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("Merge") {
                if let plan { onMerge(plan) }
                dismiss()
            }
            .buttonStyle(ProminentPillButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(plan == nil)
        }
        .padding(20)
    }
}
