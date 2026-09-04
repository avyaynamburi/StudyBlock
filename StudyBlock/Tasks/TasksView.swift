import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TasksView: View {
    @EnvironmentObject private var store: TaskStore
    @EnvironmentObject private var timer: FocusTimerController
    @EnvironmentObject private var canvas: CanvasSync
    @AppStorage("lockSessions") private var lockSessions = false

    @State private var quickAddText = ""
    @State private var quickAddCourse: String?
    @State private var courseFilter: String?
    @State private var editorTarget: EditorTarget?
    @State private var timerPromptTask: TodoItem?
    @State private var confettiTrigger = 0
    @State private var csvMessage: CSVMessage?
    @State private var showingCSVSheet = false
    @State private var showingCanvasSheet = false
    @State private var merging: MergeTarget?
    @State private var mergeRefusal: String?
    @FocusState private var quickAddFocused: Bool

    /// Result of an import/export, shown in an alert afterwards.
    private struct CSVMessage: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
    }

    /// A merge in progress. `partner` is set when one card was dropped onto
    /// another; nil when the context menu opened the picker instead.
    private struct MergeTarget: Identifiable {
        let id = UUID()
        let primary: TodoItem
        var partner: TodoItem?
    }

    /// What the task editor is open on — an existing card, or a blank draft
    /// for a new one. One sheet covers both, so this is the only thing that
    /// distinguishes them.
    private struct EditorTarget: Identifiable {
        let task: TodoItem
        var isNew = false
        var id: UUID { task.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("Tasks", subtitle: openCountLabel) {
                HStack(spacing: 10) {
                    CompletedCounterPill(count: store.completedCount)
                    sortButton
                    canvasMenu
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
        // One pull per launch. `CanvasSync` holds the guard rather than this
        // view, because `.task` re-runs every time the Tasks tab is selected.
        .task { await canvas.syncOnLaunch(into: store) }
        .sheet(item: $merging) { target in
            TaskMergeSheet(primary: target.primary, partner: target.partner,
                           candidates: store.items,
                           courseColor: { store.color(for: $0) }) { plan in
                store.applyMerge(plan)
            }
        }
        .alert("Can\u{2019}t merge these", isPresented: Binding(
            get: { mergeRefusal != nil }, set: { if !$0 { mergeRefusal = nil } })
        ) {
            Button("OK") { mergeRefusal = nil }
        } message: {
            Text(mergeRefusal ?? "")
        }
        .sheet(isPresented: $showingCanvasSheet) {
            CanvasSheet(canvas: canvas, canvasTaskCount: store.canvasCount) { runCanvasSync() }
        }
        .sheet(item: $editorTarget) { target in
            TaskEditSheet(task: target.task, isNew: target.isNew, courses: store.courses,
                          seriesPendingCount: target.task.seriesID
                              .map { store.pendingCount(inSeries: $0) } ?? 0,
                          seriesStart: target.task.seriesID
                              .flatMap { store.seriesTemplate(for: $0)?.dueDate },
                          onSave: { plan in save(plan, to: target) },
                          onDelete: target.isNew ? nil : { store.delete(target.task) },
                          onDeleteSeries: target.task.seriesID == nil || target.isNew
                              ? nil : { store.deleteSeries(containing: target.task) },
                          courseColor: { store.color(for: $0) },
                          onCreateCategory: { name, hue in store.setHue(hue, for: name) })
        }
        .sheet(item: $timerPromptTask) { task in
            StudyTimerPromptSheet(task: task, defaultMinutes: timer.defaultMinutes) { minutes, locked in
                timer.start(minutes: minutes, task: task, locked: locked)
            }
        }
        .sheet(isPresented: $showingCSVSheet) {
            CSVSheet(categories: store.csvCategories,
                     onImport: runImport, onExport: runExport,
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
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Theme.accentFill)
                    .frame(width: 26, height: 26)
                Image(systemName: "plus")
                    .font(Theme.ui(12, .semibold))
                    .foregroundStyle(.white)
            }
            TextField("Add a task — try: essay friday #history !!", text: $quickAddText)
                .textFieldStyle(.plain)
                .font(Theme.ui(14))
                .focused($quickAddFocused)
                .onSubmit {
                    // One box, two languages: a pasted spreadsheet row goes
                    // to the CSV importer, anything else to the quick-add
                    // parser that understands "essay friday #history !!".
                    if TaskCSV.looksLikeRow(quickAddText) {
                        runPasteImport(quickAddText)
                    } else {
                        store.quickAdd(quickAddText, courseOverride: quickAddCourse)
                    }
                    quickAddText = ""
                    quickAddCourse = nil
                }
            CategoryPickerButton(selection: $quickAddCourse, courses: store.courses,
                                  courseColor: { store.color(for: $0) },
                                  onCreateCategory: { name, hue in store.setHue(hue, for: name) })
            Button(action: pasteTasksFromClipboard) {
                Image(systemName: "doc.on.clipboard")
                    .font(Theme.ui(11, .semibold))
            }
            .buttonStyle(SoftPillButtonStyle())
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .help("Paste tasks from CSV on the clipboard (\u{2318}\u{21E7}V) — one row or many, "
                  + "with or without a header line")
            Button(action: openNewTaskEditor) {
                Label("Details", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(SoftPillButtonStyle())
            .help("Open the full editor \u{2014} due date, time, notes, category, and repeats")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(quickAddFocused ? Theme.accent.opacity(0.55) : Theme.stroke, lineWidth: 1))
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
                                tasks: store.tasks(in: column, course: courseFilter),
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
                                onMove: { id, target in handleDrop(id: id, column: target) },
                                onMergeDrop: { id, targetID in beginMerge(id: id, into: targetID) },
                                onMergePick: { task in beginMerge(from: task) })
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
    /// recurring one — so a click always opens the same editor. It asks there
    /// whether an edit lands on the one card or the whole series.
    private func openEditor(for task: TodoItem) {
        editorTarget = EditorTarget(task: task)
    }

    /// Opens the editor on a blank task, seeded with whatever is already in
    /// the quick-add box — so "I started typing and need a due date" carries
    /// straight over instead of being retyped.
    private func openNewTaskEditor() {
        let typed = quickAddText.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = typed.isEmpty ? nil : QuickAddParser.parse(typed)
        let draft = TodoItem(title: parsed?.title ?? "",
                             course: parsed?.course ?? quickAddCourse,
                             dueDate: parsed?.dueDate)
        editorTarget = EditorTarget(task: draft, isNew: true)
    }

    /// Applies what the editor handed back: a new task (or whole series), a
    /// rewrite of an existing series, or an edit to one card.
    private func save(_ plan: TaskPlan, to target: EditorTarget) {
        if target.isNew {
            let created = store.add(title: plan.title, notes: plan.notes, course: plan.course,
                                    dueDate: plan.dueDate, repeatRule: plan.repeatRule,
                                    repeatWeekdays: plan.weekdays, repeatInterval: plan.interval,
                                    seriesEndDate: plan.endDate)
            quickAddText = ""
            quickAddCourse = nil
            report(created: created, repeating: plan.repeatRule != .none)
            return
        }

        if plan.appliesToSeries, let seriesID = target.task.seriesID {
            store.updateSeries(seriesID: seriesID, title: plan.title, notes: plan.notes,
                               course: plan.course, dueDate: plan.dueDate,
                               repeatRule: plan.repeatRule, repeatWeekdays: plan.weekdays,
                               repeatInterval: plan.interval, seriesEndDate: plan.endDate)
            return
        }

        var updated = target.task
        updated.title = plan.title
        updated.notes = plan.notes
        updated.course = plan.course
        updated.dueDate = plan.dueDate
        updated.repeatRule = plan.repeatRule
        updated.repeatWeekdays = plan.weekdays
        updated.repeatInterval = plan.interval
        updated.seriesEndDate = plan.endDate
        let created = store.update(updated)
        // Only worth reporting when a single card just became a whole run.
        if target.task.seriesID == nil, plan.repeatRule != .none {
            report(created: created, repeating: true)
        }
    }

    /// Turning one line into a hundred cards is a big change to the board, so
    /// say so rather than leaving the user to notice. A single plain task
    /// needs no announcement.
    private func report(created: Int, repeating: Bool) {
        guard repeating else { return }
        if created == 0 {
            csvMessage = CSVMessage(
                title: "Nothing created",
                detail: "That date range doesn\u{2019}t contain any occurrences \u{2014} "
                    + "check the start and end dates.")
        } else {
            csvMessage = CSVMessage(
                title: "Created \(created) task\(created == 1 ? "" : "s")",
                detail: "Each one is its own task you can complete, edit, or drag independently.")
        }
    }

    // MARK: - Merging

    /// A card was option-dropped onto another. The sheet always opens — a
    /// merge is never applied straight from the gesture.
    private func beginMerge(id: UUID, into targetID: UUID) {
        guard let dropped = store.items.first(where: { $0.id == id }),
              let target = store.items.first(where: { $0.id == targetID }) else { return }
        if let refusal = TaskMergePlan.refusal(target, dropped) {
            mergeRefusal = refusal
            return
        }
        merging = MergeTarget(primary: target, partner: dropped)
    }

    /// The context-menu route: the same sheet, opened on its picker because
    /// there is no second card yet.
    private func beginMerge(from task: TodoItem) {
        merging = MergeTarget(primary: task, partner: nil)
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
        let before = store.items.first(where: { $0.id == id })
        store.reorder(id, before: targetID)
        guard let after = store.items.first(where: { $0.id == id }) else { return }

        if after.isCompleted, !(before?.isCompleted ?? false) {
            confettiTrigger += 1
        }
        // Dropping onto a card inside Currently Doing lands the task there
        // just as surely as dropping on the column's empty space, and has to
        // prompt the same way. Only the empty-space route did, so the prompt
        // vanished as soon as that column had anything in it.
        if after.column == .doing, before?.column != .doing, !timer.isRunning {
            timerPromptTask = after
        }
    }

    // MARK: - Canvas

    /// Clicking syncs; the menu holds the settings and the less-used
    /// switches. A feed that isn't set up yet opens the sheet instead, since
    /// there is nothing to sync.
    private var canvasMenu: some View {
        Menu {
            Button("Sync Now") { runCanvasSync() }
                .disabled(!canvas.isConfigured || canvas.isSyncing)
            Button("Canvas Feed\u{2026}") { showingCanvasSheet = true }
            Divider()
            Text(canvas.lastSyncedLabel)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: canvas.isSyncing
                      ? "arrow.triangle.2.circlepath" : "graduationcap")
                    .font(Theme.ui(11, .semibold))
                Text("Canvas")
            }
        } primaryAction: {
            if canvas.isConfigured { runCanvasSync() } else { showingCanvasSheet = true }
        }
        .menuStyle(.button)
        .buttonStyle(SoftPillButtonStyle(tint: canvas.lastError != nil ? Theme.danger : nil))
        .fixedSize()
        .disabled(canvas.isSyncing)
        .help(canvas.isConfigured
              ? "Pull assignments from Canvas \u{2014} \(canvas.lastSyncedLabel.lowercased())"
              : "Set up your Canvas calendar feed")
    }

    private func runCanvasSync() {
        Task {
            let result = await canvas.sync(into: store)
            switch result {
            case .success(let summary):
                // Silence is right for a launch sync that found nothing, but
                // a sync the user asked for should always say what happened.
                csvMessage = CSVMessage(title: summary.headline, detail: summary.detail)
            case .failure(let error):
                csvMessage = CSVMessage(title: "Canvas sync failed",
                                        detail: error.localizedDescription)
            }
        }
    }

    // MARK: - CSV import/export

    private var csvMenu: some View {
        Button {
            showingCSVSheet = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "tablecells")
                    .font(Theme.ui(11, .semibold))
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

    /// Imports whatever CSV is sitting on the clipboard. This is the only
    /// route that takes more than one row at a time — the quick-add field is
    /// single-line, so a multi-row paste loses its newlines on the way in.
    private func pasteTasksFromClipboard() {
        let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            csvMessage = CSVMessage(title: "Nothing on the clipboard",
                                    detail: "Copy some CSV first \u{2014} a single row is enough, "
                                        + "and it doesn\u{2019}t need a header line.")
            return
        }
        runPasteImport(text)
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
                    .font(Theme.ui(11, .semibold))
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
    /// Existing categories and their colors, baked into the AI prompt.
    var categories: [(name: String, color: String)] = []
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
                    .font(Theme.ui(14, .semibold))
                    .foregroundStyle(Theme.accent)
                Text(headerTitle)
                    .font(Theme.ui(16, .semibold))
                Spacer(minLength: 0)
                if page != .actions {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { page = .actions }
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .font(Theme.ui(10, .medium))
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
                        .font(Theme.ui(10))
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
                      subtitle: "Paste text straight from a chat. Code fences, markdown tables, and the AI\u{2019}s commentary around it are all handled. \u{2318}\u{21E7}V on the board does the same thing without opening this sheet.") {
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
            Text("Paste the AI\u{2019}s whole reply — you don\u{2019}t need to clean it up first. StudyBlock finds the header row, converts a markdown table if it wrote one, and stops at the commentary underneath. A snippet with no header line works too: the columns are read in the standard order, so a bare row or a plain list of task names both import.")
                .font(Theme.ui(12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $pastedText)
                    .font(Theme.mono(11))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                if pastedText.isEmpty {
                    Text("title,category,color,due_date,…")
                        .font(Theme.mono(11))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 210)
            .background(Theme.surfaceLow, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
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
                        .font(Theme.ui(10))
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
                .font(Theme.ui(12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label(promptHint, systemImage: "questionmark.bubble")
                .font(Theme.ui(10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                Text(prompt)
                    .font(Theme.mono(11))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 210)
            .background(Theme.surfaceLow, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 1))

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(prompt, forType: .string)
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

    /// Built fresh each time the sheet opens so the date it states is today's
    /// and the categories it lists are the ones currently on the board.
    private var prompt: String {
        TaskCSV.aiPrompt(categories: categories)
    }

    private var promptHint: String {
        let base = "It tells the AI today\u{2019}s date, gives it a legend for repeating "
            + "tasks (\u{201C}2w:tue\u{201D} is every other Tuesday), and asks it to check with "
            + "you about anything you left out instead of guessing."
        guard !categories.isEmpty else { return base }
        return base + " It also lists your \(categories.count) existing "
            + "categor\(categories.count == 1 ? "y" : "ies") so it reuses them."
    }

    private func actionRow(icon: String, title: String, subtitle: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Theme.accentSoft)
                        .frame(width: 34, height: 34)
                    Image(systemName: icon)
                        .font(Theme.ui(14, .semibold))
                        .foregroundStyle(Theme.accent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.ui(14, .semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(Theme.ui(10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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
                .font(Theme.ui(12, .semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.successSoft, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
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
    let tasks: [TodoItem]
    let count: Int
    let timerRunning: Bool
    let courseColor: (String) -> Color
    let onToggle: (TodoItem) -> Void
    let onFocus: (TodoItem) -> Void
    let onSelect: (TodoItem) -> Void
    let onDrop: (UUID) -> Void
    let onReorder: (_ id: UUID, _ targetID: UUID) -> Void
    let onMove: (_ id: UUID, _ target: TaskColumn) -> Void
    let onMergeDrop: (_ id: UUID, _ targetID: UUID) -> Void
    let onMergePick: (TodoItem) -> Void

    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: column.icon)
                    .font(Theme.ui(11, .semibold))
                    .foregroundStyle(Theme.accent)
                Text(column.rawValue)
                    .font(Theme.ui(12, .semibold))
                    .textCase(.uppercase)
                    .kerning(0.4)
                    .lineLimit(1)
                Text("\(count)")
                    .font(Theme.ui(10, .semibold))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            Divider().overlay(Theme.stroke)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(tasks) { task in
                        TaskCard(task: task,
                                 column: column,
                                 showFocusButton: column == .backlog || column == .upcoming,
                                 courseColor: courseColor,
                                 onToggle: { onToggle(task) },
                                 onFocus: timerRunning ? nil : { onFocus(task) },
                                 onReorder: { droppedID in onReorder(droppedID, task.id) },
                                 onSelect: { onSelect(task) },
                                 onMove: { target in onMove(task.id, target) },
                                 onMergeDrop: { droppedID in onMergeDrop(droppedID, task.id) },
                                 onMergePick: { onMergePick(task) })
                    }
                    if tasks.isEmpty {
                        Text(emptyMessage)
                            .font(Theme.ui(10))
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
        case .backlog: return "Empty — tasks due more than a week out land here."
        case .upcoming: return "Nothing due soon."
        case .doing: return "Drag a task here to start it."
        case .completed: return "Nothing finished yet."
        }
    }
}

// MARK: - Task card

struct TaskCard: View {
    let task: TodoItem
    let column: TaskColumn
    let showFocusButton: Bool
    let courseColor: (String) -> Color
    let onToggle: () -> Void
    var onFocus: (() -> Void)?
    var onReorder: ((UUID) -> Void)?
    var onSelect: (() -> Void)?
    var onMove: ((TaskColumn) -> Void)?
    /// A card was dropped here with Option held: fold the two together
    /// instead of repositioning.
    var onMergeDrop: ((UUID) -> Void)?
    /// "Merge with" from the context menu, which opens the picker instead of
    /// needing a drag at all.
    var onMergePick: (() -> Void)?

    @State private var hovering = false
    /// A card is hovering over this one's body: dropping folds the two into
    /// one.
    @State private var mergeTargeted = false
    /// A card is hovering over the thin strip along the top edge: dropping
    /// puts it in front of this one instead.
    @State private var reorderTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 9) {
                Button(action: onToggle) {
                    ZStack {
                        Circle()
                            .strokeBorder(task.isCompleted ? .clear : (hovering ? Theme.accent : Color.secondary.opacity(0.45)), lineWidth: 1.5)
                            .background(Circle().fill(task.isCompleted ? Theme.accentFill : Color.clear))
                            .frame(width: 18, height: 18)
                        if task.isCompleted {
                            Image(systemName: "checkmark")
                                .font(Theme.ui(9, .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    // The whole disc has to be clickable. An unchecked box is
                    // a stroked ring over a *clear* fill, and a clear fill
                    // takes no clicks — so without this the only hittable part
                    // is the 1.5pt ring, and the box appears to stop working
                    // the moment it's unchecked.
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: task.isCompleted)
                .help(task.isCompleted ? "Mark incomplete" : "Mark complete")

                // Clicking the title or the meta row opens the editor. Those
                // are child tap gestures under the card's own drag, which is
                // what keeps the two from fighting: a tap needs no movement,
                // a drag needs some.
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(Theme.ui(13, .medium))
                        .strikethrough(task.isCompleted)
                        .foregroundStyle(task.isCompleted ? .secondary : .primary)
                        .lineLimit(2)
                    if !task.notes.isEmpty {
                        Text(task.notes)
                            .font(Theme.ui(10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { onSelect?() }

                Spacer(minLength: 0)
                if let onFocus, showFocusButton, hovering {
                    Button(action: onFocus) {
                        Image(systemName: "play.fill")
                            .font(Theme.ui(10, .semibold))
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
                            .font(Theme.ui(11, .semibold))
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
                        .font(Theme.ui(9, .semibold))
                        .foregroundStyle(.tertiary)
                        .help(task.repeatRule.intervalLabel(task.repeatInterval))
                }
                if let course = task.course {
                    TagChip(text: course, color: courseColor(course))
                }
                if let due = task.dueDate {
                    Text(Self.dueLabel(for: due))
                        .font(Theme.ui(10, .medium))
                        .foregroundStyle(task.isOverdue ? Theme.danger : .secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 27)
            .contentShape(Rectangle())
            .onTapGesture { onSelect?() }
        }
        .padding(10)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(borderColor, lineWidth: borderWidth))
        // Pick the card up from anywhere on it. This used to hang off the two
        // inner text views, which left the checkbox column, the spacer, the
        // hover-button strip and all the padding as dead zones — most of the
        // card's area — so grabbing it missed about as often as it hit.
        // Buttons inside still win their own clicks: a drag only begins once
        // the pointer moves.
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .draggable(task.id.uuidString) { dragPreview }
        // Where the card will land. Drawn as a line only — the target used to
        // slide down 5pt to open a gap, which moved it out from under the
        // pointer, cleared `isTargeted`, moved it back, and oscillated.
        .overlay(alignment: .top) {
            if reorderTargeted {
                Capsule()
                    .fill(Theme.accent)
                    .frame(height: 3)
                    .padding(.horizontal, 4)
                    .offset(y: -6)
            }
        }
        // Dropping onto the card itself merges, so reordering keeps a strip
        // of its own along the top edge — the place you already aim for when
        // putting one card in front of another. It sits above the card's own
        // drop area, so it wins inside its own band.
        .overlay(alignment: .top) {
            Color.clear
                .frame(height: 13)
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { droppedItems, _ in
                    guard let onReorder, let idString = droppedItems.first,
                          let id = UUID(uuidString: idString) else { return false }
                    onReorder(id)
                    return true
                } isTargeted: { reorderTargeted = $0 }
        }
        .contextMenu {
            Button("Edit Task\u{2026}") { onSelect?() }
            if let onMergePick {
                Button("Merge With\u{2026}", action: onMergePick)
            }
            Button(task.isCompleted ? "Mark Incomplete" : "Mark Complete", action: onToggle)
            if let onFocus, showFocusButton {
                Button("Start Focus Session", action: onFocus)
            }
            if let onMove {
                Divider()
                Menu("Move to") {
                    ForEach(TaskColumn.allCases.filter { $0 != column }) { target in
                        Button {
                            onMove(target)
                        } label: {
                            Label(target.rawValue, systemImage: target.icon)
                        }
                    }
                }
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.1), value: mergeTargeted)
        .animation(.easeOut(duration: 0.1), value: reorderTargeted)
        .dropDestination(for: String.self) { droppedItems, _ in
            guard let onMergeDrop, let idString = droppedItems.first,
                  let id = UUID(uuidString: idString) else { return false }
            onMergeDrop(id)
            return true
        } isTargeted: { mergeTargeted = $0 }
    }

    /// What you actually pick up. `.draggable` rasterises the view it's
    /// attached to, and it's attached to the title text and the meta row —
    /// the two places that aren't buttons, because putting it on the whole
    /// card would swallow the checkbox's clicks. Without a preview you'd
    /// therefore lift a bare line of text off a card that stays behind, which
    /// is what made dragging feel like nothing had been picked up.
    ///
    /// The outer padding is load-bearing: the drag image is cut to the
    /// preview's bounds, so a shadow given no room around it is clipped away
    /// and the card lands flat.
    private var dragPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 9) {
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.45), lineWidth: 1.5)
                    .frame(width: 18, height: 18)
                Text(task.title)
                    .font(Theme.ui(13, .medium))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                if task.repeatRule != .none {
                    Image(systemName: "repeat")
                        .font(Theme.ui(9, .semibold))
                        .foregroundStyle(.tertiary)
                }
                if let course = task.course {
                    TagChip(text: course, color: courseColor(course))
                }
                if let due = task.dueDate {
                    Text(Self.dueLabel(for: due))
                        .font(Theme.ui(10, .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 27)
        }
        .padding(10)
        .frame(width: 226, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(Theme.accent.opacity(0.65), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.22), radius: 10, y: 5)
        .rotationEffect(.degrees(-1.5))
        .padding(16)
    }

    private var cardBackground: AnyShapeStyle {
        // Filled in while a card hovers over this one, so "drop here to
        // merge" reads differently from "drop here to reorder".
        if mergeTargeted { return AnyShapeStyle(Theme.accentSoft) }
        if column == .completed { return AnyShapeStyle(Theme.successSoft) }
        return AnyShapeStyle(hovering ? Theme.surface : Theme.surface.opacity(0.7))
    }

    private var borderColor: Color {
        if mergeTargeted { return Theme.accent }
        if reorderTargeted { return Theme.accent }
        if column == .completed { return Theme.success }
        if column == .upcoming, !task.isCompleted, let due = task.dueDate {
            return Self.urgencyColor(for: due)
        }
        return Theme.stroke
    }

    private var borderWidth: CGFloat {
        if mergeTargeted || reorderTargeted || column == .completed { return 2 }
        if column == .upcoming, !task.isCompleted, task.dueDate != nil { return 1.5 }
        return 1
    }

    /// How close this card is to its deadline, as the faint red border
    /// `Theme.urgency` draws: barely there a week out, firmest once the day
    /// arrives.
    private static func urgencyColor(for dueDate: Date, now: Date = Date()) -> Color {
        let daysRemaining = dueDate.timeIntervalSince(now) / 86400
        return Theme.urgency(1 - daysRemaining / 7)
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
    /// Identifies the burst in flight, so a burst that ends while a newer one
    /// is running doesn't sweep the newer one's pieces off the screen.
    @State private var burst = 0

    /// Longest a burst can last: the last piece to launch, falling slowest.
    private static let maxLifetime = ScreenConfettiPiece.maxDelay + ScreenConfettiPiece.maxDuration

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(pieces) { piece in
                    shape(for: piece)
                        .rotationEffect(.degrees(animate ? piece.endRotation : piece.startRotation))
                        .rotation3DEffect(.degrees(animate ? piece.tumble : 0), axis: piece.axis)
                        .position(x: (animate ? piece.endX : piece.startX) * proxy.size.width,
                                  y: animate ? proxy.size.height + 40 : -30)
                        // Each piece carries its own curve, delay and duration.
                        // This modifier is what makes them independent — the
                        // single shared `withAnimation` this replaced moved all
                        // of them on one clock, which is why the burst looked
                        // like one line sweeping down the screen.
                        .animation(.easeIn(duration: piece.duration).delay(piece.delay), value: animate)
                        // Applied below the animation above, so it governs only
                        // the fade: pieces stay solid on the way down and go out
                        // near the end of their own fall rather than all at once.
                        .opacity(animate ? 0 : 1)
                        .animation(.easeOut(duration: 0.45)
                            .delay(piece.delay + piece.duration - 0.45), value: animate)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .onChange(of: trigger) { _ in fire() }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func shape(for piece: ScreenConfettiPiece) -> some View {
        if piece.isRound {
            Circle()
                .fill(piece.color)
                .frame(width: piece.size, height: piece.size)
        } else {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(piece.color)
                .frame(width: piece.size, height: piece.size * 0.45)
        }
    }

    private func fire() {
        burst += 1
        let current = burst
        pieces = (0..<110).map { _ in ScreenConfettiPiece() }
        animate = false
        // Deferred a tick so SwiftUI sees false → true as a real change, and
        // set plainly rather than inside `withAnimation`, which would override
        // every piece's own animation with one shared curve.
        DispatchQueue.main.async { animate = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxLifetime + 0.3) {
            guard current == burst else { return }
            pieces = []
            animate = false
        }
    }
}

private struct ScreenConfettiPiece: Identifiable {
    static let maxDelay = 0.6
    static let maxDuration = 2.1

    let id = UUID()
    let color: Color
    /// Start and end as fractions of the overlay's width: a piece drifts
    /// sideways on the way down instead of dropping down a fixed rail.
    let startX: CGFloat
    let endX: CGFloat
    let size: CGFloat
    /// A quarter of the pieces are round, so the burst isn't 110 identical
    /// rectangles.
    let isRound: Bool
    let startRotation: Double
    let endRotation: Double
    /// Tumble through a random 3D axis — a piece that turns edge-on and
    /// briefly disappears reads as paper rather than a falling brick.
    let tumble: Double
    let axis: (x: CGFloat, y: CGFloat, z: CGFloat)
    /// Staggered launch and an individual fall time. These two are the whole
    /// difference between confetti and a curtain.
    let delay: Double
    let duration: Double

    init() {
        let colors: [Color] = [Theme.accent, Theme.violet, Theme.success, Theme.amber, Theme.danger]
        color = colors.randomElement() ?? Theme.accent
        startX = CGFloat.random(in: 0.02...0.98)
        // Clamped loosely rather than to 0...1: a piece is allowed to drift
        // off the edge, which looks better than one sliding along it.
        endX = min(1.08, max(-0.08, startX + CGFloat.random(in: -0.16...0.16)))
        size = CGFloat.random(in: 5...12)
        isRound = Double.random(in: 0...1) < 0.25
        startRotation = Double.random(in: 0...360)
        endRotation = startRotation + Double.random(in: 240...900)
        tumble = Double.random(in: 360...1440)
        axis = (CGFloat.random(in: 0...1), CGFloat.random(in: 0...1), CGFloat.random(in: 0.2...1))
        delay = Double.random(in: 0...Self.maxDelay)
        duration = Double.random(in: 1.1...Self.maxDuration)
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
                    .font(Theme.ui(11, .semibold))
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
                .font(Theme.ui(15, .semibold))

            TextField("Category name", text: $name)
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Theme.surfaceLow, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))

            VStack(alignment: .leading, spacing: 8) {
                Text("Color").font(Theme.ui(10)).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    ForEach(Theme.categoryHueSteps, id: \.self) { step in
                        Circle()
                            .fill(Theme.categoryPastel(hue: step))
                            .frame(width: 24, height: 24)
                            .overlay(Circle().strokeBorder(Theme.stroke, lineWidth: 1))
                            .overlay(
                                Image(systemName: "checkmark")
                                    .font(Theme.ui(10, .semibold))
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

/// Shared by the task editor and the block-schedule editor.
struct WeekdayPicker: View {
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
                        .font(Theme.ui(12, .semibold))
                        .frame(width: 26, height: 26)
                        .foregroundStyle(isOn ? .white : .secondary)
                        .background(isOn ? Theme.accentFill : Theme.surfaceLow, in: Circle())
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
    @State private var customText = ""
    @FocusState private var customFocused: Bool

    /// What Start will actually use: whatever is typed in the custom box if
    /// it's a sane number, otherwise the chosen preset. Nil means the box has
    /// something unusable in it, which disables Start rather than silently
    /// falling back to a duration the user didn't ask for.
    private var minutes: Int? {
        let typed = customText.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return selectedMinutes }
        guard let value = Int(typed), (1...600).contains(value) else { return nil }
        return value
    }

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
                        .font(Theme.ui(20, .semibold))
                        .foregroundStyle(Theme.accent)
                }
                Text("Start a study timer?")
                    .font(Theme.ui(17, .semibold))
                Text("\"\(task.title)\" just moved to Currently Doing.")
                    .font(Theme.ui(12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            .padding(.top, 24)

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    ForEach(FocusTimerController.presetMinutes, id: \.self) { preset in
                        Button("\(preset) min") {
                            selectedMinutes = preset
                            customText = ""
                            customFocused = false
                        }
                        .buttonStyle(SoftPillButtonStyle(
                            tint: customText.isEmpty && selectedMinutes == preset ? Theme.accent : nil))
                    }
                }

                HStack(spacing: 8) {
                    Text("or").font(Theme.ui(12)).foregroundStyle(.secondary)
                    TextField("custom", text: $customText)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.center)
                        .frame(width: 54)
                        .padding(.vertical, 5)
                        .background(Theme.surfaceLow, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(minutes == nil ? Theme.danger : Theme.stroke, lineWidth: 1))
                        .focused($customFocused)
                        .onSubmit { if minutes != nil { start() } }
                    Text("minutes").font(Theme.ui(12)).foregroundStyle(.secondary)
                }
            }

            Toggle(isOn: $lockSessions) {
                Text("Lock session — no giving up until time is up")
                    .font(Theme.ui(12))
            }
            .toggleStyle(CheckToggleStyle())
            .padding(.horizontal, 24)

            HStack {
                Button("Not Now") { dismiss() }
                    .buttonStyle(SoftPillButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(action: start) {
                    Label("Start Timer", systemImage: "play.fill")
                }
                .buttonStyle(ProminentPillButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(minutes == nil)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(width: 360)
        .background(Theme.bg)
    }

    private func start() {
        guard let minutes else { return }
        onStart(minutes, lockSessions)
        dismiss()
    }
}

// MARK: - Task editor

/// Everything the task editor hands back. A plain task and a whole recurring
/// series are the same form now — the repeat rule is just another field on it
/// — so one type describes both.
struct TaskPlan {
    var title: String
    var notes: String
    var course: String?
    /// nil for a task with no due date. A repeating task always has one: it's
    /// where the series starts counting from.
    var dueDate: Date?
    var repeatRule: RepeatRule = .none
    /// 1 = Sunday … 7 = Saturday. Only meaningful with `.weekly`.
    var weekdays: Set<Int> = []
    /// Periods between occurrences — 2 with `.weekly` is "every other week".
    var interval: Int = 1
    /// Last day the series runs, or nil for "repeats indefinitely".
    var endDate: Date?
    /// For a task already in a series: whether Save rewrites every occurrence
    /// still to do, or only the one that was opened.
    var appliesToSeries = false
}

/// The one place a task is written: title, notes, category, due date and —
/// behind a single "Repeats" checkbox — the whole recurring schedule. It
/// creates tasks too (`isNew`), so there's one form to learn rather than a
/// separate sheet per kind of task, and a plain task can be given a due date
/// or turned into a repeating one without leaving it.
struct TaskEditSheet: View {
    /// The task being edited, or a blank draft when `isNew`.
    let task: TodoItem
    var isNew = false
    let courses: [String]
    /// Occurrences of this task's series still pending, or 0 when it isn't
    /// part of one. Says plainly how much "All" would rewrite.
    var seriesPendingCount: Int = 0
    /// Where "All" rebuilds the series from: its first occurrence still to do,
    /// which isn't necessarily the card that was opened. Rebuilding from a
    /// later card would quietly drop the ones before it.
    var seriesStart: Date?
    let onSave: (TaskPlan) -> Void
    /// Absent when creating — there's nothing to delete yet.
    var onDelete: (() -> Void)?
    /// Deletes the rest of the series alongside this task. Absent for a task
    /// that isn't part of one, which keeps Delete a plain one-tap delete
    /// there instead of asking a pointless question.
    var onDeleteSeries: (() -> Void)?
    var courseColor: (String) -> Color = { _ in Theme.accent }
    var onCreateCategory: (_ name: String, _ hue: Double) -> Void = { _, _ in }

    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var notes: String
    @State private var course: String?
    @State private var hasDueDate: Bool
    @State private var dueDay: Date
    @State private var hasDueTime: Bool
    @State private var dueTime: Date
    @State private var repeats: Bool
    @State private var repeatRule: RepeatRule
    @State private var weekdays: Set<Int>
    @State private var interval: Int
    @State private var hasEndDate: Bool
    @State private var endDate: Date
    @State private var applyToSeries: Bool
    @State private var showingDeleteChoice = false

    /// "Never" is the unchecked checkbox now, so it isn't one of the choices.
    private static let repeatOptions: [RepeatRule] = [.daily, .weekly, .monthly]

    init(task: TodoItem, isNew: Bool = false, courses: [String], seriesPendingCount: Int = 0,
         seriesStart: Date? = nil,
         onSave: @escaping (TaskPlan) -> Void,
         onDelete: (() -> Void)? = nil, onDeleteSeries: (() -> Void)? = nil,
         courseColor: @escaping (String) -> Color = { _ in Theme.accent },
         onCreateCategory: @escaping (_ name: String, _ hue: Double) -> Void = { _, _ in }) {
        self.task = task
        self.isNew = isNew
        self.courses = courses
        self.seriesPendingCount = seriesPendingCount
        self.seriesStart = seriesStart
        self.onSave = onSave
        self.onDelete = onDelete
        self.onDeleteSeries = onDeleteSeries
        self.courseColor = courseColor
        self.onCreateCategory = onCreateCategory

        _title = State(initialValue: task.title)
        _notes = State(initialValue: task.notes)
        _course = State(initialValue: task.course)

        // Every date control needs *some* value to sit on even while it's
        // switched off, so an undated task anchors them all on today.
        let calendar = Calendar.current
        let anchor = task.dueDate ?? calendar.startOfDay(for: .now)
        _hasDueDate = State(initialValue: task.dueDate != nil)
        _dueDay = State(initialValue: calendar.startOfDay(for: anchor))
        let time = calendar.dateComponents([.hour, .minute], from: anchor)
        _hasDueTime = State(initialValue: task.dueDate != nil
                            && ((time.hour ?? 0) != 0 || (time.minute ?? 0) != 0))
        _dueTime = State(initialValue: anchor)

        _repeats = State(initialValue: task.repeatRule != .none)
        _repeatRule = State(initialValue: task.repeatRule == .none ? .weekly : task.repeatRule)
        _weekdays = State(initialValue: task.repeatWeekdays)
        _interval = State(initialValue: task.repeatInterval)
        _hasEndDate = State(initialValue: task.seriesEndDate != nil)
        // A sensible first guess for "when does this stop" — about a term out.
        let start = calendar.startOfDay(for: anchor)
        let defaultEnd = calendar.date(byAdding: .month, value: 4, to: start) ?? start
        _endDate = State(initialValue: task.seriesEndDate ?? defaultEnd)
        // Least destructive default: an edit touches the card you opened
        // until you say otherwise.
        _applyToSeries = State(initialValue: false)
    }

    /// True for a card that's one copy of a live recurring series — the only
    /// case where "this one, or all of them?" is a real question.
    private var isSeriesMember: Bool { !isNew && task.isRecurring }

    /// Whether the repeat controls are live. A repeat describes the series as
    /// a whole, so editing a single occurrence can't reach it.
    private var canEditRepeat: Bool { !isSeriesMember || applyToSeries }

    /// A finished task has no schedule left to set, so the checkbox only
    /// appears on one still to do — or on any occurrence of a series, where
    /// it's what the schedule is read from.
    private var showsRepeat: Bool { isNew || !task.isCompleted || isSeriesMember }

    private var combinedDueDate: Date? {
        guard hasDueDate else { return nil }
        return hasDueTime ? combineDateAndTime(date: dueDay, time: dueTime)
                          : Calendar.current.startOfDay(for: dueDay)
    }

    /// The rule as saved. A repeat counts from a start date, so an undated
    /// task is never a repeating one however the checkbox is left.
    private var effectiveRule: RepeatRule { repeats && hasDueDate ? repeatRule : .none }

    /// The dates this series would produce as currently configured — drives
    /// the live "creates N tasks" line, so the scale is visible before Save
    /// rather than after.
    private var previewDates: [Date] {
        guard effectiveRule != .none, let start = combinedDueDate else { return [] }
        return effectiveRule.occurrences(startingAt: start, weekdays: weekdays,
                                         interval: interval,
                                         endDate: hasEndDate ? endDate : nil,
                                         limit: RepeatRule.materializedCount(hasEndDate: hasEndDate))
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

    /// The schedule in one line, for when the repeat controls are read-only.
    private var scheduleSummary: String {
        var parts = [repeatRule.intervalLabel(interval).lowercased()]
        if repeatRule == .weekly, !weekdays.isEmpty {
            let symbols = Calendar.current.shortWeekdaySymbols
            parts.append("on " + weekdays.sorted().map { symbols[$0 - 1] }.joined(separator: ", "))
        }
        if hasEndDate {
            parts.append("until " + endDate.formatted(.dateTime.month(.abbreviated).day()))
        }
        return parts.joined(separator: " ")
    }

    private var canSave: Bool {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return effectiveRule == .none || !previewDates.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(isNew ? "New Task" : "Edit Task")
                .font(Theme.ui(16, .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)

            if isSeriesMember {
                scopePicker
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }

            ScrollView {
                VStack(spacing: 12) {
                    detailsCard
                    scheduleCard
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
            }

            footer
        }
        .frame(width: 460, height: 600)
        .background(Theme.bg)
    }

    // MARK: Scope

    /// The one question the old separate "Edit Series" sheet used to answer by
    /// existing: does this edit land on the card you opened, or on the whole
    /// run? Asking it here is what lets a single form cover both.
    private var scopePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "repeat").font(Theme.ui(11, .semibold))
                Text("This task repeats").font(Theme.ui(11, .medium))
                Spacer(minLength: 0)
                Picker("", selection: $applyToSeries) {
                    Text("This one").tag(false)
                    Text(seriesPendingCount > 1 ? "All \(seriesPendingCount)" : "All").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                // "All" rewrites the run from its first occurrence still to
                // do. Leaving the date on the card that happened to be opened
                // would restart the series there and drop everything before it.
                .onChange(of: applyToSeries) { all in
                    applyDate(all ? (seriesStart ?? task.dueDate) : task.dueDate)
                }
            }
            .foregroundStyle(Theme.accent)

            Text(applyToSeries
                 ? "Saving rebuilds every occurrence still to do from the date below. "
                    + "Ones you\u{2019}ve already completed are kept."
                 : "Changes apply to this copy only. Switch to All to change the schedule.")
                .font(Theme.ui(10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: Fields

    private var detailsCard: some View {
        VStack(spacing: 0) {
            sheetField("Title") {
                TextField("Title", text: $title).textFieldStyle(.plain)
            }
            Divider().overlay(Theme.stroke)
            sheetField("Notes") {
                TextField("Notes", text: $notes, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...4)
            }
            Divider().overlay(Theme.stroke)
            HStack {
                Text("Category").font(Theme.ui(12)).foregroundStyle(.secondary)
                Spacer()
                CategoryPickerButton(selection: $course, courses: courses,
                                     courseColor: courseColor, onCreateCategory: onCreateCategory)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(Theme.stroke, lineWidth: 1))
    }

    private var scheduleCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Due date").font(Theme.ui(12))
                Spacer()
                Toggle("", isOn: $hasDueDate).toggleStyle(GlowToggleStyle()).labelsHidden()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            // A repeat counts from a start date, so the two switches are tied:
            // dropping the due date drops the repeat with it.
            .onChange(of: hasDueDate) { isOn in
                if !isOn { repeats = false }
            }

            if hasDueDate {
                Divider().overlay(Theme.stroke)
                HStack {
                    Text(repeats ? "Starts" : "Due").font(Theme.ui(12))
                    Spacer()
                    DatePicker("", selection: $dueDay, displayedComponents: .date).labelsHidden()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

                Divider().overlay(Theme.stroke)
                HStack {
                    Text(repeats ? "At" : "Due time").font(Theme.ui(12))
                    Spacer()
                    DatePicker("", selection: $dueTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .disabled(!hasDueTime)
                        .opacity(hasDueTime ? 1 : 0.4)
                    Toggle("", isOn: $hasDueTime).toggleStyle(GlowToggleStyle()).labelsHidden()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }

            if showsRepeat {
                repeatToggleRow
            }

            if repeats, canEditRepeat, showsRepeat {
                repeatRows
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(Theme.stroke, lineWidth: 1))
    }

    /// The single checkbox that turns any task into a repeating one — the
    /// whole schedule below it hangs off this one control.
    private var repeatToggleRow: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.stroke)
            HStack {
                Toggle(isOn: $repeats) {
                    Text("Repeats").font(Theme.ui(12))
                }
                .toggleStyle(CheckToggleStyle())
                .disabled(!canEditRepeat)
                .opacity(canEditRepeat ? 1 : 0.5)
                // Checking the box needs a start date to count from, so it
                // supplies one rather than sitting there doing nothing.
                .onChange(of: repeats) { isOn in
                    if isOn { hasDueDate = true }
                }
                Spacer()
                if repeats, !canEditRepeat {
                    Text(scheduleSummary)
                        .font(Theme.ui(10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private var repeatRows: some View {
        Divider().overlay(Theme.stroke)
        HStack {
            Text("Every").font(Theme.ui(12))
            Spacer()
            Picker("", selection: $repeatRule) {
                ForEach(Self.repeatOptions, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)

        Divider().overlay(Theme.stroke)
        HStack {
            Text("How often").font(Theme.ui(12))
            Spacer()
            Text(repeatRule.intervalLabel(interval))
                .font(Theme.ui(12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Stepper("", value: $interval, in: 1...52).labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)

        if repeatRule == .weekly {
            Divider().overlay(Theme.stroke)
            VStack(alignment: .leading, spacing: 8) {
                Text("On these days").font(Theme.ui(10)).foregroundStyle(.secondary)
                WeekdayPicker(selection: $weekdays)
                if weekdays.isEmpty {
                    Text("No days picked — it'll repeat weekly on "
                         + dueDay.formatted(.dateTime.weekday(.wide)) + ".")
                        .font(Theme.ui(10))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }

        Divider().overlay(Theme.stroke)
        HStack {
            Text("Ends").font(Theme.ui(12))
            Spacer()
            DatePicker("", selection: $endDate, in: dueDay..., displayedComponents: .date)
                .labelsHidden()
                .disabled(!hasEndDate)
                .opacity(hasEndDate ? 1 : 0.4)
            Toggle("", isOn: $hasEndDate).toggleStyle(GlowToggleStyle()).labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)

        Divider().overlay(Theme.stroke)
        Label(previewSummary,
              systemImage: previewDates.isEmpty ? "exclamationmark.triangle.fill" : "square.on.square")
            .font(Theme.ui(10))
            .foregroundStyle(previewDates.isEmpty ? Theme.danger : .secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if let onDelete {
                Button {
                    if seriesDeleteCount > 1 {
                        showingDeleteChoice = true
                    } else {
                        onDelete()
                        dismiss()
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(SoftPillButtonStyle(tint: Theme.danger))
                .confirmationDialog("This task repeats.", isPresented: $showingDeleteChoice) {
                    Button("Delete Just This One") {
                        onDelete()
                        dismiss()
                    }
                    Button("Delete All \(seriesDeleteCount) Tasks", role: .destructive) {
                        onDeleteSeries?()
                        dismiss()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Delete only the \(dueLabel) occurrence, or every remaining one in the series? "
                         + "Occurrences you\u{2019}ve already completed are kept either way.")
                }
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(SoftPillButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button(saveLabel) {
                onSave(TaskPlan(title: title, notes: notes, course: course,
                                dueDate: combinedDueDate,
                                repeatRule: effectiveRule,
                                weekdays: effectiveRule == .weekly ? weekdays : [],
                                interval: effectiveRule == .none ? 1 : interval,
                                endDate: effectiveRule != .none && hasEndDate ? endDate : nil,
                                appliesToSeries: isSeriesMember && applyToSeries))
                dismiss()
            }
            .buttonStyle(ProminentPillButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave)
        }
        .padding(20)
    }

    private var saveLabel: String {
        guard isNew else { return applyToSeries ? "Save Series" : "Save" }
        let count = previewDates.count
        return count > 1 ? "Add \(count) Tasks" : "Add Task"
    }

    /// How many tasks "Delete All" would actually remove: every pending
    /// occurrence, plus this one when it's already completed (it isn't
    /// counted among the pending ones). 1 or 0 means there's nothing to ask
    /// about — deleting this task is the whole story.
    private var seriesDeleteCount: Int {
        guard task.seriesID != nil, onDeleteSeries != nil else { return 1 }
        return seriesPendingCount + (task.isCompleted ? 1 : 0)
    }

    /// Names the occurrence being deleted by its due date, so the choice
    /// reads as a date rather than an abstract "this one."
    private var dueLabel: String {
        guard let due = task.dueDate else { return "this" }
        return due.formatted(.dateTime.month(.abbreviated).day())
    }

    /// Points the date controls at `date`, keeping the "has a time" switch in
    /// step with whether that date carries one.
    private func applyDate(_ date: Date?) {
        guard let date else { return }
        let calendar = Calendar.current
        hasDueDate = true
        dueDay = calendar.startOfDay(for: date)
        dueTime = date
        let time = calendar.dateComponents([.hour, .minute], from: date)
        hasDueTime = (time.hour ?? 0) != 0 || (time.minute ?? 0) != 0
    }

    private func sheetField<Content: View>(_ label: String,
                                           @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(Theme.ui(12))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
