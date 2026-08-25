import SwiftUI

enum ReviewMode {
    /// Due cards only; grades update the SM-2 schedule.
    case study
    /// All cards, shuffled; missed cards re-queued once; schedule untouched.
    case practice
}

struct ReviewSession: Identifiable {
    let deck: Deck
    let mode: ReviewMode
    var id: UUID { deck.id }
}

struct ReviewView: View {
    let deck: Deck
    let mode: ReviewMode
    @EnvironmentObject private var store: DeckStore
    @Environment(\.dismiss) private var dismiss

    @State private var queue: [Flashcard] = []
    @State private var missed: [Flashcard] = []
    @State private var index = 0
    @State private var showBack = false
    @State private var gotItCount = 0
    @State private var againCount = 0
    @State private var firstPassCount = 0
    @State private var onRetryPass = false

    var body: some View {
        VStack(spacing: 16) {
            header

            if index < queue.count {
                progressBar
                cardView(queue[index])
            } else {
                summaryView
            }
        }
        .padding(22)
        .frame(width: 540, height: 460)
        .background(Theme.bg)
        .onAppear {
            switch mode {
            case .study: queue = deck.cards.filter { $0.isDue() }.shuffled()
            case .practice: queue = deck.cards.shuffled()
            }
            firstPassCount = queue.count
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(deck.name)
                .font(.system(size: 16, weight: .bold, design: .rounded))
            TagChip(text: mode == .study ? "Study" : (onRetryPass ? "Retrying missed" : "Practice"),
                    color: mode == .study ? Theme.accent : Theme.violet)
            Spacer()
            if index < queue.count {
                Text("\(queue.count - index) left")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(IconButtonStyle())
            .keyboardShortcut(.cancelAction)
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surfaceLow)
                Capsule()
                    .fill(Theme.accentGradient)
                    .frame(width: geo.size.width * progressFraction)
                    .animation(.easeOut(duration: 0.25), value: progressFraction)
            }
        }
        .frame(height: 5)
    }

    private var progressFraction: CGFloat {
        guard !queue.isEmpty else { return 0 }
        return CGFloat(index) / CGFloat(queue.count)
    }

    private func cardView(_ card: Flashcard) -> some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.surface)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(showBack ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.stroke),
                                      lineWidth: showBack ? 1.5 : 1))
                    .shadow(color: .black.opacity(0.12), radius: 18, y: 8)

                VStack(spacing: 10) {
                    Text(showBack ? "ANSWER" : "QUESTION")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .kerning(1.2)
                        .foregroundStyle(showBack ? Theme.violet : Theme.accent)
                    Text(showBack ? card.back : card.front)
                        .font(.system(size: 19, weight: .medium))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                    Spacer(minLength: 0)
                    if !showBack {
                        Text("Click or press space to flip")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(22)
                .rotation3DEffect(.degrees(showBack ? -180 : 0), axis: (x: 0, y: 1, z: 0))
            }
            .rotation3DEffect(.degrees(showBack ? 180 : 0), axis: (x: 0, y: 1, z: 0))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .onTapGesture { flip() }
            .frame(maxHeight: .infinity)

            if showBack {
                switch mode {
                case .study: gradeButtons(card)
                case .practice: practiceButtons(card)
                }
            } else {
                Button("Show Answer") { flip() }
                    .buttonStyle(ProminentPillButtonStyle(size: .large))
                    .keyboardShortcut(.space, modifiers: [])
            }
        }
    }

    private func flip() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
            showBack.toggle()
        }
    }

    private func gradeButtons(_ card: Flashcard) -> some View {
        HStack(spacing: 8) {
            ForEach(SRSGrade.allCases, id: \.rawValue) { grade in
                GradeButton(
                    label: grade.label,
                    sublabel: grade == .again ? "now" : SRS.previewLabel(for: card, grade: grade),
                    color: gradeColor(grade),
                    prominent: grade == .good
                ) {
                    self.grade(card, as: grade)
                }
                .keyboardShortcut(grade == .good ? .defaultAction : nil)
            }
        }
    }

    private func gradeColor(_ grade: SRSGrade) -> Color {
        switch grade {
        case .again: return Theme.danger
        case .hard: return Theme.amber
        case .good: return Theme.accent
        case .easy: return Theme.success
        }
    }

    private func practiceButtons(_ card: Flashcard) -> some View {
        HStack(spacing: 10) {
            GradeButton(label: "Missed It", sublabel: nil, color: Theme.danger, prominent: false) {
                missed.append(card)
                advance()
            }
            GradeButton(label: "Got It", sublabel: nil, color: Theme.success, prominent: true) {
                if !onRetryPass { gotItCount += 1 }
                advance()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private var summaryView: some View {
        VStack(spacing: 14) {
            let starred = mode == .study ? againCount == 0 : gotItCount == firstPassCount
            ZStack {
                Circle()
                    .fill(starred ? Theme.amberSoft : Theme.successSoft)
                    .frame(width: 74, height: 74)
                Image(systemName: starred ? "star.fill" : "checkmark.seal.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(starred ? Theme.amber : Theme.success)
            }

            switch mode {
            case .study:
                Text(firstPassCount == 0
                     ? "Nothing due — come back later"
                     : "Reviewed \(firstPassCount) card\(firstPassCount == 1 ? "" : "s")"
                       + (againCount > 0 ? " (\(againCount) needed a retry)" : ""))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Button("Done") { dismiss() }
                    .buttonStyle(ProminentPillButtonStyle(size: .large))
            case .practice:
                Text("\(gotItCount) of \(firstPassCount) on the first pass")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                HStack(spacing: 10) {
                    Button("Practice Again") {
                        queue = deck.cards.shuffled()
                        missed = []
                        index = 0
                        gotItCount = 0
                        onRetryPass = false
                        showBack = false
                    }
                    .buttonStyle(SoftPillButtonStyle())
                    Button("Done") { dismiss() }
                        .buttonStyle(ProminentPillButtonStyle(size: .large))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func grade(_ card: Flashcard, as grade: SRSGrade) {
        let updated = SRS.review(card, grade: grade)
        store.updateCard(updated, inDeck: deck.id)
        if grade == .again {
            againCount += 1
            queue.append(updated)
        }
        advance()
    }

    private func advance() {
        showBack = false
        index += 1
        if mode == .practice, index >= queue.count, !missed.isEmpty, !onRetryPass {
            queue = missed.shuffled()
            missed = []
            index = 0
            onRetryPass = true
        }
    }
}

private struct GradeButton: View {
    let label: String
    let sublabel: String?
    let color: Color
    let prominent: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(label)
                    .font(.callout.weight(.semibold))
                if let sublabel {
                    Text(sublabel)
                        .font(.caption2)
                        .opacity(0.75)
                }
            }
            .foregroundStyle(prominent ? .white : color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(prominent ? AnyShapeStyle(color) : AnyShapeStyle(color.opacity(hovering ? 0.22 : 0.13)))
            )
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(color.opacity(prominent ? 0 : 0.25), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }
}
