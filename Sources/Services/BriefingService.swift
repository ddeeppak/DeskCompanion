import Foundation
import Combine

/// Speaks first: a morning briefing when you arrive, an evening wrap-up, and a heads-up before events.
/// Built on the phone from your own data (instant, works offline). Only when someone is at the desk
/// (front camera or a recent touch), never at night or while the assistant is busy.
final class BriefingService: ObservableObject {
    @Published var morningOn: Bool { didSet { save() } }
    @Published var eveningOn: Bool { didSet { save() } }
    @Published var headsUpOn: Bool { didSet { save() } }
    @Published var headsUpMinutes: Int { didSet { save() } }
    /// Text currently shown in the small banner at the top (while it's spoken).
    @Published private(set) var announcement: String? = nil
    @Published private(set) var announcementSymbol = "sun.max.fill"

    private weak var planner: PlannerService?
    private weak var weather: WeatherService?
    private weak var focus: FocusTimer?
    private weak var presence: PresenceService?
    private weak var night: NightMode?
    private weak var voice: VoiceService?
    private weak var speech: SpeechService?
    private weak var habits: HabitStore?
    private var announcedEvents: Set<String> = []
    weak var german: GermanStore?
    private var clearWork: DispatchWorkItem?

    init() {
        let d = UserDefaults.standard
        morningOn = d.object(forKey: "briefing.morning") as? Bool ?? true
        eveningOn = d.object(forKey: "briefing.evening") as? Bool ?? true
        headsUpOn = d.object(forKey: "briefing.headsUp") as? Bool ?? true
        headsUpMinutes = d.object(forKey: "briefing.headsUpMinutes") as? Int ?? 10
    }

    func configure(planner: PlannerService, weather: WeatherService, focus: FocusTimer, presence: PresenceService,
                   night: NightMode, voice: VoiceService, speech: SpeechService, habits: HabitStore) {
        self.planner = planner
        self.weather = weather
        self.focus = focus
        self.presence = presence
        self.night = night
        self.voice = voice
        self.speech = speech
        self.habits = habits
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(morningOn, forKey: "briefing.morning")
        d.set(eveningOn, forKey: "briefing.evening")
        d.set(headsUpOn, forKey: "briefing.headsUp")
        d.set(headsUpMinutes, forKey: "briefing.headsUpMinutes")
    }

    // MARK: When to speak (called every minute and when someone arrives)

    func check(now: Date = Date()) {
        guard !(night?.showNight ?? false), !(speech?.isListening ?? false), !(voice?.speaking ?? false),
              announcement == nil else { return }
        let present: Bool = {
            guard let presence = presence, !presence.isAway, let seen = presence.lastSeen else { return false }
            return now.timeIntervalSince(seen) < 120
        }()
        guard present else { return }

        let hour = Calendar.current.component(.hour, from: now)
        let today = HabitStore.key(now)
        let d = UserDefaults.standard

        if headsUpOn, let text = headsUp(now) {
            announce(text, symbol: "calendar.badge.clock")
            return
        }
        if morningOn, (5..<11).contains(hour), d.string(forKey: "briefing.lastMorning") != today {
            d.set(today, forKey: "briefing.lastMorning")
            announce(morningText(now), symbol: "sun.max.fill")
            return
        }
        if eveningOn, (18..<22).contains(hour), d.string(forKey: "briefing.lastEvening") != today {
            d.set(today, forKey: "briefing.lastEvening")
            announce(eveningText(now), symbol: "moon.stars.fill")
        }
    }

    func playMorningNow() { announce(morningText(Date()), symbol: "sun.max.fill") }
    func playEveningNow() { announce(eveningText(Date()), symbol: "moon.stars.fill") }

    func dismiss() {
        clearWork?.cancel()
        announcement = nil
        voice?.stop()
    }

    private func announce(_ text: String, symbol: String) {
        announcementSymbol = symbol
        announcement = text
        voice?.speak(text)
        clearWork?.cancel()
        let words = Double(text.split(separator: " ").count)
        let work = DispatchWorkItem { [weak self] in self?.announcement = nil }
        clearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(10, words * 0.45 + 4), execute: work)
    }

    // MARK: What to say

    private func headsUp(_ now: Date) -> String? {
        guard let planner = planner else { return nil }
        let window = TimeInterval(headsUpMinutes * 60)
        for event in planner.events where !event.isAllDay {
            let until = event.start.timeIntervalSince(now)
            guard until > 0, until <= window, !announcedEvents.contains(event.id) else { continue }
            announcedEvents.insert(event.id)
            let minutes = max(1, Int((until / 60).rounded()))
            return "Heads up: \(event.title) starts in \(minutes) minute\(minutes == 1 ? "" : "s")."
        }
        return nil
    }

    func morningText(_ now: Date) -> String {
        var parts = ["Good morning!"]
        if let w = weather?.snapshot {
            parts.append("It's \(Int(w.temperature.rounded())) degrees and \(WeatherCode.text(w.code).lowercased()), with a high of \(Int(w.high.rounded())).")
            if w.nextHours(after: now, count: 12).contains(where: { WeatherSnapshot.isRainy($0.code) }) {
                parts.append("Rain is likely later, so keep an umbrella handy.")
            }
        }
        if let planner = planner, planner.calendarAccess == .granted {
            let today = planner.events.filter { !$0.isAllDay }
            if let first = today.first(where: { $0.end > now }) {
                parts.append("You have \(today.count) event\(today.count == 1 ? "" : "s") today; the first is \(first.title) at \(TimeText.time(first.start)).")
            } else {
                parts.append("Your calendar is clear today.")
            }
        }
        if let planner = planner, planner.remindersAccess == .granted {
            let open = planner.tasks.filter { !$0.isCompleted }.count
            if open > 0 { parts.append("\(open) task\(open == 1 ? " is" : "s are") waiting.") }
        }
        if let streak = habits?.perfectStreak, streak >= 2 {
            parts.append("You're on a \(streak)-day habit streak. Keep it going!")
        }
        if let german = german, german.wordOfDayOn {
            let word = german.wordOfTheDay(now)
            parts.append("Your German word of the day is «\(word.de)», which means \(word.en).")
        }
        return parts.joined(separator: " ")
    }

    func eveningText(_ now: Date) -> String {
        var parts = ["Good evening."]
        if let planner = planner, planner.remindersAccess == .granted, !planner.tasks.isEmpty {
            let done = planner.doneCount
            parts.append("You finished \(done) of \(planner.tasks.count) tasks today.")
        }
        if let focus = focus {
            let minutes = Int(focus.liveFocusedToday / 60)
            if minutes >= 5 {
                let h = minutes / 60, m = minutes % 60
                let length = h > 0 ? "\(h) hour\(h == 1 ? "" : "s")\(m > 0 ? " \(m) minutes" : "")" : "\(m) minutes"
                parts.append("You focused for \(length).")
            }
        }
        if let planner = planner, planner.calendarAccess == .granted,
           let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now) {
            if let first = planner.events(on: tomorrow).first(where: { !$0.isAllDay }) {
                parts.append("Tomorrow starts with \(first.title) at \(TimeText.time(first.start)).")
            } else {
                parts.append("Tomorrow your calendar is clear.")
            }
        }
        if let w = weather?.snapshot, let high = w.tomorrowHigh {
            let code = w.tomorrowCode ?? 3
            parts.append("Tomorrow looks \(WeatherCode.text(code).lowercased()), with a high of \(Int(high.rounded()))\(WeatherSnapshot.isRainy(code) ? ", so plan for rain" : "").")
        }
        return parts.joined(separator: " ")
    }
}
