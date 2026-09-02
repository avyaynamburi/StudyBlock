import SwiftUI

/// Where the Canvas feed URL is pasted, and where a sync can be run by hand.
struct CanvasSheet: View {
    @ObservedObject var canvas: CanvasSync
    let canvasTaskCount: Int
    let onSync: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var saveFailed = false
    @State private var confirmingForget = false

    init(canvas: CanvasSync, canvasTaskCount: Int, onSync: @escaping () -> Void) {
        self.canvas = canvas
        self.canvasTaskCount = canvasTaskCount
        self.onSync = onSync
        _draft = State(initialValue: canvas.feedURL)
    }

    private var isDirty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines) != canvas.feedURL
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "graduationcap.fill")
                    .font(Theme.ui(14, .semibold))
                    .foregroundStyle(Theme.accent)
                Text("Canvas")
                    .font(Theme.ui(16, .semibold))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("In Canvas, open **Calendar** and click **Calendar Feed** at the "
                         + "bottom of the right-hand sidebar. Copy the link it shows you and "
                         + "paste it below \u{2014} assignments with due dates will appear on "
                         + "your board in the \u{201C}\(TaskStore.canvasCategory)\u{201D} category.")
                        .font(Theme.ui(12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Feed URL").font(Theme.ui(10)).foregroundStyle(.secondary)
                            TextField("https://canvas.\u{2026}/feeds/calendars/user_\u{2026}.ics",
                                      text: $draft, axis: .vertical)
                                .textFieldStyle(.plain)
                                .font(Theme.mono(11))
                                .lineLimit(2...4)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)

                        Divider().overlay(Theme.stroke)
                        HStack {
                            Toggle(isOn: $canvas.importsEvents) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Also import course events").font(Theme.ui(12))
                                    Text("Reading days, exam rooms \u{2014} things that start "
                                         + "rather than come due.")
                                        .font(Theme.ui(10))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(CheckToggleStyle())
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Theme.stroke, lineWidth: 1))

                    Label("This link is a password. Anyone who has it can read your Canvas "
                          + "calendar, so it\u{2019}s kept in your login keychain and never "
                          + "written to a log or a file.", systemImage: "lock.fill")
                        .font(Theme.ui(10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    statusBlock
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
            }

            HStack {
                if canvas.isConfigured {
                    Button(role: .destructive) {
                        confirmingForget = true
                    } label: {
                        Label("Forget", systemImage: "trash")
                    }
                    .buttonStyle(SoftPillButtonStyle(tint: Theme.danger))
                    .help("Removes the saved URL. Assignments already on your board stay.")
                    .confirmationDialog("Forget the Canvas feed?", isPresented: $confirmingForget) {
                        Button("Forget URL", role: .destructive) {
                            canvas.forget()
                            draft = ""
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("The \(canvasTaskCount) assignment\(canvasTaskCount == 1 ? "" : "s") "
                             + "already imported stay on your board \u{2014} they just stop updating.")
                    }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(SoftPillButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(isDirty ? "Save & Sync" : "Sync Now") {
                    if isDirty {
                        canvas.feedURL = draft
                        saveFailed = !canvas.saveURL()
                        draft = canvas.feedURL
                        guard !saveFailed else { return }
                    }
                    onSync()
                }
                .buttonStyle(ProminentPillButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(canvas.isSyncing
                          || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(20)
        }
        .frame(width: 460, height: 520)
        .background(Theme.bg)
    }

    @ViewBuilder
    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            if canvas.isSyncing {
                Label("Syncing\u{2026}", systemImage: "arrow.triangle.2.circlepath")
                    .font(Theme.ui(11, .medium))
                    .foregroundStyle(Theme.accent)
            } else if saveFailed {
                Label("Couldn\u{2019}t save to the keychain. Try again, or check Keychain Access.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.ui(11, .medium))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let error = canvas.lastError {
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.ui(11, .medium))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let summary = canvas.lastSummary {
                Label(summary.headline, systemImage: "checkmark.circle.fill")
                    .font(Theme.ui(11, .medium))
                    .foregroundStyle(Theme.success)
                if !summary.detail.isEmpty {
                    Text(summary.detail)
                        .font(Theme.ui(10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text(canvas.lastSyncedLabel + (canvasTaskCount > 0
                 ? " \u{00B7} \(canvasTaskCount) assignment\(canvasTaskCount == 1 ? "" : "s") on the board"
                 : ""))
                .font(Theme.ui(10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
