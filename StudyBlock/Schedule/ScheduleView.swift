import SwiftUI

struct ScheduleView: View {
    @EnvironmentObject private var scheduler: BlockScheduleController
    @EnvironmentObject private var blocker: BlockerViewModel

    @State private var editing: BlockSchedule?
    @State private var isNew = false
    @State private var deleting: BlockSchedule?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("Schedule", subtitle: headerSubtitle) {
                Button {
                    editing = BlockSchedule(name: "")
                    isNew = true
                } label: {
                    Label("New Schedule", systemImage: "plus")
                }
                .buttonStyle(ProminentPillButtonStyle())
            }

            ScrollView {
                VStack(spacing: 16) {
                    WeekGrid(schedules: scheduler.schedules, activeIDs: scheduler.activeIDs)
                        .card()

                    if scheduler.schedules.isEmpty {
                        EmptyState(icon: "calendar",
                                   title: "No schedules yet",
                                   message: "Set the hours you want your block lists switched on and StudyBlock will turn them on for you. Schedules never lock — you can always switch one off.")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 30)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(scheduler.schedules) { schedule in
                                row(schedule)
                            }
                        }
                        .card()
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
        }
        .sheet(item: $editing) { schedule in
            ScheduleEditSheet(schedule: schedule, isNew: isNew, groups: blocker.groups) { saved in
                if isNew { scheduler.add(saved) } else { scheduler.update(saved) }
            }
        }
        .confirmationDialog("Delete this schedule?",
                            isPresented: Binding(get: { deleting != nil },
                                                 set: { if !$0 { deleting = nil } })) {
            Button("Delete \u{201C}\(deleting?.name ?? "")\u{201D}", role: .destructive) {
                if let schedule = deleting { scheduler.delete(schedule.id) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("Its hours stop switching your block lists on. Nothing currently blocked changes until the window would have ended.")
        }
    }

    private var headerSubtitle: String {
        let active = scheduler.activeSchedules
        if let first = active.first {
            return active.count == 1
                ? "\u{201C}\(first.name)\u{201D} is on now until \(BlockSchedule.clockLabel(first.endMinute))"
                : "\(active.count) schedules are on now"
        }
        let enabled = scheduler.schedules.filter(\.isEnabled).count
        if enabled == 0 { return "Blocking turns on by itself during the hours you set" }
        return "\(enabled) schedule\(enabled == 1 ? "" : "s") — nothing on right now"
    }

    private func row(_ schedule: BlockSchedule) -> some View {
        let isActive = scheduler.activeIDs.contains(schedule.id)

        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(isActive ? Theme.successSoft : Theme.surfaceLow)
                    .frame(width: 34, height: 34)
                Image(systemName: isActive ? "shield.fill" : "clock")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isActive ? Theme.success : .secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(schedule.name.isEmpty ? "Untitled" : schedule.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(schedule.isEnabled ? .primary : .secondary)
                    if isActive {
                        Text("ON NOW")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .kerning(0.4)
                            .foregroundStyle(Theme.success)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.successSoft, in: Capsule())
                    }
                }
                Text("\(schedule.daysLabel) · \(schedule.timeLabel) · \(listsLabel(schedule))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Menu {
                Button("Edit\u{2026}") {
                    editing = schedule
                    isNew = false
                }
                Divider()
                Button("Delete Schedule", role: .destructive) { deleting = schedule }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Toggle("", isOn: Binding(
                get: { schedule.isEnabled },
                set: { scheduler.setEnabled(schedule.id, $0) }
            ))
            .toggleStyle(GlowToggleStyle())
            .labelsHidden()
        }
        .padding(12)
        .background(Theme.surfaceLow.opacity(schedule.isEnabled ? 1 : 0.5),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(isActive ? Theme.success : Theme.stroke, lineWidth: isActive ? 1.5 : 1))
    }

    private func listsLabel(_ schedule: BlockSchedule) -> String {
        guard !schedule.groupIDs.isEmpty else { return "every list" }
        let names = blocker.groups.filter { schedule.groupIDs.contains($0.id) }.map(\.name)
        return names.isEmpty ? "every list" : names.joined(separator: ", ")
    }
}

// MARK: - Week grid

/// The calendar itself: seven day columns with each schedule drawn as a bar
/// over the hours it covers.
private struct WeekGrid: View {
    let schedules: [BlockSchedule]
    let activeIDs: Set<UUID>

    private static let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let hourHeight: CGFloat = 22
    private static let gutter: CGFloat = 46

    /// Hours worth drawing: the span the schedules actually occupy, padded an
    /// hour either side and never narrower than a working day — so an empty
    /// week still reads as a calendar rather than a sliver.
    private var hourRange: ClosedRange<Int> {
        let bars = schedules.filter(\.isEnabled).flatMap(\.segments)
        guard !bars.isEmpty else { return 8...20 }
        let first = max(0, (bars.map(\.start).min() ?? 480) / 60 - 1)
        let last = min(24, Int(ceil(Double(bars.map(\.end).max() ?? 1200) / 60)) + 1)
        guard last - first >= 8 else {
            let start = max(0, min(first, 24 - 8))
            return start...(start + 8)
        }
        return first...last
    }

    var body: some View {
        let hours = hourRange
        let height = CGFloat(hours.upperBound - hours.lowerBound) * Self.hourHeight

        VStack(alignment: .leading, spacing: 10) {
            Text("Your week")
                .font(.system(size: 15, weight: .semibold))

            HStack(spacing: 0) {
                Color.clear.frame(width: Self.gutter)
                ForEach(1...7, id: \.self) { day in
                    Text(Self.dayNames[day - 1])
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(day == todayWeekday ? Theme.accent : .secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            HStack(alignment: .top, spacing: 0) {
                // Hour labels
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(hours.lowerBound..<hours.upperBound, id: \.self) { hour in
                        Text(BlockSchedule.clockLabel(hour * 60))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .frame(height: Self.hourHeight, alignment: .top)
                            .offset(y: -4)
                    }
                }
                .frame(width: Self.gutter - 6, alignment: .trailing)
                .padding(.trailing, 6)

                ForEach(1...7, id: \.self) { day in
                    dayColumn(day, hours: hours, height: height)
                }
            }
            .frame(height: height)
        }
    }

    private var todayWeekday: Int {
        Calendar.current.component(.weekday, from: .now)
    }

    private func dayColumn(_ day: Int, hours: ClosedRange<Int>, height: CGFloat) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                // Hour lines
                VStack(spacing: 0) {
                    ForEach(hours.lowerBound..<hours.upperBound, id: \.self) { _ in
                        VStack(spacing: 0) {
                            Rectangle().fill(Theme.stroke).frame(height: 1)
                            Spacer(minLength: 0)
                        }
                        .frame(height: Self.hourHeight)
                    }
                }

                ForEach(bars(for: day), id: \.key) { bar in
                    let top = offset(forMinute: bar.start, in: hours)
                    let bottom = offset(forMinute: bar.end, in: hours)
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(bar.isActive ? AnyShapeStyle(Theme.accentGradient)
                                           : AnyShapeStyle(Theme.accent.opacity(0.28)))
                        .overlay(alignment: .topLeading) {
                            Text(bar.name)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(bar.isActive ? .white : Theme.accent)
                                .lineLimit(1)
                                .padding(.horizontal, 4)
                                .padding(.top, 2)
                        }
                        .frame(height: max(10, bottom - top))
                        .offset(y: top)
                        .help("\(bar.name) — \(BlockSchedule.clockLabel(bar.start))\u{2013}\(BlockSchedule.clockLabel(bar.end))")
                }
            }
            .frame(width: proxy.size.width, height: height, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .background(day == todayWeekday ? Theme.accentSoft.opacity(0.35) : .clear)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.stroke).frame(width: 1) }
    }

    private struct Bar {
        let key: String
        let name: String
        let start: Int
        let end: Int
        let isActive: Bool
    }

    private func bars(for day: Int) -> [Bar] {
        schedules.filter(\.isEnabled).flatMap { schedule in
            schedule.segments.filter { $0.weekday == day }.enumerated().map { index, segment in
                Bar(key: "\(schedule.id)-\(day)-\(index)",
                    name: schedule.name.isEmpty ? "Untitled" : schedule.name,
                    start: segment.start,
                    end: segment.end,
                    isActive: activeIDs.contains(schedule.id))
            }
        }
    }

    private func offset(forMinute minute: Int, in hours: ClosedRange<Int>) -> CGFloat {
        let clamped = min(max(minute, hours.lowerBound * 60), hours.upperBound * 60)
        return CGFloat(clamped - hours.lowerBound * 60) / 60 * Self.hourHeight
    }
}
