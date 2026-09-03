import SwiftUI

/// Review step between choosing a `.ics` file and creating block windows.
///
/// Nothing is created until Import is pressed. A timetable can easily hold a
/// dozen classes, and a schedule that switches blocking on is not something
/// to conjure sight-unseen.
struct ScheduleImportSheet: View {
    let fileName: String
    let outcome: ScheduleICSImport.Outcome
    let groups: [BlockGroup]
    let onImport: ([ScheduleCandidate], Set<UUID>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID>
    @State private var groupIDs: Set<UUID> = []

    init(fileName: String, outcome: ScheduleICSImport.Outcome, groups: [BlockGroup],
         onImport: @escaping ([ScheduleCandidate], Set<UUID>) -> Void) {
        self.fileName = fileName
        self.outcome = outcome
        self.groups = groups
        self.onImport = onImport
        // Everything found is checked to begin with — the common case is
        // importing a whole timetable.
        _selected = State(initialValue: Set(outcome.candidates.map(\.id)))
    }

    private var chosen: [ScheduleCandidate] {
        outcome.candidates.filter { selected.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Import Schedule")
                    .font(Theme.ui(16, .semibold))
                Text(fileName)
                    .font(Theme.ui(10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            if outcome.candidates.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Each of these becomes a weekly window that switches your block "
                             + "lists on. The calendar\u{2019}s dates are dropped \u{2014} only the "
                             + "days and times are kept.")
                            .font(Theme.ui(11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        candidateList
                        if !outcome.skippedSummary.isEmpty {
                            Label(outcome.skippedSummary, systemImage: "info.circle")
                                .font(Theme.ui(10))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        groupList
                        Label("Schedules never lock. Anything imported can be edited or "
                              + "switched off afterwards.", systemImage: "lock.open")
                            .font(Theme.ui(10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 4)
                }
            }

            HStack {
                if !outcome.candidates.isEmpty {
                    Button(selected.count == outcome.candidates.count ? "Deselect All" : "Select All") {
                        selected = selected.count == outcome.candidates.count
                            ? [] : Set(outcome.candidates.map(\.id))
                    }
                    .buttonStyle(SoftPillButtonStyle())
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SoftPillButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(chosen.count == 1 ? "Add 1 Schedule" : "Add \(chosen.count) Schedules") {
                    onImport(chosen, groupIDs)
                    dismiss()
                }
                .buttonStyle(ProminentPillButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 480, height: 560)
        .background(Theme.bg)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(Theme.ui(24))
                .foregroundStyle(.tertiary)
            Text("Nothing to import")
                .font(Theme.ui(13, .semibold))
            Text(outcome.skippedSummary.isEmpty
                 ? "That file didn\u{2019}t contain any timed events."
                 : outcome.skippedSummary + " A block window needs a start and an end time on the same day.")
                .font(Theme.ui(11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var candidateList: some View {
        VStack(spacing: 0) {
            ForEach(Array(outcome.candidates.enumerated()), id: \.element.id) { index, candidate in
                if index > 0 { Divider().overlay(Theme.stroke) }
                Toggle(isOn: Binding(
                    get: { selected.contains(candidate.id) },
                    set: { isOn in
                        if isOn { selected.insert(candidate.id) } else { selected.remove(candidate.id) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.name)
                            .font(Theme.ui(12, .medium))
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(candidate.daysLabel)
                            Text("\u{00B7}")
                            Text(candidate.timeLabel)
                            if !candidate.fromRecurrenceRule {
                                Text("\u{00B7}")
                                // Worth saying: the calendar never claimed this
                                // repeats — the pattern came from folding
                                // separate entries together.
                                Text(candidate.mergedCount > 1
                                     ? "from \(candidate.mergedCount) entries"
                                     : "one-off")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .font(Theme.ui(10))
                        .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(CheckToggleStyle())
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(Theme.stroke, lineWidth: 1))
    }

    private var groupList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Switch on these lists").font(Theme.ui(11, .semibold))
                Spacer()
                if groupIDs.isEmpty {
                    Text("All lists").font(Theme.ui(10)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if groups.isEmpty {
                Divider().overlay(Theme.stroke)
                Text("No block lists yet — these windows will switch on every list you make.")
                    .font(Theme.ui(10))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            } else {
                ForEach(groups) { group in
                    Divider().overlay(Theme.stroke)
                    Toggle(isOn: Binding(
                        get: { groupIDs.isEmpty || groupIDs.contains(group.id) },
                        set: { isOn in
                            // An empty set means "every list", so the first
                            // change has to make that implicit selection
                            // explicit before removing from it.
                            if groupIDs.isEmpty { groupIDs = Set(groups.map(\.id)) }
                            if isOn { groupIDs.insert(group.id) } else { groupIDs.remove(group.id) }
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
    }
}
