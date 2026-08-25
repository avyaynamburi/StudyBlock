import SwiftUI

struct NotesView: View {
    @EnvironmentObject private var store: NotesStore
    @State private var selectedID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("Notes", subtitle: "Quick scratchpads — everything autosaves") {
                Button {
                    selectedID = store.addNote().id
                } label: {
                    Label("New Note", systemImage: "square.and.pencil")
                }
                .buttonStyle(ProminentPillButtonStyle())
            }

            HStack(alignment: .top, spacing: 16) {
                noteRail
                    .frame(width: 240)
                editor
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
        .onDisappear { store.saveNow() }
    }

    private var noteRail: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(store.sortedNotes) { note in
                    NoteRailItem(note: note, isSelected: selectedID == note.id) {
                        selectedID = note.id
                    }
                    .contextMenu {
                        Button("Delete Note", role: .destructive) {
                            if selectedID == note.id { selectedID = nil }
                            store.delete(note)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let id = selectedID, let index = store.notes.firstIndex(where: { $0.id == id }) {
            VStack(spacing: 0) {
                TextField("Title", text: Binding(
                    get: { store.notes[index].title },
                    set: { store.notes[index].title = $0; store.touch(id) }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 6)

                Divider().overlay(Theme.stroke).padding(.horizontal, 20)

                TextEditor(text: Binding(
                    get: { store.notes[index].body },
                    set: { store.notes[index].body = $0; store.touch(id) }
                ))
                .font(.system(size: 13.5))
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 15)
                .padding(.vertical, 8)
            }
            .card(padding: 0)
        } else {
            EmptyState(icon: "note.text",
                       title: store.notes.isEmpty ? "Create a note to get started" : "Select a note",
                       message: store.notes.isEmpty ? "Perfect for lecture snippets, todo dumps, or anything mid-study." : nil)
                .card(padding: 0)
        }
    }
}

private struct NoteRailItem: View {
    let note: Note
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(note.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(note.updatedAt, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
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
