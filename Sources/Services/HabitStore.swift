import Foundation
import Combine

struct Habit: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var symbol: String
    var target: Int          // 1 = tick once a day; more = counter (e.g. 8 glasses)
    var unit: String         // counter unit, e.g. "glasses"
    var detail: String       // shown when not done, e.g. "5 minutes"
    var streakWord: String   // "days" or "nights"
}

/// Habits saved on the phone, with a daily log for progress and streaks.
final class HabitStore: ObservableObject {
    struct Entry: Codable {
        var count: Int
        var doneAt: Date?
    }

    @Published private(set) var habits: [Habit]
    @Published private(set) var log: [String: [String: Entry]]      // "yyyy-MM-dd" -> habit id -> entry

    private static let habitsKey = "habits.list.v1"
    private static let logKey = "habits.log.v1"

    static let starter: [Habit] = [
        Habit(name: "Water", symbol: "drop.fill", target: 8, unit: "glasses", detail: "", streakWord: "days"),
        Habit(name: "Read 20 min", symbol: "book.fill", target: 1, unit: "", detail: "20 minutes", streakWord: "days"),
        Habit(name: "Stretch", symbol: "figure.walk", target: 1, unit: "", detail: "5 minutes", streakWord: "days"),
        Habit(name: "Sleep by 11 PM", symbol: "moon.fill", target: 1, unit: "", detail: "Lights out by 11", streakWord: "nights")
    ]

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.habitsKey), let saved = try? JSONDecoder().decode([Habit].self, from: data) {
            habits = saved
        } else {
            habits = HabitStore.starter
        }
        if let data = defaults.data(forKey: Self.logKey),
           let saved = try? JSONDecoder().decode([String: [String: Entry]].self, from: data) {
            log = saved
        } else {
            log = [:]
        }
    }

    // MARK: Reading

    static func key(_ date: Date) -> String { dayFormatter.string(from: date) }

    func entry(_ habit: Habit, on date: Date = Date()) -> Entry {
        log[Self.key(date)]?[habit.id.uuidString] ?? Entry(count: 0, doneAt: nil)
    }

    func isDone(_ habit: Habit, on date: Date = Date()) -> Bool {
        entry(habit, on: date).count >= habit.target
    }

    func progress(_ habit: Habit) -> Double {
        min(1, Double(entry(habit).count) / Double(max(1, habit.target)))
    }

    /// Days in a row the habit was done (counting today if done, otherwise up to yesterday).
    func streak(_ habit: Habit) -> Int {
        countBack { isDone(habit, on: $0) }
    }

    /// Days in a row where every habit was done (the flame on the Habits card).
    var perfectStreak: Int {
        guard !habits.isEmpty else { return 0 }
        return countBack { day in habits.allSatisfy { isDone($0, on: day) } }
    }

    func subtitle(_ habit: Habit) -> String {
        let e = entry(habit)
        if habit.target > 1 { return "\(e.count) of \(habit.target) \(habit.unit)" }
        if e.count >= 1, let at = e.doneAt { return "Done \(TimeText.time(at))" }
        let s = streak(habit)
        if s >= 2 { return "\(s) \(habit.streakWord) in a row" }
        return habit.detail
    }

    private func countBack(_ done: (Date) -> Bool) -> Int {
        let calendar = Calendar.current
        var day = calendar.startOfDay(for: Date())
        if !done(day) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        var count = 0
        while count < 366 && done(day) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    // MARK: Changes

    /// Tap on the Today screen: ticks a habit, or adds one to a counter (wraps to 0 after the target).
    func tap(_ habit: Habit) {
        var e = entry(habit)
        if habit.target <= 1 {
            e.count = e.count >= 1 ? 0 : 1
        } else {
            e.count = e.count >= habit.target ? 0 : e.count + 1
        }
        e.doneAt = e.count >= habit.target ? Date() : nil
        let day = Self.key(Date())
        var dayLog = log[day] ?? [:]
        dayLog[habit.id.uuidString] = e
        log[day] = dayLog
        save()
    }

    func add(name: String, target: Int) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        habits.append(Habit(name: trimmed, symbol: "star.fill", target: max(1, target),
                            unit: target > 1 ? "times" : "", detail: "", streakWord: "days"))
        save()
    }

    func remove(_ habit: Habit) {
        habits.removeAll { $0.id == habit.id }
        save()
    }

    private func save() {
        // Keep about 4 months of history.
        if let cutoff = Calendar.current.date(byAdding: .day, value: -120, to: Date()) {
            let cutoffKey = Self.key(cutoff)
            log = log.filter { $0.key >= cutoffKey }
        }
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(habits) { defaults.set(data, forKey: Self.habitsKey) }
        if let data = try? JSONEncoder().encode(log) { defaults.set(data, forKey: Self.logKey) }
    }
}
