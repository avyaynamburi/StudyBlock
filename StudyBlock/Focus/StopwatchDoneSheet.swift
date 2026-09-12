import SwiftUI

/// The question, as something a sheet can be presented from.
struct StopwatchDonePrompt: Identifiable, Equatable {
    let id = UUID()
    var taskTitle: String
}

/// Asked when the task a stopwatch is timing gets ticked off while the
/// stopwatch is still running.
///
/// A stopwatch has no deadline to end itself at, so without this it keeps
/// counting after the work is over and quietly credits the walk to the
/// kitchen as studying. Stopping is offered first for that reason — but it is
/// only offered, because finishing one task and carrying straight on with the
/// next is a perfectly normal thing to do.
struct StopwatchDoneSheet: View {
    let taskTitle: String
    let elapsedLabel: String
    /// True to stop the stopwatch and bank the time.
    let onAnswer: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                ZStack {
                    Circle().fill(Theme.successSoft).frame(width: 52, height: 52)
                    Image(systemName: "stopwatch")
                        .font(Theme.ui(20, .semibold))
                        .foregroundStyle(Theme.success)
                }
                Text("\u{201C}\(taskTitle)\u{201D} is done")
                    .font(Theme.ui(17, .semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The stopwatch is still running at \(elapsedLabel). Stop it and bank the time?")
                    .font(Theme.ui(12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 22)

            HStack(spacing: 10) {
                Button {
                    dismiss()
                    onAnswer(false)
                } label: {
                    Text("Keep Running")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SoftPillButtonStyle())
                .keyboardShortcut(.cancelAction)
                .help("Leaves the stopwatch and the block exactly as they are")

                Button {
                    dismiss()
                    onAnswer(true)
                } label: {
                    Label("Stop Stopwatch", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(ProminentPillButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
            .padding(.bottom, 20)
            .padding(.horizontal, 22)
        }
        .frame(width: 400)
        .background(Theme.surface)
    }
}
