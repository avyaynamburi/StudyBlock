import Charts
import SwiftUI

/// The stats page, built around one question: how is today going, compared
/// with the days behind it?
///
/// Everything on it is derived in `StatsSummary`, which is where the
/// arithmetic and the wording live. This file is layout.
struct StatsView: View {
    @EnvironmentObject private var stats: StatsStore
    @EnvironmentObject private var tasks: TaskStore

    /// The day's target. Kept in defaults rather than a store because it is a
    /// preference, not history — there is nothing to migrate and nothing to
    /// merge.
    @AppStorage("dailyGoalMinutes") private var goalMinutes: Double = 120
    @State private var subjectRange: SubjectRange = .today

    private enum SubjectRange: String, CaseIterable, Identifiable {
        case today, week
        var id: String { rawValue }
        var label: String { self == .today ? "Today" : "This week" }
    }

    /// Goals worth offering. Anything under half an hour isn't a study
    /// session, and anything over four hours is a day, not a target.
    private static let goalChoices: [Double] = [30, 45, 60, 90, 120, 180, 240]

    private var summary: StatsSummary {
        stats.summary(goalMinutes: goalMinutes,
                      tasksToday: tasks.completedCount(on: .now),
                      tasksYesterday: tasks.completedCount(on: yesterday))
    }

    var body: some View {
        let summary = summary
        VStack(spacing: 0) {
            PageHeader("Stats", subtitle: "How today is going") {
                goalMenu
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    todayCard(summary)
                    tileRow(summary)
                    subjectCard(summary)
                    trendCard(summary)
                    recordsCard(summary)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
        }
    }

    // MARK: - Goal

    private var goalMenu: some View {
        Menu {
            ForEach(Self.goalChoices, id: \.self) { choice in
                Button {
                    goalMinutes = choice
                } label: {
                    if choice == goalMinutes {
                        Label(StatsSummary.compact(choice), systemImage: "checkmark")
                    } else {
                        Text(StatsSummary.compact(choice))
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "target").font(Theme.ui(11, .semibold))
                Text("Daily goal \(StatsSummary.compact(goalMinutes))").font(Theme.ui(11, .medium))
            }
        }
        .menuStyle(.button)
        .buttonStyle(SoftPillButtonStyle())
        .fixedSize()
    }

    // MARK: - Today

    private func todayCard(_ summary: StatsSummary) -> some View {
        HStack(alignment: .top, spacing: 26) {
            GoalRing(progress: summary.goalProgress,
                     tint: tint(for: summary.verdict.tone),
                     value: StatsSummary.compact(summary.minutesToday),
                     caption: summary.goalMet
                         ? "goal met"
                         : "of \(StatsSummary.compact(summary.goalMinutes))")

            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text(summary.verdict.headline)
                        .font(Theme.ui(16, .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: icon(for: summary.verdict.tone))
                        .font(Theme.ui(14, .semibold))
                        .foregroundStyle(tint(for: summary.verdict.tone))
                }

                if !summary.verdict.detail.isEmpty {
                    Text(summary.verdict.detail)
                        .font(Theme.ui(12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                WeekStrip(days: Array(summary.recentDays.suffix(7)),
                          tint: Theme.success)
                Text(weekStripCaption(summary))
                    .font(Theme.ui(10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .card()
    }

    private func weekStripCaption(_ summary: StatsSummary) -> String {
        let hits = summary.recentDays.suffix(7).filter(\.metGoal).count
        switch hits {
        case 0: return "No days hit the goal this past week."
        case 7: return "Every one of the last seven days hit the goal."
        default: return "\(hits) of the last 7 days hit the goal."
        }
    }

    // MARK: - Tiles

    private func tileRow(_ summary: StatsSummary) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 172), spacing: 12)], spacing: 12) {
            StatTile(icon: "checkmark.circle.fill", tint: Theme.success, softTint: Theme.successSoft,
                     value: "\(summary.tasksToday)", label: "Tasks done today",
                     delta: taskDelta(summary))
            StatTile(icon: "flame.fill", tint: Theme.amber, softTint: Theme.amberSoft,
                     value: "\(summary.streak)", label: "Day streak",
                     delta: summary.streakAtRisk
                         ? DeltaLabel(text: "at risk tonight", tone: .behind)
                         : DeltaLabel(text: "\(summary.goalDaysThisWeek) goal days this week", tone: .neutral))
            StatTile(icon: "timer", tint: Theme.accent, softTint: Theme.accentSoft,
                     value: "\(summary.sessionsToday)", label: "Sessions today",
                     delta: DeltaLabel(text: "\(summary.finishedSessionsToday) run to the end",
                                       tone: .neutral))
            StatTile(icon: "bolt.fill", tint: Theme.violet, softTint: Theme.accentSoft,
                     value: "\(Int((summary.followThrough * 100).rounded()))%",
                     label: "Sessions finished",
                     delta: DeltaLabel(text: "of the last 14 days' minutes", tone: .neutral))
        }
    }

    private func taskDelta(_ summary: StatsSummary) -> DeltaLabel {
        let difference = summary.tasksToday - summary.tasksYesterday
        if difference == 0 {
            return DeltaLabel(text: "same as yesterday", tone: .neutral)
        }
        let word = abs(difference) == 1 ? "task" : "tasks"
        return DeltaLabel(text: difference > 0
                            ? "+\(difference) \(word) on yesterday"
                            : "\(abs(difference)) \(word) behind yesterday",
                          tone: difference > 0 ? .ahead : .behind)
    }

    // MARK: - Subjects

    @ViewBuilder
    private func subjectCard(_ summary: StatsSummary) -> some View {
        let courses = subjectBars(summary)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Where the time went")
                    .font(Theme.ui(15, .semibold))
                Spacer()
                Picker("", selection: $subjectRange) {
                    ForEach(SubjectRange.allCases) { range in
                        Text(range.label).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Text(subjectCaption(courses))
                .font(Theme.ui(10))
                .foregroundStyle(.secondary)
                .padding(.bottom, 10)

            if courses.isEmpty {
                Text(subjectRange == .today
                        ? "Nothing logged today. Start a focus session from a task and it lands here."
                        : "Nothing logged this week yet.")
                    .font(Theme.ui(12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 18)
            } else {
                Chart(courses) { entry in
                    BarMark(
                        x: .value("Minutes", entry.minutes),
                        y: .value("Subject", entry.course),
                        height: .fixed(18)
                    )
                    // The subject's own colour — the same one its tag chip
                    // wears on the board, so the two pages read as one app.
                    .foregroundStyle(barColor(for: entry.course))
                    .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 4, topTrailingRadius: 4))
                    .annotation(position: .trailing) {
                        Text(StatsSummary.compact(entry.minutes))
                            .font(Theme.ui(10, .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .chartXAxis(.hidden)
                // Headroom on the right so the value at a bar's tip has
                // somewhere to sit instead of running off the plot.
                .chartXScale(domain: 0...Swift.max(1, (courses.map(\.minutes).max() ?? 1) * 1.18))
                .chartYAxis {
                    AxisMarks { _ in
                        AxisValueLabel().foregroundStyle(Color.primary)
                    }
                }
                .frame(height: CGFloat(courses.count) * 34 + 10)
            }
        }
        .card()
    }

    private func subjectBars(_ summary: StatsSummary) -> [CourseMinutes] {
        switch subjectRange {
        case .today:
            return summary.byCourseToday
        case .week:
            let calendar = Calendar.current
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)) ?? .now
            return StatsMath.capped(StatsMath.byCourse(stats.records, from: startOfWeek, to: end))
        }
    }

    private func subjectCaption(_ courses: [CourseMinutes]) -> String {
        let total = courses.reduce(0) { $0 + $1.minutes }
        guard let top = courses.first, total > 0 else {
            return "Sessions started from a task count toward its subject."
        }
        let share = Int((top.minutes / total * 100).rounded())
        return "\(StatsSummary.compact(total)) in total — \(share)% of it on \(top.course)."
    }

    /// "General" and "Other" are not subjects and get the de-emphasis grey;
    /// everything else wears the colour the board gave it.
    private func barColor(for course: String) -> Color {
        guard course != "General", course != "Other" else { return Color.secondary.opacity(0.45) }
        return tasks.color(for: course)
    }

    // MARK: - Trend

    private func trendCard(_ summary: StatsSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Last 14 days")
                .font(Theme.ui(15, .semibold))
            Text(weekComparison(summary))
                .font(Theme.ui(10))
                .foregroundStyle(.secondary)
                .padding(.bottom, 10)

            Chart {
                ForEach(summary.recentDays) { entry in
                    BarMark(
                        x: .value("Day", entry.day, unit: .day),
                        y: .value("Minutes", entry.minutes),
                        width: .ratio(0.6)
                    )
                    // Emphasis, not a palette: today is the story and the rest
                    // is the context it is read against.
                    .foregroundStyle(Calendar.current.isDateInToday(entry.day)
                                        ? tint(for: summary.verdict.tone)
                                        : Color.secondary.opacity(0.3))
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
                    .annotation(position: .top) {
                        // One direct label, on the only bar anyone is looking
                        // for; the axis carries the other thirteen.
                        if Calendar.current.isDateInToday(entry.day), entry.minutes > 0 {
                            Text(StatsSummary.compact(entry.minutes))
                                .font(Theme.ui(10, .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if goalMinutes > 0 {
                    RuleMark(y: .value("Goal", goalMinutes))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                        .annotation(position: .top, alignment: .leading) {
                            Text("goal")
                                .font(Theme.ui(9, .medium))
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow))
                        .foregroundStyle(Color.secondary)
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(Theme.stroke)
                    AxisValueLabel().foregroundStyle(Color.secondary)
                }
            }
            .frame(height: 200)
        }
        .card()
    }

    private func weekComparison(_ summary: StatsSummary) -> String {
        let difference = summary.minutesThisWeekToDate - summary.minutesLastWeekToDate
        let thisWeek = StatsSummary.compact(summary.minutesThisWeekToDate)
        guard summary.minutesLastWeekToDate > 0 else {
            return "\(thisWeek) this week so far."
        }
        if abs(difference) < 5 {
            return "\(thisWeek) this week — level with last week at this point."
        }
        return difference > 0
            ? "\(thisWeek) this week — \(StatsSummary.compact(difference)) ahead of last week at this point."
            : "\(thisWeek) this week — \(StatsSummary.compact(-difference)) behind last week at this point."
    }

    // MARK: - Records

    private func recordsCard(_ summary: StatsSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Records")
                .font(Theme.ui(15, .semibold))
            RecordRow(label: "Best day", value: summary.bestDayMinutes > 0
                        ? "\(StatsSummary.compact(summary.bestDayMinutes)) · \(dayLabel(summary.bestDayDate))"
                        : "—")
            RecordRow(label: "Average day you studied",
                      value: summary.averageActiveDayMinutes > 0
                        ? StatsSummary.compact(summary.averageActiveDayMinutes) : "—")
            RecordRow(label: "Sessions completed", value: "\(stats.completedSessionCount)")
            RecordRow(label: "Total focused", value: String(format: "%.1f h", summary.totalHours))
        }
        .card()
    }

    private func dayLabel(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return formatter.string(from: date)
    }

    // MARK: - Shared

    private func tint(for tone: StatsTone) -> Color {
        switch tone {
        case .ahead: return Theme.success
        case .onTrack: return Theme.accent
        case .behind: return Theme.amber
        case .idle: return Color.secondary
        }
    }

    private func icon(for tone: StatsTone) -> String {
        switch tone {
        case .ahead: return "checkmark.seal.fill"
        case .onTrack: return "arrow.up.right"
        case .behind: return "exclamationmark.triangle.fill"
        case .idle: return "moon.zzz.fill"
        }
    }

    private var yesterday: Date {
        Calendar.current.date(byAdding: .day, value: -1, to: .now) ?? .now
    }

    private var startOfWeek: Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let weekday = calendar.component(.weekday, from: today)
        let daysBack = (weekday - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -daysBack, to: today) ?? today
    }
}

// MARK: - Pieces

/// The day's progress as a ring, with the number it is a ring *of* inside it.
///
/// The track is the same hue as the fill at low opacity rather than grey, so
/// an empty ring still reads as "this much of that" instead of as a disabled
/// control.
private struct GoalRing: View {
    let progress: Double
    let tint: Color
    let value: String
    let caption: String

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.15), lineWidth: 14)
            Circle()
                .trim(from: 0, to: max(0.001, progress))
                .stroke(tint, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.45), value: progress)
            VStack(spacing: 2) {
                Text(value)
                    // Scales itself down rather than wrapping: "2h" gets the
                    // full display size, "1h 45m" quietly takes less.
                    .font(Theme.number(44))
                    .minimumScaleFactor(0.55)
                    .lineLimit(1)
                Text(caption)
                    .font(Theme.ui(10, .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 22)
        }
        .frame(width: 148, height: 148)
    }
}

/// Seven days as dots: filled for a day that hit the goal, hollow-centred for
/// a day with some work on it, empty for a day with none.
///
/// The fill is a second channel on top of colour — three states that are told
/// apart by shape alone, which is what keeps the strip readable for anyone
/// who can't separate the green from the grey.
private struct WeekStrip: View {
    let days: [DayTotal]
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            ForEach(days) { day in
                VStack(spacing: 5) {
                    ZStack {
                        Circle()
                            .fill(day.metGoal ? tint : Color.clear)
                            .frame(width: 14, height: 14)
                        Circle()
                            .strokeBorder(day.minutes > 0 ? tint : Theme.stroke, lineWidth: 1.5)
                            .frame(width: 14, height: 14)
                        if day.minutes > 0 && !day.metGoal {
                            Circle().fill(tint).frame(width: 5, height: 5)
                        }
                    }
                    Text(Self.initial(for: day.day))
                        .font(Theme.ui(9, .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private static func initial(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEEE"
        return formatter.string(from: date)
    }
}

/// The small line under a tile's number: what it was yesterday, or what it is
/// made of. `.neutral` is the common case and stays grey — a coloured delta on
/// every tile would make the page shout at you about nothing.
struct DeltaLabel {
    enum Tone { case ahead, behind, neutral }
    let text: String
    let tone: Tone

    var color: Color {
        switch tone {
        case .ahead: return Theme.success
        case .behind: return Theme.amber
        case .neutral: return .secondary
        }
    }
}

private struct StatTile: View {
    let icon: String
    let tint: Color
    let softTint: Color
    let value: String
    let label: String
    var delta: DeltaLabel?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(softTint)
                        .frame(width: 30, height: 30)
                    Image(systemName: icon)
                        .font(Theme.ui(13, .semibold))
                        .foregroundStyle(tint)
                }
                Text(label)
                    .font(Theme.ui(10, .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(Theme.number(26))
                    .monospacedDigit()
                if let delta {
                    Text(delta.text)
                        .font(Theme.ui(10))
                        .foregroundStyle(delta.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14)
    }
}

private struct RecordRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(Theme.ui(12))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(Theme.ui(12, .medium))
                .monospacedDigit()
        }
    }
}
