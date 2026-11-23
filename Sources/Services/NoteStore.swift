import Foundation
import Combine

/// A note or idea said out loud ("Note: buy a new lamp", "I have an idea: a plant shelf"). Stored on the iPhone.
struct Note: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var text: String
    var isIdea: Bool
    var created: Date = Date()
    var pinned: Bool = false
}

final class NoteStore: ObservableObject {
    @Published private(set) var notes: [Note] { didSet { save() } }

    private static let key = "notes.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Note].self, from: data) {
            notes = saved
        } else {
            notes = []
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(notes) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    /// Pinned first, then newest first.
    var sorted: [Note] {
        notes.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.created > b.created
        }
    }

    @discardableResult
    func add(_ text: String, idea: Bool) -> Note {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = Note(text: clean.prefix(1).uppercased() + clean.dropFirst(), isIdea: idea)
        notes.append(note)
        return note
    }

    func update(_ note: Note) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[index] = note
    }

    func delete(_ id: UUID) { notes.removeAll { $0.id == id } }
    func restore(_ note: Note) { if !notes.contains(where: { $0.id == note.id }) { notes.append(note) } }

    /// Best match for "the note about the lamp".
    func find(_ phrase: String) -> Note? {
        let target = CommandStore.normalize(phrase)
        guard !target.isEmpty else { return nil }
        if let contains = sorted.first(where: { CommandStore.normalize($0.text).contains(target) }) { return contains }
        let words = Set(target.split(separator: " ").map(String.init).filter { $0.count > 2 })
        let best = sorted
            .map { note -> (Note, Int) in
                (note, Set(CommandStore.normalize(note.text).split(separator: " ").map(String.init)).intersection(words).count)
            }
            .max { $0.1 < $1.1 }
        if let best = best, best.1 > 0 { return best.0 }
        return nil
    }
}
