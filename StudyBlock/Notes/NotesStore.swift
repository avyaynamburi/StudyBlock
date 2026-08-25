import Foundation

struct Note: Identifiable, Codable, Equatable {
    var id = UUID()
    var title = ""
    var body = ""
    var updatedAt = Date()

    var displayTitle: String {
        if !title.isEmpty { return title }
        let firstLine = body.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        return firstLine.isEmpty ? "New Note" : firstLine
    }
}

@MainActor
final class NotesStore: ObservableObject {
    @Published var notes: [Note] = [] {
        didSet { scheduleSave() }
    }

    private var saveTask: Task<Void, Never>?

    init() {
        notes = JSONStore.load([Note].self, from: "notes.json") ?? []
    }

    @discardableResult
    func addNote() -> Note {
        let note = Note()
        notes.insert(note, at: 0)
        return note
    }

    func delete(_ note: Note) {
        notes.removeAll { $0.id == note.id }
    }

    func touch(_ id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].updatedAt = Date()
    }

    var sortedNotes: [Note] {
        notes.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Typing in the editor fires on every keystroke; debounce disk writes.
    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = notes
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            JSONStore.save(snapshot, to: "notes.json")
        }
    }

    func saveNow() {
        saveTask?.cancel()
        JSONStore.save(notes, to: "notes.json")
    }
}
