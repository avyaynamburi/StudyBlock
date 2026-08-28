import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TasksView: View {
    @EnvironmentObject private var store: TaskStore
    @EnvironmentObject private var timer: FocusTimerController
    @AppStorage("lockSessions") private var lockSessions = false

    @State private var quickAddText = ""
    @State private var quickAddCourse: String?
    @State private var courseFilter: String?
    @State private var editingTask: TodoItem?
    @State private var editingRecurringTask: TodoItem?
    @State private var showingRecurringSheet = false
    @State private var timerPromptTask: TodoItem?
    @State private var confettiTrigger = 0
    @State private var csvMessage: CSVMessage?
    @State private var showingCSVSheet = false
    @FocusState private var quickAddFocused: Bool

    /// Result of an import/export, shown in an alert afterwards.
    private struct CSVMessage: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("Tasks", subtitle: openCountLabel) {
                HStack(spacing: 10) {
                    CompletedCounterPill(count: store.completedCount)
                    sortButton
                    csvMenu
                    courseFilterMenu
                }
            }

            quickAddBar
                .padding(.horizontal, 28)
                .padding(.bottom, 16)

            board
        }
        .overlay { ScreenConfettiOverlay(trigger: confettiTrigger) }
        .onAppear { store.recomputeAutoColumns() }
        .sheet(item: $editingTask) { task in
            TaskEditSheet(task: task, courses: store.courses,
                          seriesPendingCount: task.seriesID.map { store.pendingCount(inSeries: $0) } ?? 0) { updated in
                store.update(updated)
            } onDelete: {
                store.delete(task)
            } onEditSeries: {
                if let seriesID = task.seriesID, let template = store.seriesTemplate(for: seriesID) {
                    editingRecurringTask = template
                }
            } courseColor: { store.color(for: $0) }
            onCreateCategory: { name, hue in store.setHue(hue, for: name) }
        }
        .sheet(isPresented: $showingRecurringSheet) {
            RecurringTaskSheet(courses: store.courses) { plan in
                let created = store.addRecurring(title: plan.title, course: plan.course,
                                                 dueDate: plan.dueDate, priority: plan.priority,
                                                 repeatRule: plan.repeatRule,
                                                 repeatWeekdays: plan.weekdays,
                                                 seriesEndDate: plan.endDate)
                csvMessage = CSVMessage(
                    title: "Created \(created) task\(created == 1 ? "" : "s")",
                    detail: created == 0
                        ? "That date range doesn\u{2019}t contain any occurrences — check the start and end dates."
                        : "Each one is its own task you can complete, edit, or drag independently.")
            } courseColor: { store.color(for: $0) }
            onCreateCategory: { name, hue in store.setHue(hue, for: name) }
        }
        .sheet(item: $editingRecurringTask) { task in
            RecurringTaskSheet(courses: store.courses, existing: task,
                               pendingCount: task.seriesID.map { store.pendingCount(inSeries: $0) } ?? 0) { plan in
                guard let seriesID = task.seriesID else { return }
                store.updateSeries(seriesID: seriesID, title: plan.title, course: plan.course,
                                   dueDate: plan.dueDate, priority: plan.priority,
                                   repeatRule: plan.repeatRule, repeatWeekdays: plan.weekdays,
                                   seriesEndDate: plan.endDate)
            } onDelete: {
                if let seriesID = task.seriesID {
                    store.deleteSeries(seriesID)
                } else {
                    store.delete(task)
                }
            } courseColor: { store.color(for: $0) }
            onCreateCategory: { name, hue in store.setHue(hue, for: name) }
        }
        .sheet(item: $timerPromptTask) { task in
            StudyTimerPromptSheet(task: task, defaultMinutes: timer.defaultMinutes) { minutes, locked in
                timer.start(minutes: minutes, task: task, locked: locked)
            }
        }
        .sheet(isPresented: $showingCSVSheet) {
            CSVSheet(onImport: runImport, onExport: runExport,
                     onTemplate: saveTemplate, onPaste: runPasteImport)
        }
        .alert(item: $csvMessage) { message in
            Alert(title: Text(message.title),
                  message: message.detail.isEmpty ? nil : Text(message.detail),
                  dismissButton: .default(Text("OK")))
        }
    }

    private var openCountLabel: String {
        let open = store.items.filter { !$0.isCompleted && (courseFilter == nil || $0.course == courseFilter) }.count
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
                    store.quickAdd(quickAddText, courseOverride: quickAddCourse)
                    quickAddText = ""
                    quickAddCourse = nil
                }
            CategoryPickerButton(selection: $quickAddCourse, courses: store.courses,
                                  courseColor: { store.color(for: $0) },
                                  onCreateCategory: { name, hue in store.setHue(hue, for: name) })
            Button {
                showingRecurringSheet = true
            } label: {
                Label("Recurring", systemImage: "calendar.badge.clock")
            }
            .buttonStyle(SoftPillButtonStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .strokeBorder(quickAddFocused ? Theme.accent.opacity(0.55) : Theme.stroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        .animation(.easeOut(duration: 0.15), value: quickAddFocused)
    }

    // MARK: - Board

    private var board: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(TaskColumn.allCases.enumerated()), id: \.element.id) { index, column in
                    if index > 0 {
                        Divider().overlay(Theme.stroke).padding(.vertical, 6)
                    }
                    BoardColumn(column: column,
                                groups: store.groupedTasks(in: column, course: courseFilter),
                                count: store.count(in: column, course: courseFilter),
                                timerRunning: timer.isRunning,
                                courseColor: { store.color(for: $0) },
                                onToggle: { handleToggle($0) },
                                onFocus: { task in
                                    timer.start(minutes: timer.defaultMinutes, task: task, locked: lockSessions)
                                },
                                onSelect: { openEditor(for: $0) },
                                onDrop: { id in handleDrop(id: id, column: column) },
                                onReorder: { id, targetID in handleReorder(id: id, before: targetID) },
                                onMove: { id, target in handleDrop(id: id, column: target) })
                        .frame(width: 250)
                        .padding(.horizontal, 12)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    /// Every card on the board is a real task — including each copy of a
    /// recurring one — so a click always opens the plain editor. That editor
    /// offers a way through to the whole series when the task belongs to one.
    private func openEditor(for task: TodoItem) {
        editingTask = task
    }

    private func handleToggle(_ task: TodoItem) {
        let wasCompleted = task.isCompleted
        store.toggleCompletion(task)
        if !wasCompleted { confettiTrigger += 1 }
    }

    private func handleDrop(id: UUID, column: TaskColumn) {
        let wasCompleted = store.items.first(where: { $0.id == id })?.isCompleted ?? false
        store.move(id, to: column)
        if column == .doing, !timer.isRunning, let task = store.items.first(where: { $0.id == id }) {
            timerPromptTask = task
        }
        if column == .completed, !wasCompleted {
            confettiTrigger += 1
        }
    }

    private func handleReorder(id: UUID, before targetID: UUID) {
        let wasCompleted = store.items.first(where: { $0.id == id })?.isCompleted ?? false
        store.reorder(id, before: targetID)
        let isCompletedNow = store.items.first(where: { $0.id == id })?.isCompleted ?? false
        if isCompletedNow, !wasCompleted {
            confettiTrigger += 1
        }
    }

    // MARK: - CSV import/export

    private var csvMenu: some View {
        Button {
            showingCSVSheet = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "tablecells")
                    .font(.system(size: 11, weight: .semibold))
                Text("CSV")
            }
        }
        .buttonStyle(SoftPillButtonStyle())
        .fixedSize()
        .help("Import tasks from a spreadsheet, export the board, or get an AI prompt")
    }

    private func runImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a CSV of tasks to import."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            // Spreadsheet exports aren't always UTF-8; fall back rather than
            // failing outright on a stray accented character.
            guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? String(data: data, encoding: .macOSRoman) else {
                csvMessage = CSVMessage(title: "Import failed",
                                        detail: "That file isn\u{2019}t readable as text.")
                return
            }
            let summary = try store.importCSV(text)
            csvMessage = CSVMessage(title: summary.headline,
                                    detail: summary.warnings.joined(separator: "\n"))
        } catch {
            csvMessage = CSVMessage(title: "Import failed", detail: error.localizedDescription)
        }
    }

    private func runPasteImport(_ text: String) {
        do {
            let summary = try store.importPastedCSV(text)
            csvMessage = CSVMessage(title: summary.headline,
                                    detail: summary.warnings.joined(separator: "\n"))
        } catch {
            csvMessage = CSVMessage(title: "Couldn\u{2019}t read that",
                                    detail: error.localizedDescription)
        }
    }

    private func runExport() {
        writeCSV(store.exportCSV(), suggestedName: "StudyBlock-tasks.csv",
                 successTitle: "Exported \(store.items.count) task\(store.items.count == 1 ? "" : "s")")
    }

    private func saveTemplate() {
        writeCSV(TaskCSV.template(), suggestedName: "StudyBlock-tasks-template.csv",
                 successTitle: "Template saved",
                 successDetail: "Fill it in (or hand it to an AI along with your assignments) and use Import CSV to load the tasks.")
    }

    private func writeCSV(_ text: String, suggestedName: String,
                          successTitle: String, successDetail: String = "") {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = suggestedName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            csvMessage = CSVMessage(title: successTitle, detail: successDetail)
        } catch {
            csvMessage = CSVMessage(title: "Couldn\u{2019}t save", detail: error.localizedDescription)
        }
    }

    private var sortButton: some View {
        Button {
            store.resetSortToDate()
        } label: {
            Label("Sort by Date", systemImage: "arrow.up.arrow.down")
        }
        .buttonStyle(SoftPillButtonStyle())
        .help("Reset all manual reordering back to due-date order")
    }

    private var courseFilterMenu: some View {
        Menu {
            Button("All Courses") { courseFilter = nil }
            if store.courses.isEmpty {
                Divider()
                Text("No categories yet").foregroundStyle(.secondary)
            } else {
                Divider()
                ForEach(store.courses, id: \.self) { course in
                    Button(course) { courseFilter = course }
                }
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
    }
}

// MARK: - CSV sheet

/// The window behind the "CSV" button: import, export, and a ready-made AI
/// prompt for generating an importable file from plain-English assignments.
private struct CSVSheet: View {
    let onImport: () -> Void
    let onExport: () -> Void
    let onTemplate: () -> Void
    let onPaste: (String) -> Void

    private enum Page { case actions, prompt, paste }

    @Environment(\.dismiss) private var dismiss
    @State private var page: Page = .actions
    @State private var copied = false
    @State private var pastedText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: headerIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(headerTitle)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Spacer(minLength: 0)
                if page != .actions {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { page = .actions }
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(SoftPillButtonStyle())
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            switch page {
            case .actions: actionsPage
            case .prompt: promptPage
            case .paste: pastePage
            }

            Divider().overlay(Theme.stroke)

            HStack {
                if page == .actions {
                    Button("Save Blank Template…") { run(onTemplate) }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if page == .paste {
                    Button {
                        let text = pastedText
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { onPaste(text) }
                    } label: {
                        Label("Import Tasks", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(ProminentPillButtonStyle())
                    .disabled(pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Button("Done") { dismiss() }
                        .buttonStyle(SoftPillButtonStyle())
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 460)
        .background(Theme.bg)
    }

    private var headerIcon: String {
        switch page {
        case .actions: return "tablecells"
        case .prompt: return "sparkles"
        case .paste: return "doc.on.clipboard"
        }
    }

    private var headerTitle: String {
        switch page {
        case .actions: return "Tasks CSV"
        case .prompt: return "Generate tasks with AI"
        case .paste: return "Paste from a chat"
        }
    }

    // MARK: Pages

    private var actionsPage: some View {
        VStack(spacing: 10) {
            actionRow(icon: "square.and.arrow.down",
                      title: "Import CSV…",
                      subtitle: "Add tasks from a spreadsheet. One repeating row becomes a real copy per occurrence; re-importing an export updates tasks instead of duplicating them.") {
                run(onImport)
            }
            actionRow(icon: "square.and.arrow.up",
                      title: "Export CSV…",
                      subtitle: "Save every task on the board, including categories and colors.") {
                run(onExport)
            }
            actionRow(icon: "doc.on.clipboard",
                      title: "Paste CSV…",
                      subtitle: "Paste text straight from a chat. Code fences, markdown tables, and the AI\u{2019}s commentary around it are all handled.") {
                withAnimation(.easeOut(duration: 0.15)) { page = .paste }
            }
            actionRow(icon: "sparkles",
                      title: "Prompt for AI",
                      subtitle: "Copy a prompt, describe your assignments to any AI, and import what it writes back.") {
                withAnimation(.easeOut(duration: 0.15)) { page = .prompt }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    private var pastePage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste the AI\u{2019}s whole reply — you don\u{2019}t need to clean it up first. StudyBlock finds the header row, converts a markdown table if it wrote one, and stops at the commentary underneath.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $pastedText)
                    .font(.system(size: 11, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                if pastedText.isEmpty {
                    Text("title,notes,category,…")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 210)
            .background(Theme.surfaceLow, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 1))

            HStack {
                Button {
                    pastedText = NSPasteboard.general.string(forType: .string) ?? ""
                } label: {
                    Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(SoftPillButtonStyle(tint: Theme.accent))
                if !pastedText.isEmpty {
                    Button("Clear") { pastedText = "" }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    private var promptPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Copy this, paste it into a chat with any AI, then list your assignments in plain English — \u{201C}discussion post every Tuesday at 11:59pm for History.\u{201D} Paste its reply back into \u{201C}Paste from a chat\u{201D}, or save it as a .csv and import it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label("The prompt asks the AI to check with you first about anything you left out — when a repeating task should stop, a vague date, a missing due time — instead of guessing.",
                  systemImage: "questionmark.bubble")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                Text(TaskCSV.aiPrompt)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 210)
            .background(Theme.surfaceLow, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 1))

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(TaskCSV.aiPrompt, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
            } label: {
                Label(copied ? "Copied!" : "Copy Prompt",
                      systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(ProminentPillButtonStyle())
            .frame(maxWidth: .infinity, alignment: .center)
            .animation(.easeOut(duration: 0.15), value: copied)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    private func actionRow(icon: String, title: String, subtitle: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Theme.accentSoft)
                        .frame(width: 34, height: 34)
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// Close the sheet before opening an AppKit open/save panel — running a
    /// modal panel underneath a live sheet leaves the panel unresponsive.
    private func run(_ action: @escaping () -> Void) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: action)
    }
}

// MARK: - Completed counter

private struct CompletedCounterPill: View {
    let count: Int
    @State private var bump = false
    @State private var previousCount = 0

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(Theme.success)
            Text("\(count) completed")
                .font(.callout.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.successSoft, in: Capsule())
        .scaleEffect(bump ? 1.15 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.5), value: bump)
        .onAppear { previousCount = count }
        .onChange(of: count) { newValue in
            if newValue > previousCount {
                bump = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { bump = false }
            }
            previousCount = newValue
        }
    }
}

// MARK: - Board column

private struct BoardColumn: View {
    let column: TaskColumn
    let groups: [TaskStore.SubjectGroup]
    let count: Int
    let timerRunning: Bool
    let courseColor: (String) -> Color
    let onToggle: (TodoItem) -> Void
    let onFocus: (TodoItem) -> Void
    let onSelect: (TodoItem) -> Void
    let onDrop: (UUID) -> Void
    let onReorder: (_ id: UUID, _ targetID: UUID) -> Void
    let onMove: (_ id: UUID, _ target: TaskColumn) -> Void

    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: column.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(column.rawValue)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .textCase(.uppercase)
                    .kerning(0.4)
                    .lineLimit(1)
                Text("\(count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            Divider().overlay(Theme.stroke)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(groups) { group in
                        if groups.count > 1 {
                            Text(group.subject)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                                .padding(.top, group.id == groups.first?.id ? 0 : 6)
                        }
                        ForEach(group.tasks) { task in
                            TaskCard(task: task,
                                     column: column,
                                     showFocusButton: column == .backlog || column == .upcoming,
                                     courseColor: courseColor,
                                     onToggle: { onToggle(task) },
                                     onFocus: timerRunning ? nil : { onFocus(task) },
                                     onReorder: { droppedID in onReorder(droppedID, task.id) },
                                     onSelect: { onSelect(task) },
                                     onMove: { target in onMove(task.id, target) })
                        }
                    }
                    if groups.isEmpty {
                        Text(emptyMessage)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                    }
                }
                .padding(2)
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(isTargeted ? Theme.accentSoft.opacity(0.5) : Color.clear)
        .animation(.easeOut(duration: 0.12), value: isTargeted)
        .dropDestination(for: String.self) { items, _ in
            guard let idString = items.first, let id = UUID(uuidString: idString) else { return false }
            onDrop(id)
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }

    private var emptyMessage: String {
        switch column {
        case .backlog: return "Nothing here — add a task above."
        case .upcoming: return "Nothing due soon."
        case .doing: return "Drag a task here to start it."
        case .completed: return "Nothing finished yet."
        }
    }
}

// MARK: - Task card

private struct TaskCard: View {
    let task: TodoItem
    let column: TaskColumn
    let showFocusButton: Bool
    let courseColor: (String) -> Color
    let onToggle: () -> Void
    var onFocus: (() -> Void)?
    var onReorder: ((UUID) -> Void)?
    var onSelect: (() -> Void)?
    var onMove: ((TaskColumn) -> Void)?

    @State private var hovering = false
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 9) {
                Button(action: onToggle) {
                    ZStack {
                        Circle()
                            .strokeBorder(task.isCompleted ? .clear : (hovering ? Theme.accent : Color.secondary.opacity(0.45)), lineWidth: 1.5)
                            .background(Circle().fill(task.isCompleted ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(.clear)))
                            .frame(width: 18, height: 18)
                        if task.isCompleted {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .buttonStyle(.plain)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: task.isCompleted)
                .help(task.isCompleted ? "Mark incomplete" : "Mark complete")

                // Only the title/notes text (no buttons) opens the editor and
                // acts as the drag handle — keeping the checkbox and focus
                // button out from under `.draggable` is what lets them
                // actually receive their taps instead of starting a drag.
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(.system(size: 13, weight: .medium))
                        .strikethrough(task.isCompleted)
                        .foregroundStyle(task.isCompleted ? .secondary : .primary)
                        .lineLimit(2)
                    if !task.notes.isEmpty {
                        Text(task.notes)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { onSelect?() }
                .draggable(task.id.uuidString)

                Spacer(minLength: 0)
                if let onFocus, showFocusButton, hovering {
                    Button(action: onFocus) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(IconButtonStyle(tint: Theme.accent))
                    .help("Start a focus session on this task")
                    .transition(.opacity)
                }
                if let onMove, hovering {
                    Menu {
                        ForEach(TaskColumn.allCases.filter { $0 != column }) { target in
                            Button {
                                onMove(target)
                            } label: {
                                Label(target.rawValue, systemImage: target.icon)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.right.circle")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Move to another list")
                    .transition(.opacity)
                }
            }

            HStack(spacing: 6) {
                if task.repeatRule != .none {
                    Image(systemName: "repeat")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                if let course = task.course {
                    TagChip(text: course, color: courseColor(course))
                }
                if let due = task.dueDate {
                    Text(Self.dueLabel(for: due))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(task.isOverdue ? Theme.danger : .secondary)
                }
                if task.priority != .none {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(priorityColor)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 27)
            .contentShape(Rectangle())
            .onTapGesture { onSelect?() }
            .draggable(task.id.uuidString)
        }
        .padding(10)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(borderColor, lineWidth: borderWidth))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.1), value: isDropTargeted)
        .dropDestination(for: String.self) { droppedItems, _ in
            guard let onReorder, let idString = droppedItems.first, let id = UUID(uuidString: idString) else { return false }
            onReorder(id)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
    }

    private var priorityColor: Color {
        switch task.priority {
        case .high: return Theme.danger
        case .medium: return Theme.amber
        default: return Theme.accent
        }
    }

    private var cardBackground: AnyShapeStyle {
        if column == .completed { return AnyShapeStyle(Theme.successSoft) }
        return AnyShapeStyle(hovering ? Theme.surface : Theme.surface.opacity(0.7))
    }

    private var borderColor: Color {
        if isDropTargeted { return Theme.accent }
        if column == .completed { return Theme.success }
        if column == .upcoming, !task.isCompleted, let due = task.dueDate {
            return Self.urgencyColor(for: due)
        }
        return Theme.stroke
    }

    private var borderWidth: CGFloat {
        if isDropTargeted || column == .completed { return 2 }
        if column == .upcoming, !task.isCompleted, task.dueDate != nil { return 1.5 }
        return 1
    }

    /// Yellow (a week or more out) → orange → red (due now or overdue).
    private static func urgencyColor(for dueDate: Date, now: Date = Date()) -> Color {
        let daysRemaining = dueDate.timeIntervalSince(now) / 86400
        let t = min(1, max(0, 1 - daysRemaining / 7))
        return Color(hue: (60 - 60 * t) / 360, saturation: 0.82, brightness: 0.92)
    }

    static func dueLabel(for date: Date) -> String {
        let calendar = Calendar.current
        var label: String
        if calendar.isDateInToday(date) { label = "Today" }
        else if calendar.isDateInTomorrow(date) { label = "Tomorrow" }
        else if calendar.isDateInYesterday(date) { label = "Yesterday" }
        else {
            let formatter = DateFormatter()
            formatter.dateFormat = calendar.isDate(date, equalTo: .now, toGranularity: .year) ? "E, MMM d" : "MMM d, yyyy"
            label = formatter.string(from: date)
        }
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        if let hour = comps.hour, let minute = comps.minute, !(hour == 0 && minute == 0) {
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "h:mm a"
            label += " · \(timeFormatter.string(from: date))"
        }
        return label
    }
}

// MARK: - Confetti

/// Full-page celebration: a fresh burst of pieces rains down across the
/// whole Tasks view every time `trigger` changes, regardless of where on
/// the board the completed task was.
private struct ScreenConfettiOverlay: View {
    let trigger: Int
    @State private var pieces: [ScreenConfettiPiece] = []
    @State private var animate = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(pieces) { piece in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(piece.color)
                        .frame(width: piece.size, height: piece.size * 0.4)
                        .rotationEffect(.degrees(animate ? piece.endRotation : piece.startRotation))
                        .position(x: piece.x * proxy.size.width, y: animate ? proxy.size.height + 40 : -20)
                        .opacity(animate ? 0 : 1)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .onChange(of: trigger) { _ in fire() }
        }
        .allowsHitTesting(false)
    }

    private func fire() {
        pieces = (0..<60).map { _ in ScreenConfettiPiece() }
        animate = false
        withAnimation(.easeIn(duration: 1.1)) { animate = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            pieces = []
            animate = false
        }
    }
}

private struct ScreenConfettiPiece: Identifiable {
    let id = UUID()
    let color: Color
    let x: CGFloat
    let size: CGFloat
    let startRotation: Double
    let endRotation: Double

    init() {
        let colors: [Color] = [Theme.accent, Theme.violet, Theme.success, Theme.amber, Theme.danger]
        color = colors.randomElement() ?? Theme.accent
        x = CGFloat.random(in: 0.02...0.98)
        size = CGFloat.random(in: 6...11)
        startRotation = Double.random(in: 0...360)
        endRotation = startRotation + Double.random(in: 180...720)
    }
}

// MARK: - Category picker

private struct CategoryPickerButton: View {
    @Binding var selection: String?
    let courses: [String]
    var courseColor: (String) -> Color = { _ in Theme.accent }
    var onCreateCategory: (_ name: String, _ hue: Double) -> Void = { _, _ in }

    @State private var showingNewCategory = false

    var body: some View {
        Menu {
            Button("None") { selection = nil }
            if !courses.isEmpty {
                Divider()
                ForEach(courses, id: \.self) { course in
                    Button {
                        selection = course
                    } label: {
                        if selection == course {
                            Label(course, systemImage: "checkmark")
                        } else {
                            Text(course)
                        }
                    }
                }
            }
            Divider()
            Button("New Category…") {
                showingNewCategory = true
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "tag")
                    .font(.system(size: 11, weight: .semibold))
                Text(selection ?? "Category")
            }
        }
        .menuStyle(.button)
        .buttonStyle(SoftPillButtonStyle(tint: selection.map(courseColor)))
        .fixedSize()
        .sheet(isPresented: $showingNewCategory) {
            NewCategorySheet { name, hue in
                onCreateCategory(name, hue)
                selection = name
            }
        }
    }
}

/// Name + pastel hue picker shown when creating a category. The swatches are
/// generated at fixed, gentle saturation/brightness (`Theme.categoryPastel`)
/// so nothing offered here can come out too bright or too dark.
private struct NewCategorySheet: View {
    let onAdd: (_ name: String, _ hue: Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var hue: Double = Theme.categoryHueSteps.first ?? 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Category")
                .font(.system(size: 15, weight: .bold, design: .rounded))

            TextField("Category name", text: $name)
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Theme.surfaceLow, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))

            VStack(alignment: .leading, spacing: 8) {
                Text("Color").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    ForEach(Theme.categoryHueSteps, id: \.self) { step in
                        Circle()
                            .fill(Theme.categoryPastel(hue: step))
                            .frame(width: 24, height: 24)
                            .overlay(Circle().strokeBorder(Theme.stroke, lineWidth: 1))
                            .overlay(
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Theme.categoryInk(hue: step))
                                    .opacity(hue == step ? 1 : 0)
                            )
                            .onTapGesture { hue = step }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SoftPillButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onAdd(trimmed, hue)
                    dismiss()
                }
                .buttonStyle(ProminentPillButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 300)
        .background(Theme.bg)
    }
}

// MARK: - Weekday picker

private struct WeekdayPicker: View {
    @Binding var selection: Set<Int>
    private static let symbols = ["S", "M", "T", "W", "T", "F", "S"]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...7, id: \.self) { weekday in
                let isOn = selection.contains(weekday)
                Button {
                    if isOn { selection.remove(weekday) } else { selection.insert(weekday) }
                } label: {
                    Text(Self.symbols[weekday - 1])
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .frame(width: 26, height: 26)
                        .foregroundStyle(isOn ? .white : .secondary)
                        .background(isOn ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surfaceLow), in: Circle())
                        .overlay(Circle().strokeBorder(isOn ? .clear : Theme.stroke, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Study timer prompt

private struct StudyTimerPromptSheet: View {
    let task: TodoItem
    let defaultMinutes: Int
    let onStart: (Int, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("lockSessions") private var lockSessions = false
    @State private var selectedMinutes: Int

    init(task: TodoItem, defaultMinutes: Int, onStart: @escaping (Int, Bool) -> Void) {
        self.task = task
        self.defaultMinutes = defaultMinutes
        self.onStart = onStart
        _selectedMinutes = State(initialValue: defaultMinutes)
    }

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(Theme.accentSoft).frame(width: 52, height: 52)
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                Text("Start a study timer?")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                Text("\"\(task.title)\" just moved to Currently Doing.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            .padding(.top, 24)

            HStack(spacing: 10) {
                ForEach(FocusTimerController.presetMinutes, id: \.self) { minutes in
                    Button("\(minutes) min") { selectedMinutes = minutes }
                        .buttonStyle(SoftPillButtonStyle(tint: selectedMinutes == minutes ? Theme.accent : nil))
                }
            }

            Toggle(isOn: $lockSessions) {
                Text("Lock session — no giving up until time is up")
                    .font(.callout)
            }
            .toggleStyle(CheckToggleStyle())
            .padding(.horizontal, 24)

            HStack {
                Button("Not Now") { dismiss() }
                    .buttonStyle(SoftPillButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    onStart(selectedMinutes, lockSessions)
                    dismiss()
                } label: {
                    Label("Start Timer", systemImage: "play.fill")
                }
                .buttonStyle(ProminentPillButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(width: 360)
        .background(Theme.bg)
    }
}

// MARK: - Recurring task sheet

/// What the recurring sheet hands back: a complete description of a series,
/// which the store turns into one real task per occurrence.
struct SeriesPlan {
    var title: String
    var course: String?
    var dueDate: Date
    var priority: TaskPriority
    var repeatRule: RepeatRule
    var weekdays: Set<Int>
    /// Last day the series runs, or nil for "repeats indefinitely".
    var endDate: Date?
}

struct RecurringTaskSheet: View {
    let courses: [String]
    var existing: TodoItem?
    /// Occurrences of this series still pending, so an edit can say plainly
    /// how many tasks it is about to replace.
    var pendingCount: Int = 0
    let onSave: (SeriesPlan) -> Void
    var onDelete: (() -> Void)?
    var courseColor: (String) -> Color = { _ in Theme.accent }
    var onCreateCategory: (_ name: String, _ hue: Double) -> Void = { _, _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var course: String?
    @State private var priority: TaskPriority
    @State private var repeatRule: RepeatRule
    @State private var weekdays: Set<Int>
    @State private var dueDate: Date
    @State private var hasDueTime: Bool
    @State private var dueTime: Date
    @State private var hasEndDate: Bool
    @State private var endDate: Date

    private static let recurringOptions: [RepeatRule] = [.daily, .weekly, .monthly]

    init(courses: [String], existing: TodoItem? = nil, pendingCount: Int = 0,
         onSave: @escaping (SeriesPlan) -> Void,
         onDelete: (() -> Void)? = nil,
         courseColor: @escaping (String) -> Color = { _ in Theme.accent },
         onCreateCategory: @escaping (_ name: String, _ hue: Double) -> Void = { _, _ in }) {
        self.courses = courses
        self.existing = existing
        self.pendingCount = pendingCount
        self.onSave = onSave
        self.onDelete = onDelete
        self.courseColor = courseColor
        self.onCreateCategory = onCreateCategory

        _title = State(initialValue: existing?.title ?? "")
        _course = State(initialValue: existing?.course)
        _priority = State(initialValue: existing?.priority ?? .none)
        _repeatRule = State(initialValue: existing.map { $0.repeatRule == .none ? .weekly : $0.repeatRule } ?? .weekly)
        _weekdays = State(initialValue: existing?.repeatWeekdays ?? [])

        let due = existing?.dueDate ?? Calendar.current.startOfDay(for: .now)
        _dueDate = State(initialValue: Calendar.current.startOfDay(for: due))
        let comps = Calendar.current.dateComponents([.hour, .minute], from: due)
        _hasDueTime = State(initialValue: (comps.hour ?? 0) != 0 || (comps.minute ?? 0) != 0)
        _dueTime = State(initialValue: due)

        _hasEndDate = State(initialValue: existing?.seriesEndDate != nil)
        // A sensible first guess for "when does this stop" — about a term out.
        let defaultEnd = Calendar.current.date(byAdding: .month, value: 4,
                                               to: Calendar.current.startOfDay(for: due))
        _endDate = State(initialValue: existing?.seriesEndDate ?? defaultEnd ?? due)
    }

    /// The dates this series would produce with the current settings — drives
    /// the live "creates N tasks" preview, so the scale is visible before the
    /// button is pressed rather than after.
    private var previewDates: [Date] {
        var template = TodoItem(title: "preview", repeatRule: repeatRule, repeatWeekdays: weekdays)
        template.seriesEndDate = hasEndDate ? endDate : nil
        return repeatRule.occurrences(startingAt: combinedDueDate, weekdays: weekdays,
                                      endDate: template.seriesEndDate,
                                      limit: RepeatRule.materializedCount(hasEndDate: hasEndDate))
    }

    private var combinedDueDate: Date {
        hasDueTime ? combineDateAndTime(date: dueDate, time: dueTime) : dueDate
    }

    private var previewSummary: String {
        let count = previewDates.count
        guard count > 0 else {
            return "No occurrences in that range — the end date is on or before the start date."
        }
        let last = previewDates[count - 1].formatted(.dateTime.month(.abbreviated).day().year())
        if hasEndDate {
            return "Creates \(count) task\(count == 1 ? "" : "s"), the last on \(last)."
        }
        return "Repeats indefinitely — creates \(count) tasks now (through \(last)), "
            + "and adds another each time you finish one."
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(existing == nil ? "New Recurring Task" : "Edit Recurring Task")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)

            ScrollView {
                VStack(spacing: 12) {
                    VStack(spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("Title").font(.callout).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                            TextField("Title", text: $title).textFieldStyle(.plain)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)

                        Divider().overlay(Theme.stroke)
                        HStack {
                            Text("Category").font(.callout)
                            Spacer()
                            CategoryPickerButton(selection: $course, courses: courses,
                                                  courseColor: courseColor, onCreateCategory: onCreateCategory)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))

                    VStack(spacing: 0) {
                        HStack {
                            Text("Repeats").font(.callout)
                            Spacer()
                            Picker("", selection: $repeatRule) {
                                ForEach(Self.recurringOptions, id: \.self) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)

                        if repeatRule == .weekly {
                            Divider().overlay(Theme.stroke)
                            VStack(alignment: .leading, spacing: 8) {
                                Text("On these days")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                WeekdayPicker(selection: $weekdays)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }

                        Divider().overlay(Theme.stroke)
                        HStack {
                            Text(repeatRule == .monthly ? "Due date" : "Starting").font(.callout)
                            Spacer()
                            DatePicker("", selection: $dueDate, displayedComponents: .date).labelsHidden()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)

                        Divider().overlay(Theme.stroke)
                        HStack {
                            Text("Due time").font(.callout)
                            Spacer()
                            DatePicker("", selection: $dueTime, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                                .disabled(!hasDueTime)
                                .opacity(hasDueTime ? 1 : 0.4)
                            Toggle("", isOn: $hasDueTime).toggleStyle(GlowToggleStyle()).labelsHidden()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)

                        Divider().overlay(Theme.stroke)
                        HStack {
                            Text("Ends").font(.callout)
                            Spacer()
                            DatePicker("", selection: $endDate, in: dueDate..., displayedComponents: .date)
                                .labelsHidden()
                                .disabled(!hasEndDate)
                                .opacity(hasEndDate ? 1 : 0.4)
                            Toggle("", isOn: $hasEndDate).toggleStyle(GlowToggleStyle()).labelsHidden()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)

                        Divider().overlay(Theme.stroke)
                        HStack {
                            Text("Priority").font(.callout)
                            Spacer()
                            Picker("", selection: $priority) {
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

                    VStack(alignment: .leading, spacing: 6) {
                        if repeatRule == .weekly, weekdays.isEmpty {
                            Text("No days selected — it'll repeat weekly on \(dueDate.formatted(.dateTime.weekday(.wide))).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Label(previewSummary, systemImage: previewDates.isEmpty
                              ? "exclamationmark.triangle.fill" : "square.on.square")
                            .font(.caption)
                            .foregroundStyle(previewDates.isEmpty ? Theme.danger : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if existing != nil, pendingCount > 0 {
                            Label("Saving replaces the \(pendingCount) task\(pendingCount == 1 ? "" : "s") "
                                  + "still to do in this series. Completed ones are kept.",
                                  systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 20)
            }

            HStack {
                if let onDelete {
                    Button {
                        onDelete()
                        dismiss()
                    } label: {
                        Label(pendingCount > 1 ? "Delete \(pendingCount) Tasks" : "Delete",
                              systemImage: "trash")
                    }
                    .buttonStyle(SoftPillButtonStyle(tint: Theme.danger))
                    .help("Removes every occurrence still to do. Completed ones are kept.")
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SoftPillButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Add Tasks" : "Save Series") {
                    onSave(SeriesPlan(title: title, course: course, dueDate: combinedDueDate,
                                      priority: priority, repeatRule: repeatRule,
                                      weekdays: weekdays, endDate: hasEndDate ? endDate : nil))
                    dismiss()
                }
                .buttonStyle(ProminentPillButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || previewDates.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 460, height: 580)
        .background(Theme.bg)
    }

}

/// Merges the calendar date from `date` with the hour/minute from `time`.
private func combineDateAndTime(date: Date, time: Date) -> Date {
    let calendar = Calendar.current
    let dateComponents = calendar.dateComponents([.year, .month, .day], from: date)
    let timeComponents = calendar.dateComponents([.hour, .minute], from: time)
    var merged = DateComponents()
    merged.year = dateComponents.year
    merged.month = dateComponents.month
    merged.day = dateComponents.day
    merged.hour = timeComponents.hour
    merged.minute = timeComponents.minute
    return calendar.date(from: merged) ?? date
}

// MARK: - Edit sheet

struct TaskEditSheet: View {
    @State var task: TodoItem
    let courses: [String]
    /// Occurrences of this task's series still pending, or 0 if it isn't part
    /// of one. Drives the "edit the whole series" route out of this sheet.
    var seriesPendingCount: Int = 0
    let onSave: (TodoItem) -> Void
    let onDelete: () -> Void
    var onEditSeries: (() -> Void)?
    var courseColor: (String) -> Color = { _ in Theme.accent }
    var onCreateCategory: (_ name: String, _ hue: Double) -> Void = { _, _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var hasDueDate: Bool
    @State private var hasDueTime: Bool
    @State private var dueTime: Date

    init(task: TodoItem, courses: [String], seriesPendingCount: Int = 0,
         onSave: @escaping (TodoItem) -> Void,
         onDelete: @escaping () -> Void, onEditSeries: (() -> Void)? = nil,
         courseColor: @escaping (String) -> Color = { _ in Theme.accent },
         onCreateCategory: @escaping (_ name: String, _ hue: Double) -> Void = { _, _ in }) {
        _task = State(initialValue: task)
        self.courses = courses
        self.seriesPendingCount = seriesPendingCount
        _hasDueDate = State(initialValue: task.dueDate != nil)
        let comps = task.dueDate.map { Calendar.current.dateComponents([.hour, .minute], from: $0) }
        let hasTime = (comps?.hour ?? 0) != 0 || (comps?.minute ?? 0) != 0
        _hasDueTime = State(initialValue: hasTime)
        _dueTime = State(initialValue: task.dueDate ?? Date())
        self.onSave = onSave
        self.onDelete = onDelete
        self.onEditSeries = onEditSeries
        self.courseColor = courseColor
        self.onCreateCategory = onCreateCategory
    }

    private static let repeatOptions = RepeatRule.allCases

    var body: some View {
        VStack(spacing: 0) {
            Text("Edit Task")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)

            if task.seriesID != nil, let onEditSeries {
                Button {
                    onEditSeries()
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "repeat")
                            .font(.system(size: 11, weight: .semibold))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("One copy of a repeating task — edits here affect only this one")
                                .font(.caption.weight(.medium))
                            if seriesPendingCount > 0 {
                                Text("Edit all \(seriesPendingCount) still to do")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }

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
                        HStack {
                            Text("Category").font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            CategoryPickerButton(selection: $task.course, courses: courses,
                                                  courseColor: courseColor, onCreateCategory: onCreateCategory)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
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
                                Text("Due time").font(.callout)
                                Spacer()
                                DatePicker("", selection: $dueTime, displayedComponents: .hourAndMinute)
                                    .labelsHidden()
                                    .disabled(!hasDueTime)
                                    .opacity(hasDueTime ? 1 : 0.4)
                                Toggle("", isOn: $hasDueTime).toggleStyle(GlowToggleStyle()).labelsHidden()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)

                            // Repeat belongs to the series as a whole, so it's
                            // only editable here for a task that isn't in one
                            // yet — setting it promotes this task into a series.
                            if task.seriesID == nil {
                                Divider().overlay(Theme.stroke)
                                HStack {
                                    Text("Repeat").font(.callout)
                                    Spacer()
                                    Picker("", selection: $task.repeatRule) {
                                        ForEach(Self.repeatOptions, id: \.self) { Text($0.label).tag($0) }
                                    }
                                    .labelsHidden()
                                    .fixedSize()
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)

                                if task.repeatRule == .weekly {
                                    Divider().overlay(Theme.stroke)
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("On these days")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        WeekdayPicker(selection: $task.repeatWeekdays)
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                }

                                if task.repeatRule != .none {
                                    Divider().overlay(Theme.stroke)
                                    Label("Saving creates \(RepeatRule.perpetualCount) copies of this task, "
                                          + "one per occurrence. Use the Recurring button to set an end date.",
                                          systemImage: "square.on.square")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                }
                            }
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
                    if !hasDueDate {
                        task.dueDate = nil
                        task.repeatRule = .none
                        task.repeatWeekdays = []
                    } else if let due = task.dueDate {
                        task.dueDate = hasDueTime
                            ? combineDateAndTime(date: due, time: dueTime)
                            : Calendar.current.startOfDay(for: due)
                    }
                    onSave(task)
                    dismiss()
                }
                .buttonStyle(ProminentPillButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(task.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(20)
        }
        .frame(width: 440, height: 480)
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
