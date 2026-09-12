import SwiftUI

/// Asked the moment a task-linked session ends: is it done?
///
/// The two answers are deliberately the same size. "Not yet" is not a
/// failure — a 50-minute session on a week-long essay ends with the essay
/// unfinished every time — so nothing here nudges toward ticking the box,
/// and the only celebration is for a task that really is finished.
struct SessionFinishSheet: View {
    let prompt: FinishedSessionPrompt
    /// True when the task is done and should be celebrated.
    let onAnswer: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                ZStack {
                    Circle().fill(Theme.successSoft).frame(width: 52, height: 52)
                    Image(systemName: "flag.checkered")
                        .font(Theme.ui(20, .semibold))
                        .foregroundStyle(Theme.success)
                }
                Text("\(prompt.minutes) minute\(prompt.minutes == 1 ? "" : "s") banked")
                    .font(Theme.ui(17, .semibold))
                Text("Did you finish \u{201C}\(prompt.taskTitle)\u{201D}?")
                    .font(Theme.ui(12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 22)

            HStack(spacing: 10) {
                Button {
                    onAnswer(false)
                    dismiss()
                } label: {
                    Text("Still working on it")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SoftPillButtonStyle())
                .keyboardShortcut(.cancelAction)
                .help("Puts it back in the column the session took it from")

                Button {
                    onAnswer(true)
                    dismiss()
                } label: {
                    Label("Mark it Done", systemImage: "checkmark")
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
