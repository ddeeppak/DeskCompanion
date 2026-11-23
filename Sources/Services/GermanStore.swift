import Foundation
import Combine

/// One German word or phrase you have practised. Spaced repetition in 5 boxes: a right answer moves it up a
/// box and it comes back later (1, 2, 4, 8, 16 days); a wrong answer sends it back to box 1 (tomorrow).
struct GermanWord: Codable, Identifiable, Equatable {
    var de: String
    var en: String
    var box: Int = 0
    var due: Date = Date()
    var seen: Int = 0
    var right: Int = 0

    var id: String { de.lowercased() }
}

/// German practice: your words, today's session and the word of the day. Stored on the iPhone.
final class GermanStore: ObservableObject {
    @Published private(set) var words: [GermanWord] { didSet { save() } }
    @Published var wordOfDayOn: Bool { didSet { UserDefaults.standard.set(wordOfDayOn, forKey: "german.wordOfDay") } }
    @Published private(set) var streak: Int
    @Published private(set) var sessionRight = 0
    @Published private(set) var sessionTotal = 0

    private static let key = "german.words.v1"
    private static let intervals = [0, 1, 2, 4, 8, 16]     // days, by box

    /// Everyday A1 words for the word of the day (the AI also brings in its own).
    static let starter: [(de: String, en: String)] = [
        ("der Apfel", "the apple"), ("das Wasser", "the water"), ("das Brot", "the bread"), ("der Kaffee", "the coffee"),
        ("die Milch", "the milk"), ("das Haus", "the house"), ("die Tür", "the door"), ("das Fenster", "the window"),
        ("der Tisch", "the table"), ("der Stuhl", "the chair"), ("die Lampe", "the lamp"), ("das Buch", "the book"),
        ("die Uhr", "the clock"), ("das Handy", "the mobile phone"), ("der Schlüssel", "the key"), ("die Tasche", "the bag"),
        ("die Stadt", "the city"), ("die Straße", "the street"), ("der Bahnhof", "the train station"), ("das Auto", "the car"),
        ("der Zug", "the train"), ("das Fahrrad", "the bicycle"), ("die Arbeit", "the work"), ("die Schule", "the school"),
        ("der Freund", "the friend"), ("die Familie", "the family"), ("die Mutter", "the mother"), ("der Vater", "the father"),
        ("der Bruder", "the brother"), ("die Schwester", "the sister"), ("das Kind", "the child"), ("der Hund", "the dog"),
        ("die Katze", "the cat"), ("der Morgen", "the morning"), ("der Abend", "the evening"), ("die Nacht", "the night"),
        ("heute", "today"), ("morgen", "tomorrow"), ("gestern", "yesterday"), ("jetzt", "now"), ("später", "later"),
        ("immer", "always"), ("oft", "often"), ("manchmal", "sometimes"), ("nie", "never"), ("groß", "big"),
        ("klein", "small"), ("schnell", "fast"), ("langsam", "slow"), ("warm", "warm"), ("kalt", "cold"),
        ("gut", "good"), ("schön", "beautiful"), ("müde", "tired"), ("hungrig", "hungry"), ("glücklich", "happy"),
        ("essen", "to eat"), ("trinken", "to drink"), ("schlafen", "to sleep"), ("arbeiten", "to work"),
        ("lernen", "to learn"), ("sprechen", "to speak"), ("lesen", "to read"), ("schreiben", "to write"),
        ("gehen", "to go"), ("kommen", "to come"), ("kaufen", "to buy"), ("verstehen", "to understand"),
        ("Guten Morgen", "good morning"), ("Gute Nacht", "good night"), ("Danke schön", "thank you very much"),
        ("Bitte", "please"), ("Entschuldigung", "excuse me"), ("Wie geht's?", "how are you?"),
        ("Ich verstehe nicht", "I don't understand"), ("Wie viel kostet das?", "how much does it cost?"),
        ("Ich habe Hunger", "I'm hungry"), ("Bis später", "see you later"), ("Keine Ahnung", "no idea"),
        ("Das Wetter ist schön", "the weather is nice")
    ]

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: Self.key), let saved = try? JSONDecoder().decode([GermanWord].self, from: data) {
            words = saved
        } else {
            words = []
        }
        wordOfDayOn = d.object(forKey: "german.wordOfDay") as? Bool ?? true
        streak = d.integer(forKey: "german.streak")
    }

    private func save() {
        if let data = try? JSONEncoder().encode(words) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    // MARK: Practice

    func startSession() {
        sessionRight = 0
        sessionTotal = 0
    }

    /// From the AI's WORD lines: a new word (correct == nil) or an answer.
    func record(de: String, en: String, correct: Bool?) {
        let clean = de.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let calendar = Calendar.current
        var word = words.first { $0.id == clean.lowercased() } ?? GermanWord(de: clean, en: en)
        if !en.isEmpty { word.en = en }
        if let correct = correct {
            word.seen += 1
            sessionTotal += 1
            if correct {
                word.right += 1
                sessionRight += 1
                word.box = min(5, word.box + 1)
            } else {
                word.box = 1
            }
            let days = Self.intervals[word.box]
            word.due = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: Date())) ?? Date()
        }
        if let index = words.firstIndex(where: { $0.id == word.id }) {
            words[index] = word
        } else {
            words.append(word)
        }
    }

    /// "You got 5 of 6 right." Also keeps the daily streak.
    func endSession() -> String {
        defer { startSession() }
        guard sessionTotal > 0 else { return "Okay, we'll practise another time." }
        let d = UserDefaults.standard
        let today = HabitStore.key(Date())
        let yesterday = HabitStore.key(Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date())
        let last = d.string(forKey: "german.lastDay")
        if last != today {
            streak = last == yesterday ? streak + 1 : 1
            d.set(streak, forKey: "german.streak")
            d.set(today, forKey: "german.lastDay")
        }
        let score = "You got \(sessionRight) of \(sessionTotal) right."
        let praise = sessionRight == sessionTotal ? " Perfect, sehr gut!" : (sessionRight * 2 >= sessionTotal ? " Well done!" : " Keep going, it gets easier.")
        return score + praise + " That's \(streak) day\(streak == 1 ? "" : "s") in a row."
    }

    func reset() {
        words = []
        streak = 0
        UserDefaults.standard.set(0, forKey: "german.streak")
        UserDefaults.standard.removeObject(forKey: "german.lastDay")
    }

    // MARK: What to practise

    var due: [GermanWord] {
        words.filter { $0.box > 0 && $0.due <= Date() }.sorted { $0.due < $1.due }
    }

    var learnedCount: Int { words.filter { $0.box >= 3 }.count }

    /// For the AI: what to review and how the session is going.
    var contextSummary: String {
        let review = due.prefix(8).map { "«\($0.de)» = \($0.en)" }.joined(separator: "; ")
        var parts = ["\(words.count) words practised, \(learnedCount) well known"]
        parts.append(review.isEmpty ? "nothing due for review: bring in new everyday words" : "due for review: \(review)")
        if sessionTotal > 0 { parts.append("this session \(sessionRight) of \(sessionTotal) right") }
        return parts.joined(separator: ". ")
    }

    /// The same word all day: a word due for review, otherwise the next starter word.
    func wordOfTheDay(_ date: Date = Date()) -> (de: String, en: String) {
        if let first = due.first { return (first.de, first.en) }
        let day = Calendar.current.ordinality(of: .day, in: .era, for: date) ?? 0
        let known = Set(words.map { $0.id })
        let fresh = Self.starter.filter { !known.contains($0.de.lowercased()) }
        let list = fresh.isEmpty ? Self.starter : fresh
        return list[day % list.count]
    }
}
