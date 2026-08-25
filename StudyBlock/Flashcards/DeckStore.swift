import Foundation

struct Flashcard: Identifiable, Codable, Equatable {
    var id = UUID()
    var front = ""
    var back = ""

    // SM-2 spaced-repetition state. New cards (dueDate nil) are always due.
    var easeFactor = 2.5
    var repetition = 0
    var intervalDays = 0.0
    var dueDate: Date?

    func isDue(now: Date = Date()) -> Bool {
        (dueDate ?? .distantPast) <= now
    }

    // Decode with defaults so decks saved before the SRS fields existed
    // still load.
    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        front = try container.decode(String.self, forKey: .front)
        back = try container.decode(String.self, forKey: .back)
        easeFactor = try container.decodeIfPresent(Double.self, forKey: .easeFactor) ?? 2.5
        repetition = try container.decodeIfPresent(Int.self, forKey: .repetition) ?? 0
        intervalDays = try container.decodeIfPresent(Double.self, forKey: .intervalDays) ?? 0
        dueDate = try container.decodeIfPresent(Date.self, forKey: .dueDate)
    }
}

struct Deck: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var cards: [Flashcard] = []

    func dueCount(now: Date = Date()) -> Int {
        cards.filter { $0.isDue(now: now) }.count
    }
}

@MainActor
final class DeckStore: ObservableObject {
    @Published var decks: [Deck] = [] {
        didSet { JSONStore.save(decks, to: "decks.json") }
    }

    init() {
        decks = JSONStore.load([Deck].self, from: "decks.json") ?? []
    }

    func addDeck(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        decks.append(Deck(name: trimmed))
    }

    func deleteDeck(_ deck: Deck) {
        decks.removeAll { $0.id == deck.id }
    }

    func binding(for deckID: UUID) -> Deck? {
        decks.first { $0.id == deckID }
    }

    func update(_ deck: Deck) {
        guard let index = decks.firstIndex(where: { $0.id == deck.id }) else { return }
        decks[index] = deck
    }

    func updateCard(_ card: Flashcard, inDeck deckID: UUID) {
        guard let deckIndex = decks.firstIndex(where: { $0.id == deckID }),
              let cardIndex = decks[deckIndex].cards.firstIndex(where: { $0.id == card.id }) else { return }
        decks[deckIndex].cards[cardIndex] = card
    }
}
