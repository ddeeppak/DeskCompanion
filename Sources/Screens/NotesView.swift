import SwiftUI

/// Notes & ideas said out loud ("Note: …", "I have an idea: …") or typed. Pinned first, newest first.
struct NotesView: View {
    @EnvironmentObject private var notes: NoteStore
    @EnvironmentObject private var assistant: AssistantService
    @Environment(\.theme) private var theme
    @State private var filter = "all"
    @State private var editing: Note? = nil
    @State private var draftText = ""
    @State private var draftIdea = false

    private var shown: [Note] {
        notes.sorted.filter { filter == "all" || (filter == "ideas") == $0.isIdea }
    }

    private var subtitle: String {
        let ideas = notes.notes.filter { $0.isIdea }.count
        return "\(notes.notes.count - ideas) notes · \(ideas) ideas"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScreenHeader(title: "Notes", subtitle: subtitle)
            if editing != nil {
                editor
            } else {
                toolbar
                if shown.isEmpty {
                    empty
                } else {
                    grid
                }
            }
        }
        .screenPadding()
    }

    // MARK: List

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $filter) {
                Text("All").tag("all")
                Text("Ideas").tag("ideas")
                Text("Notes").tag("notes")
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
            Spacer(minLength: 8)
            Button { open(Note(text: "", isIdea: filter == "ideas")) } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(theme.accent)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Type a note")
            Button { assistant.dictateNote(idea: filter == "ideas") } label: {
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill")
                    Text("Say a note").font(.system(size: 15, weight: .bold))
                }
                .foregroundColor(theme.onAccent)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(Capsule().fill(theme.accent))
            }
            .buttonStyle(.plain)
        }
    }

    private var grid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3),
                      alignment: .leading, spacing: 10) {
                ForEach(shown) { note in
                    card(note)
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func card(_ note: Note) -> some View {
        Button { open(note) } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(note.text)
                    .font(.system(size: 16))
                    .foregroundColor(theme.label)
                    .lineLimit(5)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                HStack(spacing: 5) {
                    Image(systemName: note.isIdea ? "lightbulb.fill" : "note.text")
                        .foregroundColor(note.isIdea ? theme.yellow : theme.accent)
                    Text(Self.when(note.created))
                    Spacer(minLength: 0)
                    if note.pinned { Image(systemName: "pin.fill").foregroundColor(theme.orange) }
                }
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryLabel)
            }
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .card()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                var changed = note
                changed.pinned.toggle()
                notes.update(changed)
            } label: {
                Label(note.pinned ? "Unpin" : "Pin", systemImage: note.pinned ? "pin.slash" : "pin")
            }
            Button {
                notes.delete(note.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            Image(systemName: "lightbulb")
                .font(.system(size: 40))
                .foregroundColor(theme.secondaryLabel)
            Text(filter == "ideas" ? "No ideas yet" : "No notes yet")
                .font(.system(size: 20, weight: .bold))
            Text("Say “Note: call the plumber” or “I have an idea: a shelf for plants”.")
                .font(.system(size: 15))
                .foregroundColor(theme.secondaryLabel)
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Editor

    private func open(_ note: Note) {
        draftText = note.text
        draftIdea = note.isIdea
        editing = note
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button("Cancel") { editing = nil }
                    .foregroundColor(theme.accent)
                    .frame(minHeight: 44)
                Spacer(minLength: 0)
                Picker("", selection: $draftIdea) {
                    Text("Note").tag(false)
                    Text("Idea").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                Spacer(minLength: 0)
                if let note = editing, notes.notes.contains(where: { $0.id == note.id }) {
                    Button("Delete") {
                        notes.delete(note.id)
                        editing = nil
                    }
                    .foregroundColor(theme.red)
                    .frame(minHeight: 44)
                }
                Button("Save") { saveDraft() }
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(theme.accent)
                    .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .frame(minHeight: 44)
            }
            TextEditor(text: $draftText)
                .font(.system(size: 17))
                .padding(8)
                .background(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous).fill(theme.surface))
                .frame(maxHeight: .infinity)
        }
    }

    private func saveDraft() {
        guard var note = editing else { return }
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if notes.notes.contains(where: { $0.id == note.id }) {
            note.text = text
            note.isIdea = draftIdea
            notes.update(note)
        } else {
            notes.add(text, idea: draftIdea)
        }
        editing = nil
    }

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()
    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f
    }()

    static func when(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today \(timeFormat.string(from: date))" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return dayFormat.string(from: date)
    }
}
