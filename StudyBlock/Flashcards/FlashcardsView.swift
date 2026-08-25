import SwiftUI

struct FlashcardsView: View {
    @EnvironmentObject private var store: DeckStore
    @State private var selectedDeckID: UUID?
    @State private var newDeckName = ""
    @State private var reviewSession: ReviewSession?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("Flashcards", subtitle: dueSummary)

            HStack(alignment: .top, spacing: 16) {
                deckRail
                    .frame(width: 240)
                deckDetail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
        .sheet(item: $reviewSession) { session in
            ReviewView(deck: session.deck, mode: session.mode)
        }
    }

    private var dueSummary: String {
        let due = store.decks.reduce(0) { $0 + $1.dueCount() }
        if store.decks.isEmpty { return "Spaced repetition, the easy way" }
        return due == 0 ? "Nothing due — nice" : "\(due) card\(due == 1 ? "" : "s") due for review"
    }

    // MARK: - Deck rail

    private var deckRail: some View {
        VStack(spacing: 10) {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(store.decks) { deck in
                        DeckRailItem(deck: deck, isSelected: selectedDeckID == deck.id) {
                            selectedDeckID = deck.id
                        }
                        .contextMenu {
                            Button("Delete Deck", role: .destructive) { store.deleteDeck(deck) }
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("New deck", text: $newDeckName)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .onSubmit(addDeck)
                Button(action: addDeck) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(IconButtonStyle(tint: Theme.accent))
                .disabled(newDeckName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
        }
    }

    @ViewBuilder
    private var deckDetail: some View {
        if let deckID = selectedDeckID, let deck = store.decks.first(where: { $0.id == deckID }) {
            DeckEditor(deck: deck) { reviewSession = $0 }
        } else {
            EmptyState(icon: "rectangle.on.rectangle.angled",
                       title: store.decks.isEmpty ? "Create a deck to get started" : "Select a deck",
                       message: store.decks.isEmpty ? "Decks keep cards for one course or topic together." : nil)
                .card(padding: 0)
        }
    }

    private func addDeck() {
        guard !newDeckName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        store.addDeck(named: newDeckName)
        newDeckName = ""
        selectedDeckID = store.decks.last?.id
    }
}

private struct DeckRailItem: View {
    let deck: Deck
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surfaceLow))
                        .frame(width: 28, height: 28)
                    Image(systemName: "rectangle.on.rectangle.angled")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isSelected ? .white : .secondary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(deck.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("\(deck.cards.count) card\(deck.cards.count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if deck.dueCount() > 0 {
                    Text("\(deck.dueCount())")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.accentSoft, in: Capsule())
                }
            }
            .padding(9)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isSelected ? Theme.surface : (hovering ? Theme.surfaceLow.opacity(0.7) : .clear))
            )
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(isSelected ? Theme.stroke : .clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }
}

struct DeckEditor: View {
    let deck: Deck
    let onReview: (ReviewSession) -> Void
    @EnvironmentObject private var store: DeckStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(deck.name)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                Spacer()
                Button("Practice All") {
                    onReview(ReviewSession(deck: deck, mode: .practice))
                }
                .buttonStyle(SoftPillButtonStyle())
                .disabled(deck.cards.isEmpty)
                Button {
                    onReview(ReviewSession(deck: deck, mode: .study))
                } label: {
                    Label("Study \(deck.dueCount()) due", systemImage: "play.fill")
                }
                .buttonStyle(ProminentPillButtonStyle())
                .disabled(deck.dueCount() == 0)
            }
            .padding(16)

            Divider().overlay(Theme.stroke)

            if deck.cards.isEmpty {
                EmptyState(icon: "plus.rectangle.on.rectangle",
                           title: "No cards yet",
                           message: "Add a question and answer below.")
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(deck.cards) { card in
                            CardRow(deck: deck, card: card)
                        }
                    }
                    .padding(16)
                }
            }

            Divider().overlay(Theme.stroke)

            Button {
                var updated = deck
                updated.cards.append(Flashcard())
                store.update(updated)
            } label: {
                Label("Add Card", systemImage: "plus")
            }
            .buttonStyle(SoftPillButtonStyle(tint: Theme.accent))
            .padding(12)
        }
        .card(padding: 0)
    }
}

private struct CardRow: View {
    let deck: Deck
    let card: Flashcard
    @EnvironmentObject private var store: DeckStore

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Q")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.accent)
                TextField("Question", text: field(\.front), axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...3)
            }
            .frame(maxWidth: .infinity)

            Rectangle().fill(Theme.stroke).frame(width: 1).padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text("A")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.violet)
                TextField("Answer", text: field(\.back), axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...3)
            }
            .frame(maxWidth: .infinity)

            Button {
                var updated = deck
                updated.cards.removeAll { $0.id == card.id }
                store.update(updated)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(IconButtonStyle())
            .opacity(hovering ? 1 : 0)
            .help("Delete card")
        }
        .padding(12)
        .background(Theme.surfaceLow.opacity(0.6), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }

    private func field(_ keyPath: WritableKeyPath<Flashcard, String>) -> Binding<String> {
        Binding(
            get: {
                store.decks.first { $0.id == deck.id }?
                    .cards.first { $0.id == card.id }?[keyPath: keyPath] ?? ""
            },
            set: { newValue in
                var updated = store.decks.first { $0.id == deck.id } ?? deck
                guard let index = updated.cards.firstIndex(where: { $0.id == card.id }) else { return }
                updated.cards[index][keyPath: keyPath] = newValue
                store.update(updated)
            }
        )
    }
}
