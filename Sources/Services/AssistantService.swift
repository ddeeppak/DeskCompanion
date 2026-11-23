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
    enum Kind { case reminder, task, timer, alarm, focus, info, weather, calendar, ai, offline }
    enum Undo: Equatable { case reminder(String), task(String), alarm(UUID), timer, focus, custom(UUID) }

    let kind: Kind
    let heading: String        // "Reminder created"
    let title: String          // "Call Mom"
    let detail: String         // "Today, 6:00 PM"
    let undo: Undo?
    let canEdit: Bool
}

/// Tracks one AI request, so a slow answer can hand over to the phone's own commands.
private final class AskProgress {
    var received = false
    var done = false
    var fellBack = false
}

/// The voice assistant: listen → understand (your commands, the AI, or the phone's rules) → act → reply.
final class AssistantService: ObservableObject {
    enum Phase: Equatable { case idle, listening, thinking, answered, misheard, noPermission, looking }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var card: ActionCard? = nil
    @Published private(set) var heard = ""
    @Published private(set) var handledIn: TimeInterval = 0
    @Published private(set) var undone = false
    /// Question being sent to the AI on the PC (shown while "Thinking…").
    @Published private(set) var thinkingQuestion = ""
    /// What the AI is doing right now ("Checking your calendar…"), shown under "Thinking…".
    @Published private(set) var thinkingStatus = ""
    /// Camera question waiting for its photo ("What's this?").
    @Published private(set) var lookQuestion = ""
    private var lookShowsQuestion = true
    private var lastQuestion = ""
    /// After "For what time?", the next thing you say completes this ("set an alarm for" + "4:30").
    private var pendingPrefix: String?
    private var askTask: Task<Void, Never>?

    /// Conversation mode: after an answer is spoken, listen again for a few seconds for a follow-up.
    @Published var keepListening: Bool {
        didSet { UserDefaults.standard.set(keepListening, forKey: "assistant.keepListening") }
    }
    /// True while listening for a follow-up (quietly gives up if nothing is said).
    @Published private(set) var isFollowUp = false
    private var followUpArmed = false
    private var cancellables = Set<AnyCancellable>()

    /// "ai": the AI understands everything (phone parser as fallback). "phone": the phone's rules first.
    @Published var routing: String {
        didSet { UserDefaults.standard.set(routing, forKey: "assistant.routing") }
    }
    /// A question waiting for yes / no ("Delete all 3 alarms?").
    @Published private(set) var confirmation: String? = nil
    private var pendingRun: (() -> Void)? = nil
    /// Undo for the card on screen (several changes undone together).
    private var undoBlocks: [UUID: () -> Void] = [:]
    /// Undo steps added by perform() for the action that just ran.
    private var pendingUndo: [() -> Void] = []
    private weak var control: AppControl?
    private weak var commands: CommandStore?
    private weak var notes: NoteStore?
    private weak var german: GermanStore?
    /// German practice: the AI is a tutor, German is read in a German voice, answers are heard in German.
    @Published private(set) var germanMode = false
    /// The tutor's LISTEN line: the next answer is in German ("de-DE") or English (nil).
    private var nextListenLocale: String? = nil

    private var app: AppState?
    private var planner: PlannerService?
    private var alarms: AlarmStore?
    private var timer: QuickTimer?
    private var focus: FocusTimer?
    private var weather: WeatherService?
    private var speech: SpeechService?
    private var voice: VoiceService?
    private var ai: AIService?

    private static let historyKey = "assistant.history.v1"

    init() {
        keepListening = UserDefaults.standard.object(forKey: "assistant.keepListening") as? Bool ?? true
        routing = UserDefaults.standard.string(forKey: "assistant.routing") ?? "ai"
        // Keep only today's conversation.
        if let data = UserDefaults.standard.data(forKey: Self.historyKey),
           let saved = try? JSONDecoder().decode([ChatMessage].self, from: data) {
            let today = Calendar.current.startOfDay(for: Date())
            messages = saved.filter { $0.date >= today }
        }
    }

    func configure(app: AppState, planner: PlannerService, alarms: AlarmStore, timer: QuickTimer,
                   focus: FocusTimer, weather: WeatherService, speech: SpeechService, voice: VoiceService,
                   ai: AIService) {
        self.ai = ai
        self.app = app
        self.planner = planner
        self.alarms = alarms
        self.timer = timer
        self.focus = focus
        self.weather = weather
        self.speech = speech
        self.voice = voice
        // When the voice finishes speaking an answer, listen for a follow-up.
        voice.$speaking
            .removeDuplicates()
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .filter { !$0 }
            .sink { [weak self] _ in self?.speakingEnded() }
            .store(in: &cancellables)
    }

    func attach(control: AppControl, commands: CommandStore, notes: NoteStore, german: GermanStore) {
        self.control = control
        self.commands = commands
        self.notes = notes
        self.german = german
    }

    /// "Hey Desk, what's the weather?" → answer it; "Hey Desk" alone → listen.
    func handleWake(_ said: String) {
        app?.screen = .assistant
        if said.split(separator: " ").count >= 2 {
            Haptics.tap()
            handle(said)
        } else {
            listen()
        }
    }

    /// Call right before speaking an answer that may have a follow-up.
    private func armFollowUp() {
        followUpArmed = keepListening
        if keepListening, !(voice?.enabled ?? true) {
            // Replies aren't spoken, so there is no "finished speaking" moment: listen shortly after the answer.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.speakingEnded() }
        }
    }

    private func speakingEnded() {
        guard followUpArmed else { return }
        // Still reading the answer (a short pause between sentences): try again a little later.
        if voice?.isBusy == true {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.speakingEnded() }
            return
        }
        followUpArmed = false
        guard phase == .answered, app?.screen == .assistant, !(speech?.isListening ?? true) else { return }
        listen(followUp: true)
    }

    // MARK: Listening

    func listen(followUp: Bool = false) {
        guard let speech = speech, !speech.isListening else { return }
        followUpArmed = false
        voice?.stop()
        if !followUp { Haptics.tap() }     // before the mic opens
        isFollowUp = followUp
        app?.screen = .assistant
        phase = .listening
        let inGerman = germanMode && nextListenLocale != nil
        speech.hints = inGerman ? (german?.due.map { $0.de } ?? []) : listeningHints()
        speech.start(onFinish: { [weak self] text in
            self?.received(text)
        }, onDenied: { [weak self] in
            self?.phase = .noPermission
        }, noSpeechTimeout: germanMode ? 9 : (followUp ? 5 : 7), locale: inGerman ? nextListenLocale : nil)
    }

    func stopListening() { speech?.stop() }

    /// Your own task and event names plus command words, so the recognizer expects them.
    private func listeningHints() -> [String] {
        var words = ["remind me", "reminder", "alarm", "timer", "calendar", "focus", "pomodoro", "tasks", "to-do list",
                     "tick off", "weather", "tomorrow", "holiday", "holidays", "remember that", "forget",
                     "warm style", "calm style", "futuristic style", "cancel the timer", "what's on",
                     "what's this", "read this", "translate this", "what am I holding"]
        words += (planner?.tasks ?? []).filter { !$0.isCompleted }.map { $0.title }
        words += (planner?.events ?? []).map { $0.title }
        words += (commands?.routines ?? []).filter { $0.enabled }.flatMap { $0.phrases }
        words += (commands?.learned ?? []).prefix(20).map { $0.phrase }
        words += ["take a note", "I have an idea", "read my notes", "practise German"]
        return words
    }

    // MARK: Small talk that ends a conversation ("thanks", "bye", a lone "okay")

    private static let closerWords: Set<String> = ["thanks", "thank", "you", "bye", "goodbye", "good", "night", "later",
        "see", "ya", "no", "nope", "that's", "thats", "all", "it", "for", "now", "nothing", "never", "mind", "else",
        "ok", "okay", "alright", "all right", "cool", "great", "perfect", "fine", "sure", "oh", "ah", "hmm", "um",
        "so", "awesome", "nice", "got", "yes", "yeah", "yep", "much", "very", "a", "lot", "lots", "cheers", "done"]
    private static let strongClosers: Set<String> = ["thanks", "thank", "bye", "goodbye", "later", "cheers",
                                                     "nothing", "mind", "all"]

    /// nil = a real request. Otherwise the reply to say ("" = end quietly).
    private func closingReply(_ text: String) -> String? {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty, words.count <= 8, words.allSatisfy({ Self.closerWords.contains($0) }) else { return nil }
        let strong = words.contains { Self.strongClosers.contains($0) }
        if !strong {
            // A lone "okay" / "yes" / "no" answers the AI's question if it just asked one.
            if let last = messages.last, !last.fromUser, last.text.trimmingCharacters(in: .whitespaces).hasSuffix("?") {
                return nil
            }
            return ""
        }
        if words.contains(where: { ["bye", "goodbye", "later", "night"].contains($0) }) {
            return "Bye! I'm here if you need me."
        }
        return "You're welcome!"
    }

    /// The AI's last reply was a question, so the next thing you say is probably its answer.
    private var aiJustAsked: Bool {
        guard let last = messages.last, !last.fromUser, last.source == "ai" else { return false }
        return last.text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
    }

    private static func soundsLikeGoodbye(_ answer: String) -> Bool {
        let t = answer.lowercased()
        return ["goodbye", "bye!", "bye.", "have a good", "have a great", "have a nice", "you're welcome",
                "talk to you later", "see you"].contains { t.contains($0) } && !t.contains("?")
    }

    func cancelListening() {
        askTask?.cancel()
        speech?.cancel()
        phase = messages.isEmpty ? .idle : .answered
    }

    private func received(_ text: String) {
        let wasFollowUp = isFollowUp
        isFollowUp = false
        if text.isEmpty {
            if wasFollowUp && germanMode {
                endGerman()                          // no answer: finish the lesson with a summary
                return
            }
            if wasFollowUp {
                // Nothing more was said: quietly go back to the answer.
                pendingPrefix = nil
                phase = messages.isEmpty ? .idle : .answered
                return
            }
            heard = ""
            phase = .misheard
            Haptics.error()
            return
        }
        handle(text)
    }

    // MARK: Understanding + acting

    /// Also used by the suggestion chips.
    func handle(_ spoken: String) {
        var text = spoken
        if let prefix = pendingPrefix {
            pendingPrefix = nil
            text = "\(prefix) \(spoken)"
        }
        if confirmation != nil {
            answerConfirmation(text)
            return
        }
        if germanMode {
            if isGermanExit(text) {
                append(ChatMessage(fromUser: true, text: text, source: nil, date: Date()))
                endGerman()
            } else {
                askAI(text)                          // an answer for the tutor
            }
            return
        }
        if let closing = closingReply(text) {
            followUpArmed = false
            card = nil
            if closing.isEmpty {
                phase = messages.isEmpty ? .idle : .answered   // nothing to answer: stop quietly
                return
            }
            append(ChatMessage(fromUser: true, text: text, source: nil, date: Date()))
            append(ChatMessage(fromUser: false, text: closing, source: "offline", date: Date()))
            phase = .answered
            voice?.speak(closing)
            return
        }
        // 1. Your own commands (exact or nearly), then phrases the AI taught the phone: instant, offline.
        if let routine = commands?.matchRoutine(text) {
            runRoutine(routine, said: text)
            return
        }
        if let item = commands?.matchLearned(text) {
            commands?.used(item)
            append(ChatMessage(fromUser: true, text: text, source: nil, date: Date()))
            execute(item.steps, source: "offline", ms: 0, learnFrom: nil, heading: nil)
            return
        }
        let started = Date()
        if let ai = ai, ai.isConfigured, aiJustAsked, !CommandParser.isExplicitCommand(text) {
            askAI(text)                           // "On December 25" after "Which day?"
            return
        }
        let intent = CommandParser.parse(text)
        if case .lookAt(let question) = intent {
            startLook(question, showQuestion: true)
            return
        }
        if intent == .germanPractice {
            startGerman(said: text)
            return
        }
        // 2. AI first: it understands any phrasing and can do several things at once. Clear-cut commands
        //    (timers, alarms, stop, the time) stay instant; if the AI is slow, the phone takes over.
        if routing == "ai", let ai = ai, ai.isConfigured, ai.state != .offline, ai.state != .wrongCode,
           !Self.isClearCut(intent, text: text) {
            askAI(text, fallback: intent, learn: !isSmallTalk(text))
            return
        }
        // A task named in a command that isn't on your list: let the AI work out what you meant.
        switch intent {
        case .completeTask(let name), .deleteTask(let name):
            if planner?.findTask(name) == nil, let ai = ai, ai.isConfigured {
                askAI(text)
                return
            }
        default:
            break
        }
        if intent == .unknown {
            if let ai = ai, ai.isConfigured {
                askAI(text, learn: !isSmallTalk(text))   // a question for the AI on the PC
            } else if Self.looksLikeQuestion(text) {
                answerOffline(text, reason: "The AI on your PC isn't set up yet, so I can't answer questions. Timers, reminders, lists and calendar still work.")
            } else {
                heard = text
                phase = .misheard
                Haptics.error()
                voice?.speak("Sorry, I didn't understand. Try saying it another way.")
            }
            return
        }
        runLocal(intent, text: text, started: started)
    }

    /// The phone's own command (offline). Bulk deletes ask first.
    private func runLocal(_ intent: VoiceIntent, text: String, started: Date) {
        append(ChatMessage(fromUser: true, text: text, source: nil, date: Date()))
        if case .deleteAlarm(_, _, _, let all) = intent, all, let count = alarms?.alarms.count, count > 1 {
            askConfirmation("Delete all \(count) alarms?", source: "offline") { [weak self] in
                guard let self = self else { return }
                self.showLocal(self.perform(intent), intent: intent, started: Date())
            }
            return
        }
        showLocal(perform(intent), intent: intent, started: started)
    }

    private func showLocal(_ reply: (text: String, card: ActionCard?), intent: VoiceIntent, started: Date) {
        handledIn = Date().timeIntervalSince(started)
        undone = false
        append(ChatMessage(fromUser: false, text: reply.text, source: "offline", date: Date()))
        var blocks = takePendingUndo()
        if !blocks.isEmpty, let token = reply.card?.undo, let block = undoBlock(token) { blocks.insert(block, at: 0) }
        card = blocks.isEmpty ? reply.card : withUndo(reply.card, blocks, summary: reply.text)
        phase = .answered
        if card?.undo != nil { Haptics.success() }
        if case .needsTime = intent {
            followUpArmed = true            // "For what time?": always listen for the answer
        } else if case .startFocus = intent {
            followUpArmed = false           // switching to the Focus screen
        } else if pendingPrefix != nil {
            followUpArmed = true            // "Which one?"
        } else {
            armFollowUp()
        }
        voice?.speak(reply.text)
        if case .startFocus = intent {
            // Show the timer after the reply has been spoken.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.app?.screen = .focus }
        }
    }

    /// Commands that can't be misunderstood run instantly on the phone, even in AI-first mode.
    private static func isClearCut(_ intent: VoiceIntent, text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains(" and ") || lower.contains(" then ") { return false }     // several requests: the AI
        let words = lower.split(separator: " ").count
        switch intent {
        case .timer, .alarm: return !looksLikeQuestion(text)
        case .cancelTimer, .stopFocus, .lookAt, .addNote, .readNotes, .germanPractice: return true
        case .time, .date: return words <= 5
        case .deleteAlarm(let hour, _, _, _): return hour != nil
        default: return false
        }
    }

    /// "okay", "thanks", "yes": never learned as a command.
    private func isSmallTalk(_ text: String) -> Bool {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
        return words.isEmpty || words.allSatisfy { Self.closerWords.contains($0) }
    }

    // MARK: Running actions (AI replies, your commands, learned phrases)

    private static let learnableTypes: Set<String> = ["setsetting", "set", "setstyle", "open", "playsound", "stopsound",
        "runroutine", "briefing", "focus", "stopfocus", "canceltimer", "timer", "extendfocus", "skip", "startbreak",
        "snooze", "stopalarm", "completehabit"]

    /// Runs ACTION steps. The question is already in the conversation.
    private func execute(_ lines: [String], source: String, ms: Int, learnFrom: String?, heading: String?,
                         conversational: Bool = true, confirmed: Bool = false) {
        // Bulk or destructive changes ask first ("Delete all 3 alarms?").
        if !confirmed, let control = control,
           let prompt = lines.compactMap({ CommandStore.json($0) }).compactMap({ control.confirmationPrompt($0) }).first {
            askConfirmation(prompt, source: source) { [weak self] in
                self?.execute(lines, source: source, ms: ms, learnFrom: nil, heading: heading,
                              conversational: conversational, confirmed: true)
            }
            return
        }
        // The AI wants to see something: open the camera instead.
        if let look = lines.compactMap({ CommandStore.json($0) }).first(where: { CommandStore.type($0) == "look" }) {
            let question = CommandStore.value(look["question"])
            startLook(question.isEmpty ? "What is this?" : question, showQuestion: false)
            return
        }
        var replies: [(text: String, card: ActionCard?)] = []
        var undos: [() -> Void] = []
        var startsFocus = false
        var opensScreen = false

        func runOne(_ line: String) {
            guard let object = CommandStore.json(line) else { return }
            let type = CommandStore.type(object)
            if type == "focus" { startsFocus = true }
            if type == "open" { opensScreen = true }
            if let result = control?.apply(object) {
                replies.append((text: result.text, card: result.card))
                if let undo = result.undo { undos.append(undo) }
            } else if let intent = Self.intent(fromActionLine: line) {
                let reply = perform(intent)
                replies.append(reply)
                if let token = reply.card?.undo, let block = undoBlock(token) { undos.append(block) }
                undos.append(contentsOf: takePendingUndo())
            } else if let reply = extraAction(line) {
                replies.append(reply)
                undos.append(contentsOf: takePendingUndo())
            }
        }

        for line in lines {
            guard let object = CommandStore.json(line) else { continue }
            if CommandStore.type(object) == "runroutine" {
                let name = CommandStore.value(object["name"])
                if let routine = commands?.routine(named: name) {
                    for step in routine.steps where CommandStore.type(CommandStore.json(step) ?? [:]) != "runroutine" {
                        runOne(step)
                    }
                } else {
                    replies.append((text: "I couldn't find a command called \(name).", card: nil))
                }
                continue
            }
            runOne(line)
        }

        guard !replies.isEmpty else {
            append(ChatMessage(fromUser: false, text: "Sorry, I couldn't do that.", source: source, date: Date()))
            card = nil
            phase = .answered
            voice?.speak("Sorry, I couldn't do that.")
            return
        }
        let text = replies.map { $0.text }.filter { !$0.isEmpty }.joined(separator: " ")
        handledIn = Double(ms) / 1000
        undone = false
        append(ChatMessage(fromUser: false, text: text.isEmpty ? "Done." : text, source: source, date: Date()))
        var shown = replies.last(where: { $0.card != nil })?.card
        if let heading = heading {
            shown = ActionCard(kind: .info, heading: "Your command", title: heading,
                               detail: "\(lines.count) step\(lines.count == 1 ? "" : "s") done", undo: nil, canEdit: true)
        }
        card = undos.isEmpty ? shown.map { Self.removingUndo($0) } : withUndo(shown, undos, summary: text)
        phase = .answered
        if !undos.isEmpty { Haptics.success() }

        // Teach the phone this phrasing, so next time it's instant and works offline.
        if let phrase = learnFrom, phrase.split(separator: " ").count <= 8,
           lines.allSatisfy({ Self.learnableTypes.contains(CommandStore.type(CommandStore.json($0) ?? [:])) }) {
            commands?.learn(phrase, steps: lines)
        }

        if conversational && !startsFocus && !opensScreen {
            armFollowUp()
        } else {
            followUpArmed = false
        }
        voice?.speak(text.isEmpty ? "Done." : text)
        if startsFocus {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.app?.screen = .focus }
        }
    }

    /// Runs one of your commands (said, or the play button in Settings).
    func runRoutine(_ routine: Routine, said: String? = nil) {
        if let said = said {
            append(ChatMessage(fromUser: true, text: said, source: nil, date: Date()))
        }
        execute(routine.steps, source: "offline", ms: 0, learnFrom: nil, heading: routine.name,
                conversational: said != nil)
    }

    /// A command running by itself (its time came, or you sat down).
    func runTriggered(_ routine: Routine) {
        guard !(speech?.isListening ?? false), phase != .thinking else { return }
        execute(routine.steps, source: "offline", ms: 0, learnFrom: nil, heading: routine.name, conversational: false)
    }

    // MARK: Yes / no

    private func askConfirmation(_ prompt: String, source: String, run: @escaping () -> Void) {
        confirmation = prompt
        pendingRun = run
        append(ChatMessage(fromUser: false, text: prompt, source: source, date: Date()))
        card = nil
        phase = .answered
        followUpArmed = true                         // listen for the yes / no
        Haptics.warning()
        voice?.speak(prompt)
        if !(voice?.enabled ?? true) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.speakingEnded() }
        }
    }

    /// Yes (button, voice or a wave over the sensor).
    func confirmPending() {
        guard let run = pendingRun else { return }
        confirmation = nil
        pendingRun = nil
        followUpArmed = false
        if speech?.isListening == true { speech?.cancel() }
        run()
    }

    func declinePending() {
        guard confirmation != nil else { return }
        confirmation = nil
        pendingRun = nil
        followUpArmed = false
        if speech?.isListening == true { speech?.cancel() }
        append(ChatMessage(fromUser: false, text: "Okay, I won't.", source: "offline", date: Date()))
        card = nil
        phase = .answered
        voice?.speak("Okay, I won't.")
    }

    private func answerConfirmation(_ text: String) {
        let t = CommandStore.normalize(text)
        let words = Set(t.split(separator: " ").map(String.init))
        let no = !words.isDisjoint(with: ["no", "nope", "don't", "dont", "cancel", "stop", "keep", "wait"])
            || t.contains("never mind")
        let yes = !words.isDisjoint(with: ["yes", "yeah", "yep", "yup", "sure", "ok", "okay", "confirm", "correct", "definitely"])
            || t.contains("do it") || t.contains("go ahead")
        if yes && !no {
            append(ChatMessage(fromUser: true, text: text, source: nil, date: Date()))
            confirmPending()
        } else if no {
            append(ChatMessage(fromUser: true, text: text, source: nil, date: Date()))
            declinePending()
        } else {
            // Something else entirely: drop the question and treat it as a new request.
            confirmation = nil
            pendingRun = nil
            handle(text)
        }
    }

    // MARK: Undo helpers

    private func takePendingUndo() -> [() -> Void] {
        let blocks = pendingUndo
        pendingUndo = []
        return blocks
    }

    private func undoBlock(_ token: ActionCard.Undo) -> (() -> Void)? {
        switch token {
        case .reminder(let id), .task(let id): return { [weak self] in self?.planner?.deleteReminder(id: id) }
        case .alarm(let id): return { [weak self] in self?.alarms?.remove(id) }
        case .timer: return { [weak self] in self?.timer?.cancel() }
        case .focus: return { [weak self] in self?.focus?.reset() }
        case .custom(let id): return undoBlocks[id]
        }
    }

    private static func removingUndo(_ card: ActionCard) -> ActionCard {
        ActionCard(kind: card.kind, heading: card.heading, title: card.title, detail: card.detail, undo: nil, canEdit: card.canEdit)
    }

    /// One Undo button for everything that just changed.
    private func withUndo(_ card: ActionCard?, _ blocks: [() -> Void], summary: String) -> ActionCard? {
        guard !blocks.isEmpty else { return card }
        let id = UUID()
        undoBlocks = [id: { blocks.reversed().forEach { $0() } }]    // only the card on screen can be undone
        if let c = card {
            return ActionCard(kind: c.kind, heading: c.heading, title: c.title, detail: c.detail, undo: .custom(id), canEdit: c.canEdit)
        }
        let title = summary.count > 60 ? String(summary.prefix(57)) + "…" : summary
        return ActionCard(kind: .info, heading: "Done", title: title, detail: "Tap Undo to change it back",
                          undo: .custom(id), canEdit: false)
    }

    // MARK: Local AI (Desk Bridge on the PC)

    /// Round 0 is your question. Later rounds send lookup RESULTS back to the AI (up to 3 rounds).
    private func askAI(_ question: String, round: Int = 0, fallback: VoiceIntent? = nil, learn: Bool = false,
                       image: Data? = nil, showQuestion: Bool = true) {
        guard let ai = ai, let voice = voice else { return }
        let progress = AskProgress()
        let history = round == 0 ? messages : []
        if round == 0 {
            lastQuestion = question
            thinkingQuestion = question
            thinkingStatus = image == nil ? "" : "Looking at your photo…"
            if showQuestion {
                append(ChatMessage(fromUser: true, text: image == nil ? question : "\(question) (photo)", source: nil, date: Date()))
            }
        }
        phase = .thinking
        undone = false
        let answerID = UUID()
        var started = false
        var fullText = ""            // everything received so far
        var shownCount = 0           // characters already shown and spoken
        var isAction = false         // an ACTION line appeared: stop speaking, carry it out at the end
        let holdBack = 6             // never speak the last 6 characters yet: they might be the start of "ACTION"

        /// Shows and speaks one more piece of a normal (non-action) answer.
        let show: (String) -> Void = { [weak self] piece in
            guard let self = self, !piece.isEmpty else { return }
            if !started {
                started = true
                self.messages.append(ChatMessage(id: answerID, fromUser: false, text: piece, source: "ai", date: Date()))
                self.phase = .answered
                self.card = nil
            } else if let index = self.messages.lastIndex(where: { $0.id == answerID }) {
                let old = self.messages[index]
                self.messages[index] = ChatMessage(id: answerID, fromUser: false, text: old.text + piece,
                                                   source: "ai", date: old.date)
            }
            voice.appendStream(piece)
        }

        voice.beginStream()
        askTask?.cancel()
        // The AI is slow and the phone knows this command: don't keep you waiting.
        if round == 0, let fallback = fallback, fallback != .unknown {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self = self, !progress.received, !progress.done, self.phase == .thinking else { return }
                progress.fellBack = true
                self.askTask?.cancel()
                voice.stop()
                if let last = self.messages.last, last.fromUser, last.text == question { self.messages.removeLast() }
                self.runLocal(fallback, text: question, started: Date())
            }
        }
        askTask = Task { [weak self] in
            do {
                let result = try await ai.ask(question, context: self?.aiContext() ?? [:], history: history,
                                              image: round == 0 ? image : nil) { incoming in
                    progress.received = true
                    fullText += incoming
                    guard !isAction else { return }
                    if fullText.range(of: "ACTION") != nil || fullText.range(of: "QUERY") != nil {
                        isAction = true
                        voice.stop()
                        return
                    }
                    // Tutor lines (WORD / LISTEN) at the end are for the phone, not to be read out.
                    let safe = Self.tutorLinesStart(fullText) ?? (fullText.count - holdBack)
                    guard safe > shownCount else { return }
                    let from = fullText.index(fullText.startIndex, offsetBy: shownCount)
                    let to = fullText.index(fullText.startIndex, offsetBy: safe)
                    shownCount = safe
                    show(String(fullText[from..<to]))
                }
                await MainActor.run {
                    guard let self = self, !progress.fellBack else { return }
                    progress.done = true
                    if result.answer.contains("QUERY") {
                        // The AI needs to look something up: answer its lookups and send the results back.
                        voice.stop()
                        self.messages.removeAll { $0.id == answerID }
                        guard round < 3 else {
                            self.append(ChatMessage(fromUser: false, text: "Sorry, I couldn't finish that.", source: "ai", date: Date()))
                            self.phase = .answered
                            voice.speak("Sorry, I couldn't finish that.")
                            return
                        }
                        let results = self.runQueries(result.answer)
                        let web = Self.webQueries(result.answer)
                        if web.isEmpty {
                            self.askAI(results, round: round + 1)
                        } else {
                            self.searchWeb(web, results: results, round: round + 1)
                        }
                        return
                    }
                    if isAction || result.answer.contains("ACTION") {
                        voice.stop()
                        self.messages.removeAll { $0.id == answerID }     // drop any explanation shown before the action
                        self.performAIAction(result.answer, learnFrom: (round == 0 && learn) ? question : nil, ms: result.ms)
                        return
                    }
                    let visibleEnd = Self.tutorLinesStart(fullText) ?? fullText.count
                    if shownCount < visibleEnd {                          // the held-back tail
                        let from = fullText.index(fullText.startIndex, offsetBy: shownCount)
                        let to = fullText.index(fullText.startIndex, offsetBy: visibleEnd)
                        show(String(fullText[from..<to]))
                        shownCount = visibleEnd
                    }
                    let spokenAnswer = self.applyTutorLines(result.answer)
                    if self.germanMode {
                        self.followUpArmed = true       // German practice: always listen for the answer
                    } else if Self.soundsLikeGoodbye(spokenAnswer) {
                        self.followUpArmed = false      // the AI said goodbye: don't keep listening
                    } else {
                        self.armFollowUp()
                    }
                    voice.endStream()
                    if let index = self.messages.lastIndex(where: { $0.id == answerID }) {
                        self.messages[index] = ChatMessage(id: answerID, fromUser: false, text: spokenAnswer,
                                                           source: "ai", date: self.messages[index].date)
                    } else {
                        self.messages.append(ChatMessage(id: answerID, fromUser: false, text: spokenAnswer,
                                                         source: "ai", date: Date()))
                    }
                    self.handledIn = Double(result.ms) / 1000
                    self.card = ActionCard(kind: .ai, heading: "Local AI", title: ai.model.isEmpty ? "Claude" : ai.model,
                                           detail: "On \(ai.serverName.isEmpty ? "your PC" : ai.serverName)",
                                           undo: nil, canEdit: false)
                    self.phase = .answered
                    self.saveHistory()
                }
            } catch {
                await MainActor.run {
                    guard let self = self, !progress.fellBack else { return }
                    progress.done = true
                    voice.stop()
                    // Drop a half-streamed answer, then show the offline state.
                    let asked = round == 0 ? question : self.lastQuestion
                    self.messages.removeAll { $0.id == answerID }
                    if let last = self.messages.last, last.fromUser, last.text == asked { self.messages.removeLast() }
                    // The phone knows this command: do it here instead.
                    if round == 0, let fallback = fallback, fallback != .unknown {
                        self.runLocal(fallback, text: question, started: Date())
                        return
                    }
                    let reason: String
                    switch error as? AIService.AIError {
                    case .wrongCode?:
                        reason = "The pairing code doesn't match your PC. Check it in Settings, AI and Network."
                    case .server(let message)?:
                        reason = "The AI on your PC had a problem: \(message)"
                    default:
                        reason = "I can't reach the AI on your PC right now, so I can't answer questions. Timers, reminders, lists and calendar still work."
                    }
                    self.answerOffline(asked, reason: reason)
                }
            }
        }
    }

    /// The AI replied with one or more `ACTION {json}` lines: run them.
    private func performAIAction(_ raw: String, learnFrom: String?, ms: Int) {
        let lines = raw.components(separatedBy: .newlines)
            .filter { $0.contains("ACTION") }
            .compactMap { CommandStore.json($0).map { CommandStore.step($0) } }
        execute(lines, source: "ai", ms: ms, learnFrom: learnFrom, heading: nil)
    }

    /// The JSON object on an ACTION / QUERY line.
    private static func json(fromLine line: String) -> [String: Any]? {
        guard let start = line.firstIndex(of: "{"), let end = line.lastIndex(of: "}"), start < end,
              let data = String(line[start...end]).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func localDate(_ text: String, format: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f.date(from: text)
    }

    /// Actions that change existing things (complete, delete, move, style, memory).
    /// "move_reminder", "Move-Reminder" and "movereminder" all become "movereminder".
    private static func normalizedType(_ json: [String: Any]) -> String? {
        guard let raw = json["type"] as? String else { return nil }
        return raw.lowercased().filter { $0.isLetter }
    }

    private func extraAction(_ line: String) -> (text: String, card: ActionCard?)? {
        guard let json = Self.json(fromLine: line), let type = Self.normalizedType(json) else { return nil }
        let title = (json["title"] as? String) ?? ""
        switch type {
        case "completetask":
            return perform(.completeTask(title))
        case "deletetask":
            return perform(.deleteTask(title))
        case "movereminder":
            guard let planner = planner, let task = planner.findTask(title) else { return ("I couldn't find a reminder called \(title).", nil) }
            let oldDue = task.hasDueTime ? task.dueDate : nil
            guard let text = json["due"] as? String, let due = Self.localDate(String(text.prefix(16)), format: "yyyy-MM-dd'T'HH:mm"),
                  planner.reschedule(task, to: due) else { return ("Sorry, I couldn't move \(task.title).", nil) }
            if let oldDue = oldDue {
                pendingUndo.append {
                    if let moved = planner.findTask(task.title) { _ = planner.reschedule(moved, to: oldDue) }
                }
            }
            return ("Moved \(task.title) to \(dayWord(due)) at \(TimeText.time(due)).",
                    ActionCard(kind: .reminder, heading: "Reminder moved", title: task.title,
                               detail: "\(CommandParser.capitalizeFirst(dayWord(due))), \(TimeText.time(due))",
                               undo: nil, canEdit: true))
        case "deletealarm":
            let time = CommandStore.value(json["time"])
            if time.isEmpty || time == "all" {
                return perform(.deleteAlarm(hour: nil, minute: nil, meridiem: nil, all: true))
            }
            let parts = time.split(separator: ":").compactMap { Int($0) }
            guard parts.count >= 2 else { return nil }
            return perform(.deleteAlarm(hour: parts[0], minute: parts[1], meridiem: nil, all: false))
        case "note":
            let text = CommandStore.value(json["text"])
            return perform(.addNote(text.isEmpty ? title : text, idea: CommandStore.value(json["idea"]) == "on"))
        case "deletenote":
            guard let notes = notes, let note = notes.find(CommandStore.value(json["text"])) else {
                return ("I couldn't find that note.", nil)
            }
            notes.delete(note.id)
            pendingUndo.append { notes.restore(note) }
            return ("Deleted the note “\(note.text.prefix(40))”.", nil)
        case "canceltimer":
            return perform(.cancelTimer)
        case "stopfocus":
            return perform(.stopFocus)
        case "setstyle":
            guard let raw = json["style"] as? String, let style = AppStyle(rawValue: raw.lowercased()) else { return nil }
            app?.style = style
            return ("Switched to \(style.displayName).", nil)
        default:
            return nil
        }
    }

    /// Answers the AI's QUERY lines with real data from the phone, as a RESULTS message.
    private func runQueries(_ raw: String) -> String {
        var out: [String] = []
        var statuses: [String] = []
        let now = Date()
        for line in raw.components(separatedBy: .newlines) where line.contains("QUERY") {
            guard let json = Self.json(fromLine: line), let type = Self.normalizedType(json) else { continue }
            switch type {
            case "events":
                statuses.append("Checking your calendar…")
                guard let planner = planner, planner.calendarAccess == .granted else {
                    out.append("events: calendar access is off"); continue
                }
                let day = (json["date"] as? String).flatMap { Self.localDate($0, format: "yyyy-MM-dd") } ?? now
                let events = planner.events(on: day)
                let list = events.map { $0.isAllDay ? "\($0.title) (all day)" : "\($0.title) \(TimeText.time($0.start))–\(TimeText.time($0.end))" }
                out.append("events on \(DateText.long(day)): " + (list.isEmpty ? "none" : list.joined(separator: "; ")))
            case "tasks":
                statuses.append("Checking your tasks…")
                guard let planner = planner, planner.remindersAccess == .granted else {
                    out.append("tasks: reminders access is off"); continue
                }
                let open = planner.tasks.filter { !$0.isCompleted }.map { task -> String in
                    if let due = task.dueDate, task.hasDueTime { return "\(task.title) (due \(dayWord(due)) \(TimeText.time(due)))" }
                    return task.title
                }
                let done = planner.tasks.filter { $0.isCompleted }.map { $0.title }
                out.append("open tasks: " + (open.isEmpty ? "none" : open.joined(separator: "; ")))
                out.append("done today: " + (done.isEmpty ? "none" : done.joined(separator: "; ")))
            case "alarms":
                statuses.append("Checking your alarms…")
                let list = (alarms?.alarms ?? []).map { "\($0.timeText) \($0.daysText)\($0.enabled ? "" : " (off)")" }
                out.append("alarms: " + (list.isEmpty ? "none" : list.joined(separator: "; ")))
            case "weather":
                statuses.append("Checking the forecast…")
                guard let w = weather?.snapshot else { out.append("weather: not available"); continue }
                if (json["day"] as? String) == "tomorrow" {
                    if let high = w.tomorrowHigh, let low = w.tomorrowLow {
                        out.append("weather tomorrow: \(WeatherCode.text(w.tomorrowCode ?? 3)), high \(Int(high.rounded())), low \(Int(low.rounded()))")
                    } else {
                        out.append("weather tomorrow: not available")
                    }
                } else {
                    let rain = w.nextHours(after: now, count: 12).contains { WeatherSnapshot.isRainy($0.code) }
                    out.append("weather today: \(Int(w.temperature.rounded())) degrees, \(WeatherCode.text(w.code)), high \(Int(w.high.rounded())), low \(Int(w.low.rounded())), rain in next 12 h: \(rain ? "likely" : "no")")
                }
            case "web":
                statuses.insert("Searching the web…", at: 0)        // answered by searchWeb()
            case "notes":
                statuses.append("Checking your notes…")
                let list = (notes?.sorted ?? []).prefix(20).map { "\($0.isIdea ? "(idea) " : "")\($0.text) [\(NotesView.when($0.created))]" }
                out.append("notes: " + (list.isEmpty ? "none" : list.joined(separator: "; ")))
            case "focus":
                statuses.append("Checking your focus time…")
                if let focus = focus {
                    let minutes = Int(focus.liveFocusedToday / 60)
                    out.append("focus today: \(minutes / 60) h \(minutes % 60) min, \(focus.sessionsDone) of \(focus.sessionsPerCycle) sessions done")
                }
            default:
                out.append("\(type): unknown lookup")
            }
        }
        thinkingStatus = statuses.first ?? "Thinking it through…"
        return "RESULTS\n" + out.joined(separator: "\n") + "\nNow do what I originally asked: answer briefly, or reply with ACTION lines."
    }

    /// `QUERY {"type": "web", "q": "…"}` lines.
    private static func webQueries(_ raw: String) -> [String] {
        raw.components(separatedBy: .newlines)
            .filter { $0.contains("QUERY") }
            .compactMap { CommandStore.json($0) }
            .filter { CommandStore.type($0) == "web" }
            .map { CommandStore.value($0["q"] ?? $0["query"]) }
            .filter { !$0.isEmpty }
    }

    /// Live web answers: a separate search on the PC (about 20 s), then the AI answers with the results.
    private func searchWeb(_ queries: [String], results: String, round: Int) {
        guard let ai = ai else { return }
        thinkingStatus = "Searching the web…"
        phase = .thinking
        askTask = Task { [weak self] in
            var found: [String] = []
            for query in queries.prefix(2) {
                do {
                    let answer = try await ai.web(query)
                    found.append("web results for \(query): \(answer)")
                } catch {
                    found.append("web search for \(query): failed, tell the user the web search didn't work")
                }
            }
            await MainActor.run {
                guard let self = self, self.phase == .thinking else { return }
                let combined = results.replacingOccurrences(of: "RESULTS\n",
                                                            with: "RESULTS\n" + found.joined(separator: "\n") + "\n")
                self.askAI(combined, round: round)
            }
        }
    }

    // MARK: German practice

    func startGerman(said: String = "Let's practise German.") {
        guard let ai = ai, ai.isConfigured else {
            answerOffline(said, reason: "German practice needs the AI on your PC. Your word of the day still comes with the morning briefing.")
            return
        }
        german?.startSession()
        germanMode = true
        nextListenLocale = nil
        app?.screen = .assistant
        askAI(said)
    }

    func endGerman() {
        guard germanMode else { return }
        germanMode = false
        nextListenLocale = nil
        followUpArmed = false
        let right = german?.sessionRight ?? 0
        let total = german?.sessionTotal ?? 0
        let summary = german?.endSession() ?? "Okay, we'll practise another time."
        append(ChatMessage(fromUser: false, text: summary, source: "offline", date: Date()))
        card = ActionCard(kind: .info, heading: "German practice", title: total > 0 ? "\(right) of \(total) right" : "No answers yet",
                          detail: "\(german?.words.count ?? 0) words · \(german?.streak ?? 0)-day streak", undo: nil, canEdit: true)
        phase = .answered
        voice?.speak(summary)
    }

    private func isGermanExit(_ text: String) -> Bool {
        let words = CommandStore.normalize(text).split(separator: " ").map(String.init)
        guard words.count <= 6 else { return false }
        let exits: Set<String> = ["stop", "stopp", "enough", "finish", "finished", "end", "ende", "done", "quit", "exit",
                                  "bye", "goodbye", "tschüss", "tschuss", "schluss", "aufhören", "aufhoren", "pause"]
        return words.contains { exits.contains($0) } || CommandStore.normalize(text).contains("that's all")
    }

    /// Where the tutor's WORD / LISTEN lines start (they are not read out), as a character offset.
    private static func tutorLinesStart(_ text: String) -> Int? {
        let starts = ["WORD {", "WORD{", "LISTEN de", "LISTEN en", "LISTEN de-", "\nLISTEN"]
            .compactMap { text.range(of: $0)?.lowerBound }
        guard let first = starts.min() else { return nil }
        return text.distance(from: text.startIndex, to: first)
    }

    /// Saves WORD lines to your German words, notes the LISTEN language, and returns the text to show.
    private func applyTutorLines(_ answer: String) -> String {
        guard Self.tutorLinesStart(answer) != nil else { return answer }
        var kept: [String] = []
        for line in answer.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("WORD"), let json = CommandStore.json(trimmed) {
                let de = CommandStore.value(json["de"])
                let en = CommandStore.value(json["en"])
                let correctText = CommandStore.value(json["correct"])
                german?.record(de: de, en: en, correct: correctText.isEmpty ? nil : correctText == "on")
            } else if trimmed.hasPrefix("LISTEN") {
                nextListenLocale = trimmed.lowercased().contains("de") ? "de-DE" : nil
            } else {
                kept.append(line)
            }
        }
        let text = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // The question decides the language of the answer ("…in German?" → listen in German).
        let question = (text.components(separatedBy: "?").dropLast().last ?? "").lowercased()
        if question.contains("in german") || question.contains("auf deutsch") {
            nextListenLocale = "de-DE"
        } else if question.contains("mean") || question.contains("in english") {
            nextListenLocale = nil
        }
        return text
    }

    // MARK: Notes

    /// The "Say a note" button: the next thing you say is saved as a note (or idea).
    func dictateNote(idea: Bool) {
        pendingPrefix = idea ? "new idea" : "take a note"
        listen()
    }

    // MARK: Camera questions

    /// Opens the front camera with a short countdown (AssistantView), then asks the AI about the photo.
    func startLook(_ question: String, showQuestion: Bool) {
        guard let ai = ai, ai.isConfigured else {
            answerOffline(question, reason: "Camera questions need the AI on your PC. Timers, reminders and lists still work.")
            return
        }
        lookQuestion = question
        lookShowsQuestion = showQuestion
        followUpArmed = false
        card = nil
        app?.screen = .assistant
        phase = .looking
        voice?.speak("Hold it up to the screen.")
    }

    func askAboutPhoto(_ photo: Data) {
        guard phase == .looking else { return }
        askAI(lookQuestion, image: photo, showQuestion: lookShowsQuestion)
    }

    func cancelLook(message: String? = nil) {
        guard phase == .looking else { return }
        phase = messages.isEmpty ? .idle : .answered
        if let message = message {
            append(ChatMessage(fromUser: false, text: message, source: "offline", date: Date()))
            voice?.speak(message)
        }
    }

    /// `ACTION {"type": "alarm", "time": "16:30"}` → the matching VoiceIntent.
    private static func intent(fromActionLine line: String) -> VoiceIntent? {
        guard let json = Self.json(fromLine: line), let type = Self.normalizedType(json) else { return nil }
        switch type {
        case "timer":
            if let seconds = (json["seconds"] as? NSNumber)?.intValue, seconds > 0 { return .timer(seconds: seconds) }
        case "alarm":
            if let time = json["time"] as? String {
                let parts = time.split(separator: ":").compactMap { Int($0) }
                if parts.count >= 2, parts[0] < 24, parts[1] < 60 { return .alarm(hour: parts[0], minute: parts[1]) }
            }
        case "reminder":
            let title = (json["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Reminder"
            var due: Date? = nil
            if let text = json["due"] as? String {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "yyyy-MM-dd'T'HH:mm"
                due = f.date(from: String(text.prefix(16)))
            }
            return .reminder(title: title, due: due)
        case "task":
            if let title = json["title"] as? String, !title.isEmpty { return .addTask(title) }
        case "focus":
            return .startFocus(minutes: (json["minutes"] as? NSNumber)?.intValue)
        default:
            break
        }
        return nil
    }

    /// S1: the PC can't be reached (or isn't set up). Offline commands keep working.
    private func answerOffline(_ question: String, reason: String) {
        lastQuestion = question
        append(ChatMessage(fromUser: true, text: question, source: nil, date: Date()))
        append(ChatMessage(fromUser: false, text: reason, source: "offline", date: Date()))
        let configured = ai?.isConfigured ?? false
        let name = (ai?.serverName.isEmpty ?? true) ? "Your PC" : "“\(ai?.serverName ?? "")”"
        var detail = configured ? "\(name) isn't reachable on Wi-Fi." : "Start Desk Bridge on your PC, then enter the pairing code."
        if configured, let seen = ai?.lastSeen { detail += " Last seen \(TimeText.time(seen))." }
        card = ActionCard(kind: .offline, heading: configured ? "Local AI offline" : "Local AI not set up",
                          title: configured ? "PC not found" : "Set up the AI", detail: detail,
                          undo: nil, canEdit: false)
        phase = .answered
        Haptics.error()
        voice?.speak(reason)
    }

    func retryLastQuestion() {
        guard !lastQuestion.isEmpty else { return }
        // Remove the offline exchange, then ask again.
        if let last = messages.last, last.source == "offline", !last.fromUser { messages.removeLast() }
        if let last = messages.last, last.fromUser, last.text == lastQuestion { messages.removeLast() }
        ai?.check()
        let question = lastQuestion
        if let ai = ai, ai.isConfigured { askAI(question) } else { answerOffline(question, reason: "The AI on your PC still isn't set up.") }
    }

    func openAISettings() {
        app?.pendingSettingsSection = "ai"
        app?.screen = .settings
    }

    private func aiContext() -> [String: String] {
        let now = Date()
        var context = ["date": DateText.long(now), "time": TimeText.time(now)]
        if let w = weather?.snapshot {
            if let place = UserDefaults.standard.string(forKey: "location.place") { context["location"] = place }
            context["weather"] = "\(Int(w.temperature.rounded())) degrees, \(WeatherCode.text(w.code).lowercased()), high \(Int(w.high.rounded())), low \(Int(w.low.rounded()))"
        }
        let iso = DateFormatter()
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.dateFormat = "yyyy-MM-dd'T'HH:mm"
        context["now"] = iso.string(from: now)
        if let app = app {
            var screen = app.screen.title
            if app.screen == .focus, let focus = focus {
                screen += " (focus \(focus.state == .running ? "running" : "not running"), \(Int(focus.focusLength / 60)) min sessions)"
            }
            context["screen"] = screen
        }
        if let control = control {
            context["settings"] = control.summary
            context["sounds"] = control.soundNames
            let habitNames = (control.habits?.habits ?? []).map { $0.name }
            if !habitNames.isEmpty { context["habits"] = habitNames.joined(separator: ", ") }
        }
        if germanMode, let german = german {
            context["mode"] = "German practice"
            context["german"] = german.contextSummary
        }
        if let notes = notes, !notes.notes.isEmpty {
            context["notes"] = "\(notes.notes.count) saved (use QUERY notes to read them)"
        }
        if let commands = commands {
            if !commands.memory.isEmpty { context["memory"] = commands.memory.joined(separator: " | ") }
            let mine = commands.routines.filter { $0.enabled }
                .map { "\($0.name) (say: \($0.phrases.joined(separator: " / ")))" }
            if !mine.isEmpty { context["my commands"] = mine.joined(separator: "; ") }
        }
        if ai?.shareDay ?? false, let planner = planner {
            let events = planner.events.filter { $0.isAllDay || $0.end > now }.prefix(6)
                .map { $0.isAllDay ? "\($0.title) (all day)" : "\($0.title) at \(TimeText.time($0.start))" }
            context["today's events"] = events.isEmpty ? "none" : events.joined(separator: ", ")
            let open = planner.tasks.filter { !$0.isCompleted }.prefix(8).map { $0.title }
            context["open tasks"] = open.isEmpty ? "none" : open.joined(separator: ", ")
        }
        return context
    }

    private static func looksLikeQuestion(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("?") { return true }
        let starts = ["what", "why", "how", "who", "when", "where", "which", "can ", "could ", "should ", "would ",
                      "is ", "are ", "do ", "does ", "did ", "tell me", "explain", "give me", "suggest", "write"]
        return starts.contains { t.hasPrefix($0) }
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

        case .tasks:
            return tasksReply()

        case .lookAt:
            return ("Camera questions need the AI on your PC.", nil)

        case .germanPractice:
            return ("German practice needs the AI on your PC.", nil)

        case .addNote(let text, let idea):
            guard let notes = notes else { return ("Notes aren't available.", nil) }
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                pendingPrefix = idea ? "new idea" : "take a note"
                return (idea ? "Go ahead, what's your idea?" : "Go ahead, I'm listening.", nil)
            }
            let note = notes.add(text, idea: idea)
            pendingUndo.append { notes.delete(note.id) }
            return (idea ? "Saved your idea." : "Noted.",
                    ActionCard(kind: .info, heading: idea ? "Idea saved" : "Note saved", title: note.text,
                               detail: "In Notes", undo: nil, canEdit: true))

        case .readNotes(let ideas):
            guard let notes = notes else { return ("Notes aren't available.", nil) }
            let list = notes.sorted.filter { note in ideas.map { note.isIdea == $0 } ?? true }
            let kind = ideas == true ? "ideas" : "notes"
            guard !list.isEmpty else { return ("You don't have any \(kind) yet.", nil) }
            let latest = list.prefix(3).map { $0.text }
            let intro = list.count == 1 ? "Your only \(kind.dropLast()) is:" : "Your latest \(kind) are:"
            return ("\(intro) \(latest.joined(separator: ". ")).",
                    ActionCard(kind: .info, heading: "Notes", title: latest[0], detail: "\(list.count) in Notes",
                               undo: nil, canEdit: true))

        case .completeTask(let name):
            guard let planner = planner, planner.remindersAccess == .granted else {
                return ("I can't see your tasks. Allow Reminders access in Settings.", nil)
            }
            guard let task = planner.findTask(name) else { return ("I couldn't find a task called \(name).", nil) }
            if task.isCompleted { return ("\(task.title) is already done.", nil) }
            planner.setCompleted(task, true)
            pendingUndo.append { planner.setCompleted(task, false) }
            let left = planner.tasks.filter { !$0.isCompleted }.count
            return ("Ticked off \(task.title).\(left == 0 ? " That's everything!" : "")",
                    ActionCard(kind: .task, heading: "Task done", title: task.title,
                               detail: left == 0 ? "All done" : "\(left) left", undo: nil, canEdit: true))

        case .deleteTask(let name):
            guard let planner = planner, planner.remindersAccess == .granted else {
                return ("I can't see your tasks. Allow Reminders access in Settings.", nil)
            }
            guard let task = planner.findTask(name) else { return ("I couldn't find a task called \(name).", nil) }
            planner.deleteReminder(id: task.id)
            let title = task.title
            let due = task.hasDueTime ? task.dueDate : nil
            pendingUndo.append { _ = planner.addReminder(title: title, due: due, byVoice: true) }
            return ("Deleted \(task.title).",
                    ActionCard(kind: .task, heading: "Task deleted", title: task.title,
                               detail: planner.selectedListTitle, undo: nil, canEdit: false))

        case .deleteAlarm(let hour, let minute, let meridiem, let all):
            let before = alarms?.alarms ?? []
            let reply = deleteAlarmsReply(hour: hour, minute: minute, meridiem: meridiem, all: all)
            if let alarms = alarms {
                let removed = before.filter { old in !alarms.alarms.contains { $0.id == old.id } }
                if !removed.isEmpty { pendingUndo.append { alarms.alarms.append(contentsOf: removed) } }
            }
            return reply

        case .setStyle(let raw):
            guard let style = AppStyle(rawValue: raw) else { return ("Sorry, I don't know that style.", nil) }
            if let app = app {
                let old = app.style
                pendingUndo.append { app.style = old }
            }
            app?.style = style
            return ("Switched to \(style.displayName).", nil)

        case .needsTime(let kind):
            if kind == "timer" {
                pendingPrefix = "set a timer for"
                return ("For how long?", nil)
            }
            pendingPrefix = "set an alarm for"
            return ("For what time?", nil)

        case .unknown:
            return ("Sorry, I didn't understand.", nil)
        }
    }

    private func deleteAlarmsReply(hour: Int?, minute: Int?, meridiem: String?, all: Bool) -> (text: String, card: ActionCard?) {
            guard let alarms = alarms else { return ("Alarms aren't available.", nil) }
            if alarms.alarms.isEmpty { return ("You don't have any alarms.", nil) }
            if all {
                let n = alarms.removeAlarms(hour: nil, minute: nil)
                return (n == 1 ? "Deleted your alarm." : "Deleted all \(n) alarms.", nil)
            }
            guard let hour = hour, let minute = minute else {
                if alarms.alarms.count == 1, let only = alarms.alarms.first {
                    let label = only.timeText
                    alarms.removeAlarms(hour: only.hour, minute: only.minute)
                    return ("Deleted the \(label) alarm.", nil)
                }
                let times = alarms.alarms.map { $0.timeText }
                pendingPrefix = "delete the alarm at"
                return ("Which one? You have alarms at \(times.dropLast().joined(separator: ", ")) and \(times.last ?? "").", nil)
            }
            // "4:30" matches a 4:30 AM or 4:30 PM alarm unless am/pm was said.
            let matching = alarms.alarms.filter { alarm in
                guard alarm.minute == minute else { return false }
                switch meridiem {
                case "am"?: return alarm.hour == hour % 12
                case "pm"?: return alarm.hour == hour % 12 + 12
                default: return alarm.hour == hour || (hour <= 12 && alarm.hour % 12 == hour % 12)
                }
            }
            guard !matching.isEmpty else {
                let label = Alarm(hour: hour, minute: minute).timeText
                return ("I couldn't find an alarm at \(label).", nil)
            }
            let label = matching[0].timeText
            for alarm in matching { alarms.removeAlarms(hour: alarm.hour, minute: alarm.minute) }
            return ("Deleted the \(label) alarm.", nil)
    }

    private func tasksReply() -> (text: String, card: ActionCard?) {
        guard let planner = planner else { return ("Tasks aren't available.", nil) }
        if planner.remindersAccess == .denied { return ("I can't see your tasks. Allow Reminders access in Settings.", nil) }
        let open = planner.tasks.filter { !$0.isCompleted }
        guard !open.isEmpty else {
            return ("You have no open tasks. Nice work!",
                    ActionCard(kind: .task, heading: "Tasks", title: "All done", detail: planner.selectedListTitle,
                               undo: nil, canEdit: true))
        }
        let names = open.prefix(3).map { $0.title }
        var list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        if open.count > 3 { list += ", plus \(open.count - 3) more" }
        let count = open.count == 1 ? "1 open task" : "\(open.count) open tasks"
        return ("You have \(count): \(list).",
                ActionCard(kind: .task, heading: "Tasks · \(count)", title: open[0].title,
                           detail: planner.selectedListTitle, undo: nil, canEdit: true))
    }

    private func agenda(offset: Int) -> (text: String, card: ActionCard?) {
        guard let planner = planner else { return ("The calendar isn't available.", nil) }
        if planner.calendarAccess == .denied { return ("I can't see your calendar. Allow access in Settings.", nil) }
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: offset, to: Date()) ?? Date()
        let dayName: String = {
            switch offset {
            case 0: return "today"
            case 1: return "tomorrow"
            case 2...6:
                let f = DateFormatter()
                f.dateFormat = "EEEE"
                return "on " + f.string(from: day)
            default: return "on " + DateText.long(day)
            }
        }()
        var events = planner.events(on: day)
        if offset == 0 { events = events.filter { $0.isAllDay || $0.end > Date() } }
        guard !events.isEmpty else {
            return (offset == 0 ? "Nothing else on your calendar today." : "Your calendar is clear \(dayName).",
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
        return ("You have \(count) \(offset == 0 ? "left today" : dayName): \(list).",
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
        case .custom(let id):
            undoBlocks[id]?()
            undoBlocks[id] = nil
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
        case .info where card.heading == "Note saved" || card.heading == "Idea saved" || card.heading == "Notes":
            app?.screen = .notes
        case .info where card.heading == "German practice":
            app?.pendingSettingsSection = "german"
            app?.screen = .settings
        case .info where card.heading.hasPrefix("Command") || card.heading == "Your command":
            app?.pendingSettingsSection = "commands"
            app?.screen = .settings
        default:
            break
        }
    }

    func clearHistory() {
        messages = []
        card = nil
        confirmation = nil
        pendingRun = nil
        germanMode = false
        nextListenLocale = nil
        phase = .idle
        UserDefaults.standard.removeObject(forKey: Self.historyKey)
        ai?.reset()                                   // fresh conversation on the PC too
    }

    private func append(_ message: ChatMessage) {
        messages.append(message)
        saveHistory()
    }

    private func saveHistory() {
        if messages.count > 40 { messages.removeFirst(messages.count - 40) }
        if let data = try? JSONEncoder().encode(messages) {
            UserDefaults.standard.set(data, forKey: Self.historyKey)
        }
    }
}
