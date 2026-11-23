import Foundation
import Combine

/// One of your own commands: say a phrase (or something close to it) and several actions run.
/// Can also run by itself at a time of day, or when you sit down at the desk.
struct Routine: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var phrases: [String]
    /// Each step is one ACTION JSON object, e.g. {"type":"set_style","style":"warm"}
    var steps: [String]
    var enabled: Bool = true
    /// "HH:mm": runs at that time on `days` (1 = Sunday … 7 = Saturday; empty = every day)
    var time: String? = nil
    var days: [Int] = []
    /// Runs once a day when you sit down, between these hours
    var onArrive: Bool = false
    var arriveFrom: Int = 5
    var arriveTo: Int = 11
    var lastRun: String? = nil

    static func blank() -> Routine { Routine(name: "", phrases: [], steps: []) }

    var triggerText: String {
        if let time = time {
            let parts = time.split(separator: ":").compactMap { Int($0) }
            let label = parts.count == 2 ? Alarm(hour: parts[0], minute: parts[1]).timeText : time
            let days = Alarm(hour: 0, minute: 0, days: self.days).daysText
            return "At \(label), \(self.days.isEmpty ? "every day" : days.lowercased())"
        }
        if onArrive { return "When you sit down, \(Self.hourText(arriveFrom))–\(Self.hourText(arriveTo))" }
        return ""
    }

    static func hourText(_ hour: Int) -> String {
        let h = hour % 24
        let h12 = h % 12 == 0 ? 12 : h % 12
        return "\(h12) \(h < 12 ? "AM" : "PM")"
    }
}

/// A new way of saying something that the AI understood: saved so next time it runs instantly, even offline.
struct LearnedPhrase: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var phrase: String
    var steps: [String]
    var uses: Int = 1
    var date: Date = Date()
}

/// Your commands, learned phrases and long-term memory. All stored on the iPhone (memory is backed up to the PC).
final class CommandStore: ObservableObject {
    @Published var routines: [Routine] { didSet { save() } }
    @Published var learned: [LearnedPhrase] { didSet { save() } }
    @Published var learningOn: Bool { didSet { UserDefaults.standard.set(learningOn, forKey: "commands.learning") } }
    @Published private(set) var memory: [String] { didSet { save() } }

    private static let routinesKey = "commands.routines.v1"
    private static let learnedKey = "commands.learned.v1"
    private static let memoryKey = "memory.facts.v1"
    private static let importedKey = "memory.importedFromPC"
    static let maxMemories = 60

    init() {
        let d = UserDefaults.standard
        learningOn = d.object(forKey: "commands.learning") as? Bool ?? true
        if let data = d.data(forKey: Self.routinesKey),
           let saved = try? JSONDecoder().decode([Routine].self, from: data) {
            routines = saved
        } else {
            routines = []
        }
        if let data = d.data(forKey: Self.learnedKey),
           let saved = try? JSONDecoder().decode([LearnedPhrase].self, from: data) {
            learned = saved
        } else {
            learned = []
        }
        memory = d.stringArray(forKey: Self.memoryKey) ?? []
    }

    private func save() {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(routines) { d.set(data, forKey: Self.routinesKey) }
        if let data = try? JSONEncoder().encode(learned) { d.set(data, forKey: Self.learnedKey) }
        d.set(memory, forKey: Self.memoryKey)
    }

    // MARK: Routines

    func upsert(_ routine: Routine) {
        var cleaned = routine
        cleaned.name = cleaned.name.trimmingCharacters(in: .whitespaces)
        cleaned.phrases = cleaned.phrases.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if cleaned.phrases.isEmpty, !cleaned.name.isEmpty { cleaned.phrases = [cleaned.name] }
        if let index = routines.firstIndex(where: { $0.id == cleaned.id }) {
            routines[index] = cleaned
        } else {
            routines.insert(cleaned, at: 0)
        }
    }

    func remove(_ id: UUID) {
        routines.removeAll { $0.id == id }
    }

    func routine(named name: String) -> Routine? {
        let target = Self.normalize(name)
        if let exact = routines.first(where: { Self.normalize($0.name) == target }) { return exact }
        return routines
            .map { r -> (Routine, Double) in (r, ([r.name] + r.phrases).map { Self.score(target, Self.normalize($0)) }.max() ?? 0) }
            .filter { $0.1 >= 0.75 }
            .max { $0.1 < $1.1 }?.0
    }

    /// Your phrase said exactly, or nearly (spelling slips, word order, "please", "run").
    func matchRoutine(_ said: String) -> Routine? {
        let text = Self.stripFillers(Self.normalize(said))
        guard !text.isEmpty else { return nil }
        var best: (Routine, Double)? = nil
        for routine in routines where routine.enabled {
            for phrase in routine.phrases + [routine.name] {
                let p = Self.stripFillers(Self.normalize(phrase))
                guard !p.isEmpty else { continue }
                let s: Double = p.count <= 3 ? (p == text ? 1.0 : 0.0) : Self.score(text, p)
                if s > (best?.1 ?? 0) { best = (routine, s) }
            }
        }
        guard let found = best, found.1 >= 0.8 else { return nil }
        return found.0
    }

    // MARK: Triggers

    private static let minuteKey: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    /// Routines whose time came in the last 2 minutes and haven't run for it yet.
    func dueRoutines(now: Date = Date()) -> [Routine] {
        let calendar = Calendar.current
        var due: [Routine] = []
        for (index, routine) in routines.enumerated() where routine.enabled {
            guard let time = routine.time else { continue }
            let hm = time.split(separator: ":").compactMap { Int($0) }
            guard hm.count == 2,
                  let at = calendar.date(bySettingHour: hm[0], minute: hm[1], second: 0, of: now) else { continue }
            let late = now.timeIntervalSince(at)
            guard late >= 0, late < 120 else { continue }
            if !routine.days.isEmpty, !routine.days.contains(calendar.component(.weekday, from: at)) { continue }
            let stamp = Self.minuteKey.string(from: at)
            guard routine.lastRun != stamp else { continue }
            routines[index].lastRun = stamp
            due.append(routine)
        }
        return due
    }

    /// Routines that run when you sit down (once a day, inside their hours).
    func arrivalRoutines(now: Date = Date()) -> [Routine] {
        let hour = Calendar.current.component(.hour, from: now)
        let today = HabitStore.key(now)
        var due: [Routine] = []
        for (index, routine) in routines.enumerated() where routine.enabled && routine.onArrive {
            guard hour >= routine.arriveFrom, hour < max(routine.arriveTo, routine.arriveFrom + 1) else { continue }
            guard routine.lastRun?.hasPrefix(today) != true else { continue }
            routines[index].lastRun = today
            due.append(routine)
        }
        return due
    }

    // MARK: Learned phrases

    func matchLearned(_ said: String) -> LearnedPhrase? {
        let text = Self.normalize(said)
        guard !text.isEmpty else { return nil }
        let best = learned
            .map { item -> (LearnedPhrase, Double) in (item, Self.score(text, Self.normalize(item.phrase))) }
            .max { $0.1 < $1.1 }
        guard let found = best, found.1 >= 0.9 else { return nil }
        return found.0
    }

    func learn(_ phrase: String, steps: [String]) {
        guard learningOn else { return }
        let text = Self.normalize(phrase)
        guard !text.isEmpty, !steps.isEmpty else { return }
        if let index = learned.firstIndex(where: { Self.score(text, Self.normalize($0.phrase)) >= 0.95 }) {
            learned[index].steps = steps
            learned[index].uses += 1
            learned[index].date = Date()
            return
        }
        learned.insert(LearnedPhrase(phrase: phrase, steps: steps), at: 0)
        if learned.count > 100 { learned.removeLast(learned.count - 100) }
    }

    func used(_ item: LearnedPhrase) {
        guard let index = learned.firstIndex(where: { $0.id == item.id }) else { return }
        learned[index].uses += 1
    }

    func removeLearned(_ id: UUID) { learned.removeAll { $0.id == id } }
    func clearLearned() { learned = [] }

    // MARK: Memory (facts you asked the assistant to remember)

    /// Adds a fact; replaces older facts that say almost the same thing. Returns false if already known.
    @discardableResult
    func remember(_ fact: String) -> Bool {
        let clean = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        if memory.contains(where: { $0.lowercased() == clean.lowercased() }) { return false }
        memory = [clean] + Self.without(memory, matching: clean)
        if memory.count > Self.maxMemories { memory.removeLast(memory.count - Self.maxMemories) }
        return true
    }

    /// Removes facts containing the phrase. Returns the removed facts.
    @discardableResult
    func forget(_ phrase: String) -> [String] {
        let before = memory
        memory = Self.without(memory, matching: phrase)
        return before.filter { !memory.contains($0) }
    }

    func forgetExact(_ fact: String) { memory.removeAll { $0 == fact } }
    func clearMemory() { memory = [] }
    func restoreMemory(_ facts: [String]) { memory = facts }

    /// First time only: take over the facts already stored on the PC.
    func importFromPC(_ facts: [String]) {
        let d = UserDefaults.standard
        guard !d.bool(forKey: Self.importedKey) else { return }
        d.set(true, forKey: Self.importedKey)
        for fact in facts.reversed() where !memory.contains(fact) { memory.insert(fact, at: 0) }
    }

    private static func without(_ items: [String], matching phrase: String) -> [String] {
        let p = phrase.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return items }
        return items.filter { !$0.lowercased().contains(p) && !p.contains($0.lowercased()) }
    }

    // MARK: Matching helpers

    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let kept = String(lowered.map { ($0.isLetter || $0.isNumber || $0 == " ") ? $0 : " " })
        return kept.split(separator: " ").joined(separator: " ")
    }

    private static let fillers: Set<String> = ["please", "run", "start", "do", "hey", "ok", "okay", "now", "the",
                                               "my", "mode", "routine", "command", "time", "for", "me"]

    /// "okay run movie time please" → "movie"… but never strips everything.
    static func stripFillers(_ text: String) -> String {
        let words = text.split(separator: " ").map(String.init)
        let kept = words.filter { !fillers.contains($0) }
        return kept.isEmpty ? text : kept.joined(separator: " ")
    }

    /// 0…1: best of letter similarity and word-order-free similarity.
    static func score(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let sortedA = a.split(separator: " ").sorted().joined(separator: " ")
        let sortedB = b.split(separator: " ").sorted().joined(separator: " ")
        return max(similarity(a, b), similarity(sortedA, sortedB))
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        if x.isEmpty || y.isEmpty { return 0 }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            previous = current
        }
        return 1 - Double(previous[y.count]) / Double(max(x.count, y.count))
    }

    // MARK: Steps

    static func step(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    static func json(_ step: String) -> [String: Any]? {
        guard let start = step.firstIndex(of: "{"), let end = step.lastIndex(of: "}"), start < end,
              let data = String(step[start...end]).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func type(_ object: [String: Any]) -> String {
        ((object["type"] as? String) ?? "").lowercased().filter { $0.isLetter }
    }

    static func value(_ any: Any?) -> String {
        guard let any = any else { return "" }
        if let n = any as? NSNumber {
            // JSON true/false arrive as NSNumber too; 0 and 1 must stay numbers.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "on" : "off" }
            return n.stringValue
        }
        if let s = any as? String { return s }
        return ""
    }

    /// Plain-English description of one step ("Switch to Warm style").
    static func describe(_ step: String) -> String {
        guard let object = json(step) else { return "Unknown step" }
        let kind = type(object)
        func text(_ key: String) -> String { value(object[key]) }
        switch kind {
        case "setstyle": return "Switch to \(text("style").capitalized) style"
        case "setsetting", "set":
            return "Set \(text("key").replacingOccurrences(of: "_", with: " ")) to \(text("value"))"
        case "open":
            let section = text("section")
            return "Open \(text("screen").capitalized)\(section.isEmpty ? "" : " → \(section.capitalized)")"
        case "playsound": return "Play \(text("sound").replacingOccurrences(of: "file:", with: "")) sound"
        case "stopsound": return "Stop the sound"
        case "focus":
            let minutes = text("minutes")
            return minutes.isEmpty ? "Start focus" : "Start a \(minutes) min focus"
        case "stopfocus": return "Stop focus"
        case "extendfocus": return "Add \(text("minutes")) min to focus"
        case "startbreak": return "Start a break"
        case "skip": return "Skip to the next session"
        case "timer":
            let seconds = Int(text("seconds")) ?? 0
            return "Timer for \(QuickTimer.spoken(seconds))"
        case "canceltimer": return "Cancel the timer"
        case "alarm": return "Alarm at \(text("time"))"
        case "alarmonoff": return "Turn the \(text("time")) alarm \(text("on") == "on" ? "on" : "off")"
        case "snooze": return "Snooze the alarm"
        case "stopalarm": return "Stop the alarm"
        case "briefing": return text("kind") == "evening" ? "Evening wrap-up" : "Morning briefing"
        case "completehabit": return "Tick off \(text("name"))"
        case "reminder": return "Reminder: \(text("title"))"
        case "task": return "Add task: \(text("title"))"
        case "say": return "Say “\(text("text"))”"
        case "runroutine": return "Run “\(text("name"))”"
        default: return kind.isEmpty ? "Unknown step" : kind.capitalized
        }
    }
}
