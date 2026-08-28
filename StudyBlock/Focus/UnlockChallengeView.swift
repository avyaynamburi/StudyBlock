import AppKit
import SwiftUI

/// A random string the user must hand-type to end a locked session early.
/// The friction is the point — this isn't a security boundary (the app
/// already trusts the local user), just a deliberate speed bump against an
/// impulsive "just this once."
enum UnlockChallenge {
    /// Excludes look-alike characters (0/O, 1/l/I) so a mismatch means a
    /// mistyped key, not a misread one.
    private static let characters = Array("abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789")

    static func generate(length: Int = 100) -> String {
        String((0..<length).map { _ in characters.randomElement()! })
    }
}

/// Single-line-ish text view that refuses pasted or drag-dropped text.
/// SwiftUI's `TextField` has no hook for this, so this drops to AppKit:
/// `readSelection(from:type:)` is the one choke point `NSTextView` routes
/// both paste *and* drag-and-drop text insertion through, and the explicit
/// `paste…` overrides cover Edit-menu / Cmd-V invocation too.
final class NoPasteTextView: NSTextView {
    override func paste(_ sender: Any?) {}
    override func pasteAsPlainText(_ sender: Any?) {}
    override func pasteAsRichText(_ sender: Any?) {}
    override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        false
    }
}

struct NoPasteTextField: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NoPasteTextView()
        textView.delegate = context.coordinator
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.textContainer?.lineBreakMode = .byCharWrapping

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        DispatchQueue.main.async {
            scrollView.window?.makeFirstResponder(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }
    }
}

/// Presented when the user wants out of a locked session before its
/// deadline. Ending the lock only happens once `typed` exactly matches a
/// freshly generated 100-character passage — typed by hand, since paste is
/// disabled in the field below.
struct UnlockChallengeSheet: View {
    @EnvironmentObject private var timer: FocusTimerController
    @EnvironmentObject private var model: BlockerViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var challenge = UnlockChallenge.generate()
    @State private var typed = ""
    @State private var isUnlocking = false

    private var isMatch: Bool { typed == challenge }
    private var hasMismatch: Bool { !typed.isEmpty && !challenge.hasPrefix(typed) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Unlock Early", systemImage: "lock.open.fill")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Text("Type the passage below exactly, start to finish, to end the lock now. Pasting is disabled on purpose — this is meant to slow you down, not speed you up.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text(challenge)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surfaceLow, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))

            NoPasteTextField(text: $typed)
                .frame(height: 74)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(hasMismatch ? Theme.danger : (isMatch ? Theme.success : Theme.stroke),
                                  lineWidth: hasMismatch || isMatch ? 1.5 : 1))

            if hasMismatch {
                Label("Doesn't match — check for typos.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
            } else if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
            } else {
                Text("\(typed.count) / \(challenge.count) characters")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Button("Never Mind") { dismiss() }
                    .buttonStyle(SoftPillButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    isUnlocking = true
                    Task {
                        await timer.forceUnlock()
                        isUnlocking = false
                        if !timer.isLockedSession { dismiss() }
                    }
                } label: {
                    if isUnlocking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Unlock")
                    }
                }
                .buttonStyle(ProminentPillButtonStyle())
                .disabled(!isMatch || isUnlocking)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(Theme.bg)
    }
}
