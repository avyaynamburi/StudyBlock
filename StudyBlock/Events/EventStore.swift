import Foundation

/// The exams on the Events page, kept in `events.json`.
@MainActor
final class EventStore: ObservableObject {
    @Published private(set) var events: [StudyEvent] = [] {
        didSet { JSONStore.save(events, to: "events.json") }
    }

    init() {
        events = JSONStore.load([StudyEvent].self, from: "events.json") ?? []
    }

    /// Adds an exam. Returns false, and adds nothing, when the title is blank.
    @discardableResult
    func add(_ event: StudyEvent) -> Bool {
        var event = event
        event.title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !event.title.isEmpty else { return false }
        events.append(event)
        return true
    }

    func update(_ event: StudyEvent) {
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let index = events.firstIndex(where: { $0.id == event.id }) else { return }
        var updated = event
        updated.title = title
        events[index] = updated
    }

    func delete(_ id: UUID) {
        events.removeAll { $0.id == id }
    }

    var courses: [String] {
        Array(Set(events.compactMap(\.course))).sorted()
    }
}
