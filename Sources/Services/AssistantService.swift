import Foundation
import Combine

struct ChatMessage: Identifiable, Codable, Equatable {
    var id = UUID()
    let fromUser: Bool
    let text: String
    let source: String?        // "offline" or "ai" (step 6)
    let date: Date
}

/// Result card on the right of the answer screen (design: icon tile, title, detail, Edit / Undo).
struct ActionCard: Equatable {
    enum Kind { case reminder, task, timer, alarm, focus, info, weather, calendar }
    enum Undo: Equatable { case reminder(String), task(String), alarm(UUID), timer, focus }

    let kind: Kind
    let heading: String        // "Reminder created"
    let title: String          // "Call Mom"
    let detail: String         // "Today, 6:00 PM"
    let undo: Undo?
    let canEdit: Bool
}

/// The voice assistant: listen → understand (offline rules) → act → reply (text + voice).
final class AssistantService: ObservableObject {
    enum Phase: Equatable { case idle, listening, answered, misheard, noPermission }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var card: ActionCard? = nil
    @Published private(set) var heard = ""
    @Published private(set) var handledIn: TimeInterval = 0
    @Published private(set) var undone = false

    private var app: AppState?
    private var planner: PlannerService?
    private var alarms: AlarmStore?
    private var timer: QuickTimer?
    private var focus: FocusTimer?
    private var weather: WeatherService?
    private var speech: SpeechService?
    private var voice: VoiceService?

    private static let historyKey = "assistant.history.v1"

    init() {
        // Keep only today's conversation.
        if let data = UserDefaults.standard.data(forKey: Self.historyKey),
           let saved = try? JSONDecoder().decode([ChatMessage].self, from: data) {
            let today = Calendar.current.startOfDay(for: Date())
            messages = saved.filter { $0.date >= today }
        }
    }

    func configure(app: AppState, planner: PlannerService, alarms: AlarmStore, timer: QuickTimer,
                   focus: FocusTimer, weather: WeatherService, speech: SpeechService, voice: VoiceService) {
        self.app = app
        self.planner = planner
        self.alarms = alarms
        self.timer = timer
        self.focus = focus
        self.weather = weather
        self.speech = speech
        self.voice = voice
    }

    // MARK: Listening

    func listen() {
        guard let speech = speech, !speech.isListening else { return }
        voice?.stop()
        Haptics.tap()                      // before the mic opens
        app?.screen = .assistant
        phase = .listening
        speech.start(onFinish: { [weak self] text in
            self?.received(text)
        }, onDenied: { [weak self] in
            self?.phase = .noPermission
        })
    }

    func stopListening() { speech?.stop() }

    func cancelListening() {
        speech?.cancel()
        phase = messages.isEmpty ? .idle : .answered
    }

    private func received(_ text: String) {
        if text.isEmpty {
            heard = ""
            phase = .misheard
            Haptics.error()
            return
        }
        handle(text)
    }

    // MARK: Understanding + acting

    /// Also used by the suggestion chips.
    func handle(_ text: String) {
        let started = Date()
        let intent = CommandParser.parse(text)
        if intent == .unknown {
            heard = text
            phase = .misheard
            Haptics.error()
            voice?.speak("Sorry, I didn't understand. Try saying it another way.")
            return
        }
        let reply = perform(intent)
        handledIn = Date().timeIntervalSince(started)
        undone = false
        append(ChatMessage(fromUser: true, text: text, source: nil, date: Date()))
        append(ChatMessage(fromUser: false, text: reply.text, source: "offline", date: Date()))
        card = reply.card
        phase = .answered
        if reply.card?.undo != nil { Haptics.success() }
        voice?.speak(reply.text)
        if case .startFocus = intent {
            // Show the timer after the reply has been spoken.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.app?.screen = .focus }
        }
    }

    private func perform(_ intent: VoiceIntent) -> (text: String, card: ActionCard?) {
        let now = Date()
        switch intent {
        case .timer(let seconds):
            timer?.start(seconds: seconds)
            let ends = now.addingTimeInterval(TimeInterval(seconds))
            return ("Timer set for \(QuickTimer.spoken(seconds)).",
                    ActionCard(kind: .timer, heading: "Timer started", title: QuickTimer.describe(seconds) + " timer",
                               detail: "Ends at \(TimeText.time(ends))", undo: .timer, canEdit: false))

        case .cancelTimer:
            guard timer?.isRunning == true || timer?.ringing == true else { return ("There's no timer running.", nil) }
            timer?.cancel()
            return ("Timer cancelled.", nil)

        case .alarm(let hour, let minute):
            guard let alarms = alarms else { return ("Alarms aren't available.", nil) }
            if !alarms.featureEnabled { alarms.featureEnabled = true }
            let alarm = Alarm(hour: hour, minute: minute, days: [], enabled: true, label: "Alarm")
            alarms.alarms.append(alarm)
            alarms.requestNotificationPermission()
            let when = alarm.nextFire(after: now).map { dayWord($0) } ?? ""
            return ("Alarm set for \(alarm.timeText)\(when.isEmpty ? "" : " " + when).",
                    ActionCard(kind: .alarm, heading: "Alarm set", title: alarm.timeText,
                               detail: when.isEmpty ? "Once" : CommandParser.capitalizeFirst(when), undo: .alarm(alarm.id),
                               canEdit: true))

        case .reminder(let title, let due):
            guard let planner = planner else { return ("Reminders aren't available.", nil) }
            if planner.remindersAccess == .denied {
                return ("I can't add reminders yet. Allow Reminders access in Settings.", nil)
            }
            guard let id = planner.addReminder(title: title, due: due, byVoice: true) else {
                return ("Sorry, I couldn't create that reminder.", nil)
            }
            if let due = due {
                let lowerTitle = title.prefix(1).lowercased() + title.dropFirst()
                return ("Done. I'll remind you \(dayWord(due)) at \(TimeText.time(due)) to \(lowerTitle).",
                        ActionCard(kind: .reminder, heading: "Reminder created", title: title,
                                   detail: "\(CommandParser.capitalizeFirst(dayWord(due))), \(TimeText.time(due))",
                                   undo: .reminder(id), canEdit: true))
            }
            return ("Added \"\(title)\" to your reminders.",
                    ActionCard(kind: .reminder, heading: "Reminder created", title: title, detail: "No time set",
                               undo: .reminder(id), canEdit: true))

        case .addTask(let item):
            guard let planner = planner else { return ("Lists aren't available.", nil) }
            if planner.remindersAccess == .denied {
                return ("I can't add to your list yet. Allow Reminders access in Settings.", nil)
            }
            guard let id = planner.addReminder(title: item, due: nil, byVoice: true) else {
                return ("Sorry, I couldn't add that.", nil)
            }
            return ("Added \(item.lowercased()) to your \(planner.selectedListTitle) list.",
                    ActionCard(kind: .task, heading: "Added to list", title: item, detail: planner.selectedListTitle,
                               undo: .task(id), canEdit: true))

        case .agenda(let offset):
            return agenda(offset: offset)

        case .weather(let offset, let rainQuestion):
            return weatherReply(offset: offset, rainQuestion: rainQuestion)

        case .time:
            let time = TimeText.time(now)
            return ("It's \(time).", ActionCard(kind: .info, heading: "Time", title: time, detail: DateText.long(now),
                                                undo: nil, canEdit: false))

        case .date:
            let date = DateText.long(now)
            return ("Today is \(date).", ActionCard(kind: .calendar, heading: "Today", title: date, detail: TimeText.time(now),
                                                    undo: nil, canEdit: false))

        case .startFocus(let minutes):
            guard let focus = focus else { return ("Focus isn't available.", nil) }
            if let minutes = minutes, minutes > 0 {
                focus.customFocusMinutes = min(120, max(5, minutes))
                focus.preset = .custom
            }
            focus.reset()
            focus.startFocus()
            let length = Int(focus.focusLength / 60)
            return ("Starting a \(length) minute focus session.",
                    ActionCard(kind: .focus, heading: "Focus started", title: "\(length) min focus",
                               detail: focus.task.isEmpty ? "Focus session" : focus.task, undo: .focus, canEdit: false))

        case .stopFocus:
            guard let focus = focus, focus.state == .running else { return ("Focus isn't running.", nil) }
            focus.pause()
            return ("Focus paused.", nil)

        case .help:
            return ("You can say: set a 10 minute timer, wake me at 6:30, remind me at 6 to call mom, add milk to my list, what's on today, or what's the weather.",
                    ActionCard(kind: .info, heading: "Try saying", title: "“Remind me at 6 to call Mom”",
                               detail: "Timers · alarms · reminders · lists · calendar · weather · focus",
                               undo: nil, canEdit: false))

        case .unknown:
            return ("Sorry, I didn't understand.", nil)
        }
    }

    private func agenda(offset: Int) -> (text: String, card: ActionCard?) {
        guard let planner = planner else { return ("The calendar isn't available.", nil) }
        if planner.calendarAccess == .denied { return ("I can't see your calendar. Allow access in Settings.", nil) }
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: offset, to: Date()) ?? Date()
        let dayName = offset == 0 ? "today" : "tomorrow"
        var events = planner.events(on: day)
        if offset == 0 { events = events.filter { $0.isAllDay || $0.end > Date() } }
        guard !events.isEmpty else {
            return (offset == 0 ? "Nothing else on your calendar today." : "Your calendar is clear tomorrow.",
                    ActionCard(kind: .calendar, heading: CommandParser.capitalizeFirst(dayName), title: "No events",
                               detail: "Your calendar is clear", undo: nil, canEdit: false))
        }
        let spoken = events.prefix(4).map { event -> String in
            event.isAllDay ? "\(event.title), all day" : "\(event.title) at \(TimeText.time(event.start))"
        }
        let list: String
        if spoken.count == 1 {
            list = spoken[0]
        } else {
            list = spoken.dropLast().joined(separator: ", ") + " and " + (spoken.last ?? "")
        }
        let count = events.count == 1 ? "1 event" : "\(events.count) events"
        let first = events[0]
        return ("You have \(count) \(offset == 0 ? "left today" : "tomorrow"): \(list).",
                ActionCard(kind: .calendar, heading: "\(CommandParser.capitalizeFirst(dayName)) · \(count)", title: first.title,
                           detail: first.isAllDay ? "All day" : "\(TimeText.time(first.start)) – \(TimeText.time(first.end))",
                           undo: nil, canEdit: true))
    }

    private func weatherReply(offset: Int, rainQuestion: Bool) -> (text: String, card: ActionCard?) {
        guard let w = weather?.snapshot else { return ("I don't have the weather yet. Check that Location is allowed.", nil) }
        if offset == 0 {
            let rainSoon = w.nextHours(after: Date(), count: 12).contains { WeatherSnapshot.isRainy($0.code) }
            let condition = WeatherCode.text(w.code).lowercased()
            var text = "It's \(Int(w.temperature.rounded())) degrees and \(condition). Today's high is \(Int(w.high.rounded())) and the low is \(Int(w.low.rounded()))."
            if rainQuestion { text = rainSoon ? "Yes, rain is likely in the next few hours." : "No rain expected in the next 12 hours." }
            return (text, ActionCard(kind: .weather, heading: "Weather now", title: "\(Int(w.temperature.rounded()))° \(WeatherCode.text(w.code))",
                                     detail: "H:\(Int(w.high.rounded()))° L:\(Int(w.low.rounded()))°", undo: nil, canEdit: false))
        }
        guard let high = w.tomorrowHigh, let low = w.tomorrowLow else {
            return ("I don't have tomorrow's forecast yet.", nil)
        }
        let code = w.tomorrowCode ?? 3
        let condition = WeatherCode.text(code).lowercased()
        var text = "Tomorrow looks \(condition), with a high of \(Int(high.rounded())) and a low of \(Int(low.rounded()))."
        if rainQuestion { text = WeatherSnapshot.isRainy(code) ? "Yes, rain is expected tomorrow." : "No rain expected tomorrow." }
        return (text, ActionCard(kind: .weather, heading: "Tomorrow", title: WeatherCode.text(code),
                                 detail: "H:\(Int(high.rounded()))° L:\(Int(low.rounded()))°", undo: nil, canEdit: false))
    }

    private func dayWord(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "today" }
        if calendar.isDateInTomorrow(date) { return "tomorrow" }
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return "on " + f.string(from: date)
    }

    // MARK: Undo / edit

    func undo() {
        guard let card = card, let token = card.undo, !undone else { return }
        switch token {
        case .reminder(let id), .task(let id):
            planner?.deleteReminder(id: id)
        case .alarm(let id):
            alarms?.remove(id)
        case .timer:
            timer?.cancel()
        case .focus:
            focus?.reset()
        }
        undone = true
        Haptics.tap()
        append(ChatMessage(fromUser: false, text: "Undone.", source: "offline", date: Date()))
        voice?.speak("Undone.")
    }

    func edit() {
        guard let card = card else { return }
        switch card.kind {
        case .alarm:
            app?.pendingSettingsSection = "alarms"
            app?.screen = .settings
        case .reminder, .task, .calendar:
            app?.screen = .today
        default:
            break
        }
    }

    func clearHistory() {
        messages = []
        card = nil
        phase = .idle
        UserDefaults.standard.removeObject(forKey: Self.historyKey)
    }

    private func append(_ message: ChatMessage) {
        messages.append(message)
        if messages.count > 40 { messages.removeFirst(messages.count - 40) }
        if let data = try? JSONEncoder().encode(messages) {
            UserDefaults.standard.set(data, forKey: Self.historyKey)
        }
    }
}
