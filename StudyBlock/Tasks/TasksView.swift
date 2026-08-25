import SwiftUI

struct TasksView: View {
    @EnvironmentObject private var store: TaskStore
    @EnvironmentObject private var timer: FocusTimerController
    @AppStorage("lockSessions") private var lockSessions = false
    @State private var quickAddText = ""
    @State private var courseFilter: String?
    @State private var editingTask: TodoItem?
    @State private var showCompleted = false
    @FocusState private var quickAddFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("Tasks", subtitle: openCountLabel) {
                courseFilterMenu
            }

            quickAddBar
                .padding(.horizontal, 28)
                .padding(.bottom, 16)

            taskList
        }
        .sheet(item: $editingTask) { task in
            TaskEditSheet(task: task) { updated in
                store.update(updated)
            } onDelete: {
                store.delete(task)
            }
        }
    }

    private var openCountLabel: String {
        let open = store.groupedOpenTasks(course: courseFilter).reduce(0) { $0 + $1.tasks.count }
        return open == 0 ? "All clear" : "\(open) open task\(open == 1 ? "" : "s")"
    }

    // MARK: - Quick add

    private var quickAddBar: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.accentGradient)
                    .frame(width: 26, height: 26)
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }
            TextField("Add a task — try: essay friday #history !!", text: $quickAddText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($quickAddFocused)
                .onSubmit {
                    store.quickAdd(quickAddText)
                    quickAddText = ""
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .strokeBorder(quickAddFocused ? Theme.accent.opacity(0.55) : Theme.stroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        .animation(.easeOut(duration: 0.15), value: quickAddFocused)
    }

    // MARK: - List

    private var taskList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(store.groupedOpenTasks(course: courseFilter), id: \.group) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader(section.group, count: section.tasks.count)
                        VStack(spacing: 0) {
                            ForEach(section.tasks) { task in
                                TaskRow(task: task, isOverdue: section.group == .overdue, onToggle: {
                                    store.toggleCompletion(task)
                                }, onFocus: timer.isRunning ? nil : {
                                    timer.start(minutes: timer.defaultMinutes, task: task, locked: lockSessions)
                                })
                                .contentShape(Rectangle())
                                .onTapGesture { editingTask = task }
                                if task.id != section.tasks.last?.id {
                                    Divider().overlay(Theme.stroke).padding(.leading, 46)
                                }
                            }
                        }
                        .card(padding: 6)
                    }
                }

                completedSection
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
        .overlay {
            if store.items.isEmpty {
                EmptyState(icon: "checklist",
                           title: "No tasks yet",
                           message: "Type above to add one — dates like \"friday\", #course tags and !! priority are picked up automatically.")
            }
        }
    }

    private func sectionHeader(_ group: TaskGroup, count: Int) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(sectionColor(group))
                .frame(width: 7, height: 7)
            Text(group.rawValue)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .kerning(0.6)
            Text("\(count)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, 4)
    }

    private func sectionColor(_ group: TaskGroup) -> Color {
        switch group {
        case .overdue: return Theme.danger
        case .today: return Theme.accent
        case .thisWeek: return Theme.violet
        case .later, .noDate: return .secondary.opacity(0.5)
        }
    }

    @ViewBuilder
    private var completedSection: some View {
        let completed = store.completedTasks(course: courseFilter)
        if !completed.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { showCompleted.toggle() }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(showCompleted ? 90 : 0))
                        Text("Completed")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .textCase(.uppercase)
                            .kerning(0.6)
                        Text("\(completed.count)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showCompleted {
                    VStack(spacing: 0) {
                        ForEach(completed) { task in
                            TaskRow(task: task, isOverdue: false) {
                                store.toggleCompletion(task)
                            }
                            if task.id != completed.last?.id {
                                Divider().overlay(Theme.stroke).padding(.leading, 46)
                            }
                        }
                    }
                    .card(padding: 6)
                }
            }
        }
    }

    private var courseFilterMenu: some View {
        Menu {
            Button("All Courses") { courseFilter = nil }
            Divider()
            ForEach(store.courses, id: \.self) { course in
                Button(course) { courseFilter = course }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 11, weight: .semibold))
                Text(courseFilter ?? "All Courses")
            }
        }
        .menuStyle(.button)
        .buttonStyle(SoftPillButtonStyle(tint: courseFilter != nil ? Theme.accent : nil))
        .fixedSize()
        .disabled(store.courses.isEmpty)
    }
}

struct TaskRow: View {
    let task: TodoItem
    let isOverdue: Bool
    let onToggle: () -> Void
    var onFocus: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 11) {
            Button(action: onToggle) {
                ZStack {
                    Circle()
                        .strokeBorder(task.isCompleted ? .clear : (hovering ? Theme.accent : Color.secondary.opacity(0.45)), lineWidth: 1.5)
                        .background(Circle().fill(task.isCompleted ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(.clear)))
                        .frame(width: 19, height: 19)
                    if task.isCompleted {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: task.isCompleted)
            .help(task.isCompleted ? "Mark incomplete" : "Mark complete")

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .strikethrough(task.isCompleted)
                    .foregroundStyle(task.isCompleted ? .secondary : .primary)
                if !task.notes.isEmpty {
                    Text(task.notes).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if let onFocus, !task.isCompleted, hovering {
                Button(action: onFocus) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(IconButtonStyle(tint: Theme.accent))
                .help("Start a focus session on this task")
                .transition(.opacity)
            }

            if task.repeatRule != .none {
                Image(systemName: "repeat")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            if let course = task.course {
                TagChip(text: course, color: Theme.courseColor(course))
            }
            if let due = task.dueDate {
                Text(Self.dueLabel(for: due))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isOverdue ? Theme.danger : .secondary)
            }
            if task.priority != .none {
                Image(systemName: "flag.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(priorityColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hovering ? Theme.surfaceLow.opacity(0.7) : .clear)
        )
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }

    private var priorityColor: Color {
        switch task.priority {
        case .high: return Theme.danger
        case .medium: return Theme.amber
        default: return Theme.accent
        }
    }

    static func dueLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateFormat = calendar.isDate(date, equalTo: .now, toGranularity: .year) ? "E, MMM d" : "MMM d, yyyy"
        return formatter.string(from: date)
    }
}

struct TaskEditSheet: View {
    @State var task: TodoItem
    let onSave: (TodoItem) -> Void
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var hasDueDate: Bool

    init(task: TodoItem, onSave: @escaping (TodoItem) -> Void, onDelete: @escaping () -> Void) {
        _task = State(initialValue: task)
        _hasDueDate = State(initialValue: task.dueDate != nil)
        self.onSave = onSave
        self.onDelete = onDelete
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Edit Task")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)

            ScrollView {
                VStack(spacing: 12) {
                    VStack(spacing: 0) {
                        sheetField("Title") {
                            TextField("Title", text: $task.title).textFieldStyle(.plain)
                        }
                        Divider().overlay(Theme.stroke)
                        sheetField("Notes") {
                            TextField("Notes", text: $task.notes, axis: .vertical)
                                .textFieldStyle(.plain)
                                .lineLimit(2...4)
                        }
                        Divider().overlay(Theme.stroke)
                        sheetField("Course") {
                            TextField("e.g. History", text: Binding(
                                get: { task.course ?? "" },
                                set: { task.course = $0.isEmpty ? nil : $0 }
                            )).textFieldStyle(.plain)
                        }
                    }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))

                    VStack(spacing: 0) {
                        HStack {
                            Text("Due date").font(.callout)
                            Spacer()
                            Toggle("", isOn: $hasDueDate).toggleStyle(GlowToggleStyle()).labelsHidden()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)

                        if hasDueDate {
                            Divider().overlay(Theme.stroke)
                            HStack {
                                Text("Due").font(.callout)
                                Spacer()
                                DatePicker("", selection: Binding(
                                    get: { task.dueDate ?? Calendar.current.startOfDay(for: .now) },
                                    set: { task.dueDate = $0 }
                                ), displayedComponents: .date)
                                .labelsHidden()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)

                            Divider().overlay(Theme.stroke)
                            HStack {
                                Text("Repeat").font(.callout)
                                Spacer()
                                Picker("", selection: $task.repeatRule) {
                                    ForEach(RepeatRule.allCases, id: \.self) { Text($0.label).tag($0) }
                                }
                                .labelsHidden()
                                .fixedSize()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                        }

                        Divider().overlay(Theme.stroke)
                        HStack {
                            Text("Priority").font(.callout)
                            Spacer()
                            Picker("", selection: $task.priority) {
                                ForEach(TaskPriority.allCases, id: \.self) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
                }
                .padding(.horizontal, 20)
            }

            HStack {
                Button {
                    onDelete()
                    dismiss()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(SoftPillButtonStyle(tint: Theme.danger))
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SoftPillButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if !hasDueDate { task.dueDate = nil; task.repeatRule = .none }
                    if let due = task.dueDate { task.dueDate = Calendar.current.startOfDay(for: due) }
                    onSave(task)
                    dismiss()
                }
                .buttonStyle(ProminentPillButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(task.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(20)
        }
        .frame(width: 440, height: 440)
        .background(Theme.bg)
    }

    private func sheetField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
