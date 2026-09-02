import SwiftUI

struct ScheduleEditSheet: View {
    @State private var schedule: BlockSchedule
    let isNew: Bool
    let groups: [BlockGroup]
    let onSave: (BlockSchedule) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var start: Date
    @State private var end: Date

    init(schedule: BlockSchedule, isNew: Bool, groups: [BlockGroup],
         onSave: @escaping (BlockSchedule) -> Void) {
        _schedule = State(initialValue: schedule)
        self.isNew = isNew
        self.groups = groups
        self.onSave = onSave
        _start = State(initialValue: Self.date(fromMinute: schedule.startMinute))
        _end = State(initialValue: Self.date(fromMinute: schedule.endMinute))
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(isNew ? "New Schedule" : "Edit Schedule")
                .font(Theme.ui(16, .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)

            ScrollView {
                VStack(spacing: 12) {
                    VStack(spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("Name").font(Theme.ui(12)).foregroundStyle(.secondary)
                                .frame(width: 64, alignment: .leading)
                            TextField("e.g. School hours, Evening study", text: $schedule.name)
                                .textFieldStyle(.plain)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)

                        Divider().overlay(Theme.stroke)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("On these days").font(Theme.ui(10)).foregroundStyle(.secondary)
                            WeekdayPicker(selection: $schedule.weekdays)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)

                        Divider().overlay(Theme.stroke)
                        HStack {
                            Text("From").font(Theme.ui(12))
                            Spacer()
                            DatePicker("", selection: $start, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                            Text("to").font(Theme.ui(12)).foregroundStyle(.secondary)
                            DatePicker("", selection: $end, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)

                        if isOvernight {
                            Divider().overlay(Theme.stroke)
                            Label("Runs overnight — it starts on the days above and ends the next morning.",
                                  systemImage: "moon.stars")
                                .font(Theme.ui(10))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                        }
                    }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Theme.stroke, lineWidth: 1))

                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("Block lists").font(Theme.ui(12))
                            Spacer()
                            Text(schedule.groupIDs.isEmpty ? "Every list"
                                 : "\(schedule.groupIDs.count) selected")
                                .font(Theme.ui(10))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)

                        if groups.isEmpty {
                            Divider().overlay(Theme.stroke)
                            Text("No block lists yet — make one on the Focus page.")
                                .font(Theme.ui(10))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                        } else {
                            ForEach(groups) { group in
                                Divider().overlay(Theme.stroke)
                                Toggle(isOn: Binding(
                                    get: { schedule.groupIDs.isEmpty || schedule.groupIDs.contains(group.id) },
                                    set: { isOn in
                                        // An empty set means "every list", so the
                                        // first change has to make that implicit
                                        // selection explicit before removing from it.
                                        if schedule.groupIDs.isEmpty {
                                            schedule.groupIDs = Set(groups.map(\.id))
                                        }
                                        if isOn { schedule.groupIDs.insert(group.id) }
                                        else { schedule.groupIDs.remove(group.id) }
                                    }
                                )) {
                                    HStack(spacing: 8) {
                                        Text(group.name).font(Theme.ui(12))
                                        Text("\(group.domains.count)")
                                            .font(Theme.ui(10, .semibold))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .toggleStyle(GlowToggleStyle())
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                            }
                        }
                    }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Theme.stroke, lineWidth: 1))

                    Label("A schedule never locks. It switches blocking on when the window opens \u{2014} you can always switch it off.",
                          systemImage: "lock.open")
                        .font(Theme.ui(10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 20)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SoftPillButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Schedule" : "Save") {
                    var saved = schedule
                    saved.name = schedule.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    saved.startMinute = Self.minute(from: start)
                    saved.endMinute = Self.minute(from: end)
                    onSave(saved)
                    dismiss()
                }
                .buttonStyle(ProminentPillButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding(20)
        }
        .frame(width: 460, height: 560)
        .background(Theme.bg)
    }

    private var isOvernight: Bool {
        Self.minute(from: end) <= Self.minute(from: start)
    }

    private var isValid: Bool {
        !schedule.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !schedule.weekdays.isEmpty
            && Self.minute(from: start) != Self.minute(from: end)
    }

    private static func date(fromMinute minutes: Int) -> Date {
        var components = DateComponents()
        components.hour = minutes / 60
        components.minute = minutes % 60
        return Calendar.current.date(from: components) ?? Date()
    }

    private static func minute(from date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}
