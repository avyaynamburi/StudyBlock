import Charts
import SwiftUI

struct StatsView: View {
    @EnvironmentObject private var stats: StatsStore
    @EnvironmentObject private var tasks: TaskStore

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("Stats", subtitle: "Your studying, in numbers")

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statTiles
                    weekChart
                    courseChart
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
        }
    }

    private var statTiles: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                StatTile(icon: "timer", tint: Theme.accent, softTint: Theme.accentSoft,
                         value: minutesLabel(stats.minutesToday), label: "Focused today")
                StatTile(icon: "flame.fill", tint: Theme.amber, softTint: Theme.amberSoft,
                         value: "\(stats.currentStreak)", label: "Day streak")
            }
            GridRow {
                StatTile(icon: "checkmark.circle.fill", tint: Theme.success, softTint: Theme.successSoft,
                         value: "\(tasks.completedCount(since: startOfWeek))", label: "Tasks done this week")
                StatTile(icon: "target", tint: Theme.violet, softTint: Theme.accentSoft,
                         value: "\(stats.completedSessionCount)", label: "Sessions completed")
            }
        }
    }

    private var weekChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Focused minutes — last 7 days")
                .font(.system(size: 15, weight: .semibold))
            Chart(stats.dailyMinutes(days: 7), id: \.day) { entry in
                BarMark(
                    x: .value("Day", entry.day, unit: .day),
                    y: .value("Minutes", entry.minutes),
                    width: .ratio(0.55)
                )
                .foregroundStyle(Theme.accent)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
                .annotation(position: .top) {
                    // Selective direct label: today only; the axis carries the rest.
                    if Calendar.current.isDateInToday(entry.day), entry.minutes > 0 {
                        Text(minutesLabel(entry.minutes))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                        .foregroundStyle(Color.secondary)
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(Theme.stroke)
                    AxisValueLabel().foregroundStyle(Color.secondary)
                }
            }
            .frame(height: 190)
        }
        .card()
    }

    @ViewBuilder
    private var courseChart: some View {
        let byCourse = stats.minutesByCourse(since: startOfWeek)
        if !byCourse.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Focus by course — this week")
                    .font(.system(size: 15, weight: .semibold))
                Text("Sessions started from a task count toward its course.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
                Chart(byCourse.prefix(6), id: \.course) { entry in
                    BarMark(
                        x: .value("Minutes", entry.minutes),
                        y: .value("Course", entry.course),
                        height: .ratio(0.55)
                    )
                    .foregroundStyle(Theme.accent)
                    .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 4, topTrailingRadius: 4))
                    .annotation(position: .trailing) {
                        Text(minutesLabel(entry.minutes))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks { _ in
                        AxisValueLabel().foregroundStyle(Color.primary)
                    }
                }
                .frame(height: CGFloat(min(byCourse.count, 6)) * 36 + 8)
            }
            .card()
        }
    }

    private var startOfWeek: Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let weekday = calendar.component(.weekday, from: today)
        let daysBack = (weekday - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -daysBack, to: today) ?? today
    }

    private func minutesLabel(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        if total >= 60 { return "\(total / 60)h \(total % 60)m" }
        return "\(total)m"
    }
}

private struct StatTile: View {
    let icon: String
    let tint: Color
    let softTint: Color
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(softTint)
                    .frame(width: 42, height: 42)
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(Theme.number(26))
                    .monospacedDigit()
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .card(padding: 16)
    }
}
