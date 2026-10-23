import Combine
import SwiftUI

struct EventsView: View {
    @EnvironmentObject private var store: EventStore
    @EnvironmentObject private var tasks: TaskStore

    @State private var today: CalendarDay
    @State private var month: CalendarMonth
    /// The highlighted day: what the side panel lists, and where an exam
    /// typed without a date goes.
    @State private var selected: CalendarDay
    @State private var quickAddText = ""
    @State private var quickAddCourse: String?
    @State private var editing: StudyEvent?
    @FocusState private var quickAddFocused: Bool

    init() {
        let today = EventCalendar.current.today()
        _today = State(initialValue: today)
        _month = State(initialValue: CalendarMonth(containing: today))
        _selected = State(initialValue: today)
    }

    private var calendar: EventCalendar { .current }

    /// The board's categories as well as the exams' own, so an exam can be
    /// filed under a subject that so far only has tasks.
    private var courses: [String] {
        Array(Set(tasks.courses + store.courses)).sorted()
    }

    var body: some View {
        let calendar = self.calendar
        VStack(spacing: 0) {
            PageHeader("Events", subtitle: calendar.headline(for: store.events, today: today)) {
                monthNavigator(calendar)
            }

            quickAddBar(calendar)
                .padding(.horizontal, 28)
                .padding(.bottom, 16)

            HStack(alignment: .top, spacing: 20) {
                MonthGrid(weeks: calendar.weeks(in: month),
                          weekdaySymbols: calendar.weekdaySymbols,
                          month: month,
                          today: today,
                          selected: selected,
                          eventsByDay: EventCalendar.byDay(store.events),
                          color: color(for:),
                          onSelect: go(to:),
                          onAddOn: { day in
                              go(to: day)
                              quickAddFocused = true
                          },
                          onOpen: { event in
                              go(to: event.day)
                              editing = event
                          },
                          onDelete: { store.delete($0.id) })

                sidePanel(calendar)
                    .frame(width: 250)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
        .sheet(item: $editing) { event in
            EventEditSheet(event: event, calendar: calendar, courses: courses,
                           courseColor: { tasks.color(for: $0) },
                           suggestedHue: tasks.nextCategoryHue,
                           onCreateCategory: { name, hue in tasks.setHue(hue, for: name) },
                           onSave: save,
                           onDelete: { store.delete(event.id) })
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
            .receive(on: RunLoop.main)) { _ in
            advanceToday()
        }
    }

    private func color(for event: StudyEvent) -> Color {
        event.course.map { tasks.color(for: $0) } ?? Theme.accent
    }

    private func go(to day: CalendarDay) {
        selected = day
        month = CalendarMonth(containing: day)
    }

    /// A page left open overnight would otherwise spend the morning pointing
    /// at yesterday. The selection and the month follow today only if they
    /// were on it, so a day picked on purpose stays picked.
    private func advanceToday() {
        let old = today
        today = calendar.today()
        guard today != old else { return }
        if selected == old { selected = today }
        if month == CalendarMonth(containing: old) { month = CalendarMonth(containing: today) }
    }

    private func save(_ event: StudyEvent) {
        if let course = event.course { tasks.claimHue(for: course) }
        store.update(event)
        go(to: event.day)
    }

    // MARK: - Header

    private func monthNavigator(_ calendar: EventCalendar) -> some View {
        HStack(spacing: 6) {
            Button { month = month.adding(months: -1) } label: {
                Image(systemName: "chevron.left").font(Theme.ui(12, .semibold))
            }
            .buttonStyle(IconButtonStyle())
            .help("Previous month")

            Text(calendar.date(of: month.firstDay).formatted(.dateTime.month(.wide).year()))
                .font(Theme.ui(14, .semibold))
                .frame(minWidth: 130)

            Button { month = month.adding(months: 1) } label: {
                Image(systemName: "chevron.right").font(Theme.ui(12, .semibold))
            }
            .buttonStyle(IconButtonStyle())
            .help("Next month")

            Button("Today") { go(to: today) }
                .buttonStyle(SoftPillButtonStyle())
                .disabled(selected == today && month == CalendarMonth(containing: today))
        }
    }

    // MARK: - Quick add

    private func quickAddBar(_ calendar: EventCalendar) -> some View {
        // Parsed as you type, so the day an exam will land on is visible
        // before Return rather than discovered after it.
        let landing = calendar.quickAdd(quickAddText, course: quickAddCourse,
                                        selectedDay: selected, knownCourses: courses)?.day ?? selected
        return HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Theme.accentFill)
                    .frame(width: 26, height: 26)
                Image(systemName: "plus")
                    .font(Theme.ui(12, .semibold))
                    .foregroundStyle(.white)
            }
            TextField("Add an exam \u{2014} try: chem final oct 14 #chem", text: $quickAddText)
                .textFieldStyle(.plain)
                .font(Theme.ui(14))
                .focused($quickAddFocused)
                .onSubmit(submitQuickAdd)
            Label(calendar.date(of: landing).formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()),
                  systemImage: "calendar")
                .font(Theme.ui(11, .medium))
                .foregroundStyle(.secondary)
                .fixedSize()
                .help("The day this exam goes on. Type a date to pick another, or click a day in the calendar.")
            CategoryPickerButton(selection: $quickAddCourse, courses: courses,
                                 courseColor: { tasks.color(for: $0) },
                                 suggestedHue: tasks.nextCategoryHue,
                                 onCreateCategory: { name, hue in tasks.setHue(hue, for: name) })
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(quickAddFocused ? Theme.accent.opacity(0.55) : Theme.stroke, lineWidth: 1))
        .animation(.easeOut(duration: 0.15), value: quickAddFocused)
    }

    private func submitQuickAdd() {
        guard let event = calendar.quickAdd(quickAddText, course: quickAddCourse,
                                            selectedDay: selected, knownCourses: courses)
        else { return }
        if let course = event.course { tasks.claimHue(for: course) }
        guard store.add(event) else { return }
        // A typed date can land in another month; show it there.
        go(to: event.day)
        quickAddText = ""
        quickAddCourse = nil
    }

    // MARK: - Side panel

    private func sidePanel(_ calendar: EventCalendar) -> some View {
        let onDay = EventCalendar.byDay(store.events)[selected] ?? []
        let upcoming = EventCalendar.upcoming(store.events, from: today)
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    panelTitle(calendar.date(of: selected).formatted(.dateTime.weekday(.wide).month(.wide).day()),
                               detail: calendar.countdown(to: selected, from: today))
                    if onDay.isEmpty {
                        panelNote(selected >= today
                                  ? "No exams. Type one in the box above to add it to this day."
                                  : "No exams on this day.")
                    }
                    ForEach(onDay) { event in
                        row(event, calendar: calendar, showsDate: false)
                            .onTapGesture { editing = event }
                            .help("Edit this exam")
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    panelTitle("Coming up", detail: upcoming.isEmpty ? nil : "\(upcoming.count)")
                    if upcoming.isEmpty {
                        panelNote("Nothing coming up. Exams you add appear here with a countdown.")
                    }
                    ForEach(upcoming) { event in
                        row(event, calendar: calendar, showsDate: true)
                            .onTapGesture { go(to: event.day) }
                            .help("Show this day in the calendar")
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func row(_ event: StudyEvent, calendar: EventCalendar, showsDate: Bool) -> some View {
        EventRow(event: event,
                 color: color(for: event),
                 dateLabel: showsDate
                     ? calendar.date(of: event.day).formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
                     : nil,
                 countdown: calendar.countdown(to: event.day, from: today),
                 urgency: calendar.urgency(of: event.day, from: today))
            .contextMenu {
                Button("Edit\u{2026}") { editing = event }
                Button("Delete", role: .destructive) { store.delete(event.id) }
            }
    }

    private func panelTitle(_ title: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(Theme.ui(13, .semibold))
            Spacer(minLength: 6)
            if let detail {
                Text(detail).font(Theme.ui(11)).foregroundStyle(.secondary)
            }
        }
    }

    private func panelNote(_ text: String) -> some View {
        Text(text)
            .font(Theme.ui(11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Month grid

private struct MonthGrid: View {
    let weeks: [[CalendarDay]]
    let weekdaySymbols: [String]
    let month: CalendarMonth
    let today: CalendarDay
    let selected: CalendarDay
    let eventsByDay: [CalendarDay: [StudyEvent]]
    let color: (StudyEvent) -> Color
    let onSelect: (CalendarDay) -> Void
    let onAddOn: (CalendarDay) -> Void
    let onOpen: (StudyEvent) -> Void
    let onDelete: (StudyEvent) -> Void

    /// Height of one exam line in a cell, spacing included.
    private static let lineHeight: CGFloat = 19
    /// A cell's padding plus its day number.
    private static let cellChrome: CGFloat = 32

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol.uppercased())
                        .font(Theme.ui(10, .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 8)

            Divider().overlay(Theme.stroke)

            GeometryReader { proxy in
                // Sized from the grid, not left to the stacks: a flexible cell
                // grows to fit its contents, and one busy day would push its
                // column out of line with the rows above and below it.
                let rows = CGFloat(max(weeks.count, 1))
                let columnWidth = (proxy.size.width - 6) / 7
                let rowHeight = (proxy.size.height - (rows - 1)) / rows
                // Too narrow for a readable title means dots instead, not
                // titles cut down to two letters.
                let capacity = columnWidth < 70
                    ? 0 : max(0, Int((rowHeight - Self.cellChrome) / Self.lineHeight))
                VStack(spacing: 0) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { index, week in
                        if index > 0 { Divider().overlay(Theme.stroke) }
                        HStack(spacing: 0) {
                            ForEach(Array(week.enumerated()), id: \.element) { column, day in
                                if column > 0 { Divider().overlay(Theme.stroke) }
                                DayCell(day: day,
                                        isInMonth: CalendarMonth(containing: day) == month,
                                        isToday: day == today,
                                        isPast: day < today,
                                        isSelected: day == selected,
                                        events: eventsByDay[day] ?? [],
                                        capacity: capacity,
                                        color: color,
                                        onSelect: { onSelect(day) },
                                        onAddOn: { onAddOn(day) },
                                        onOpen: onOpen,
                                        onDelete: onDelete)
                                    .frame(width: columnWidth, height: rowHeight)
                                    .clipped()
                            }
                        }
                    }
                }
            }
        }
        .frame(minHeight: 360)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
    }
}

private struct DayCell: View {
    let day: CalendarDay
    let isInMonth: Bool
    let isToday: Bool
    let isPast: Bool
    let isSelected: Bool
    let events: [StudyEvent]
    /// Exam lines that fit; zero means the cell shows dots.
    let capacity: Int
    let color: (StudyEvent) -> Color
    let onSelect: () -> Void
    let onAddOn: () -> Void
    let onOpen: (StudyEvent) -> Void
    let onDelete: (StudyEvent) -> Void

    @State private var hovering = false

    /// When they don't all fit, the last line becomes "+N more" rather than
    /// one more title, so the count of what's hidden is always on screen.
    private var shown: ArraySlice<StudyEvent> {
        events.count <= capacity ? events[...] : events.prefix(max(0, capacity - 1))
    }

    private var hiddenCount: Int { events.count - shown.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(day.day)")
                .font(Theme.number(11.5, weight: isToday ? .semibold : .medium))
                .foregroundStyle(numberColor)
                .frame(width: 22, height: 22)
                .background(Circle().fill(isToday ? Theme.accentFill : Color.clear))

            Group {
                if capacity == 0 {
                    dots
                } else {
                    ForEach(shown) { chip($0) }
                    if hiddenCount > 0 {
                        Text(hiddenCount == events.count ? "\(hiddenCount) exams" : "+\(hiddenCount) more")
                            .font(Theme.ui(10, .medium))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 5)
                    }
                }
            }
            .opacity(isPast ? 0.6 : 1)
        }
        .padding(5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(isInMonth ? 1 : 0.5)
        .background(background)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onSelect)
        // Simultaneous, so the first click selects at once instead of
        // waiting to learn whether a second is coming.
        .simultaneousGesture(TapGesture(count: 2).onEnded(onAddOn))
        .help(isInMonth ? "Click to select, double-click to add an exam on this day" : "")
    }

    private var numberColor: Color {
        if isToday { return .white }
        if !isInMonth || isPast { return .secondary }
        return .primary
    }

    private var background: Color {
        if isSelected { return Theme.accentSoft }
        if hovering { return Theme.surfaceLow.opacity(0.6) }
        if !isInMonth { return Theme.surfaceLow.opacity(0.35) }
        return .clear
    }

    private var dots: some View {
        HStack(spacing: 3) {
            ForEach(events.prefix(4)) { event in
                Circle().fill(color(event)).frame(width: 6, height: 6)
            }
        }
        .padding(.leading, 4)
    }

    private func chip(_ event: StudyEvent) -> some View {
        let tint = color(event)
        return Text(event.title)
            .font(Theme.ui(10, .semibold))
            .lineLimit(1)
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { onOpen(event) }
            .help(event.course.map { "\(event.title) \u{00B7} \($0)" } ?? event.title)
            .contextMenu {
                Button("Edit\u{2026}") { onOpen(event) }
                Button("Delete", role: .destructive) { onDelete(event) }
            }
    }
}

// MARK: - Rows

private struct EventRow: View {
    let event: StudyEvent
    let color: Color
    let dateLabel: String?
    let countdown: String
    let urgency: EventCalendar.Urgency

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 5) {
                Text(event.title)
                    .font(Theme.ui(12.5, .semibold))
                    .lineLimit(2)
                if event.course != nil || dateLabel != nil {
                    HStack(spacing: 6) {
                        if let course = event.course {
                            TagChip(text: course, color: color)
                        }
                        if let dateLabel {
                            Text(dateLabel)
                                .font(Theme.ui(10.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Spacer(minLength: 6)
            Text(countdown)
                .font(Theme.ui(10.5, .semibold))
                .foregroundStyle(countdownColor)
                .fixedSize()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? Theme.surfaceLow : Theme.surface,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var countdownColor: Color {
        switch urgency {
        case .imminent: return Theme.danger
        case .soon: return Theme.amber
        case .later: return .secondary
        }
    }
}

// MARK: - Editor

private struct EventEditSheet: View {
    let event: StudyEvent
    let calendar: EventCalendar
    let courses: [String]
    let courseColor: (String) -> Color
    let suggestedHue: Double
    let onCreateCategory: (_ name: String, _ hue: Double) -> Void
    let onSave: (StudyEvent) -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var course: String?
    @State private var date: Date

    init(event: StudyEvent, calendar: EventCalendar, courses: [String],
         courseColor: @escaping (String) -> Color, suggestedHue: Double,
         onCreateCategory: @escaping (_ name: String, _ hue: Double) -> Void,
         onSave: @escaping (StudyEvent) -> Void, onDelete: @escaping () -> Void) {
        self.event = event
        self.calendar = calendar
        self.courses = courses
        self.courseColor = courseColor
        self.suggestedHue = suggestedHue
        self.onCreateCategory = onCreateCategory
        self.onSave = onSave
        self.onDelete = onDelete
        _title = State(initialValue: event.title)
        _course = State(initialValue: event.course)
        _date = State(initialValue: calendar.date(of: event.day))
    }

    private var isBlank: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Exam")
                .font(Theme.ui(16, .semibold))

            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Title")
                        .font(Theme.ui(12))
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .leading)
                    TextField("Title", text: $title).textFieldStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider().overlay(Theme.stroke)
                HStack {
                    Text("Category").font(Theme.ui(12)).foregroundStyle(.secondary)
                    Spacer()
                    CategoryPickerButton(selection: $course, courses: courses,
                                         courseColor: courseColor, suggestedHue: suggestedHue,
                                         onCreateCategory: onCreateCategory)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider().overlay(Theme.stroke)
                HStack {
                    Text("Date").font(Theme.ui(12)).foregroundStyle(.secondary)
                    Spacer()
                    DatePicker("", selection: $date, displayedComponents: .date).labelsHidden()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))

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
                    var updated = event
                    updated.title = title
                    updated.course = course
                    updated.day = calendar.day(of: date)
                    onSave(updated)
                    dismiss()
                }
                .buttonStyle(ProminentPillButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(isBlank)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(Theme.bg)
    }
}
