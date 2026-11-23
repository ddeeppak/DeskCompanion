import Foundation

/// What a spoken sentence asks for. Everything here works offline.
enum VoiceIntent: Equatable {
    case timer(seconds: Int)
    case cancelTimer
    case alarm(hour: Int, minute: Int)
    case reminder(title: String, due: Date?)
    case addTask(String)
    case agenda(dayOffset: Int)
    case weather(dayOffset: Int, rainQuestion: Bool)
    case time
    case date
    case startFocus(minutes: Int?)
    case stopFocus
    case help
    case tasks
    /// "tick off call mom", "the bank is done" (matched to a real task by name later)
    case completeTask(String)
    /// "remove the bank", "delete the dentist reminder"
    case deleteTask(String)
    /// "delete my 4:30 alarm" (hour/minute nil = the only one, or ask), all = every alarm
    case deleteAlarm(hour: Int?, minute: Int?, meridiem: String?, all: Bool)
    /// "switch to warm style" (calm, futuristic or warm)
    case setStyle(String)
    /// "What's this?", "Read this", "Translate this": take a photo and ask the AI
    case lookAt(String)
    /// "Note: call the plumber", "I have an idea: a plant shelf" ("" = ask for it)
    case addNote(String, idea: Bool)
    /// "Read my notes", "what are my ideas" (nil = both)
    case readNotes(ideas: Bool?)
    /// "Let's practise German", "German lesson", "quiz me in German"
    case germanPractice
    /// Alarm or timer asked without a time ("set an alarm"): ask for it, then listen.
    case needsTime(kind: String)
    case unknown
}

/// Turns recognised speech into a VoiceIntent with simple, predictable rules.
enum CommandParser {

    static func parse(_ raw: String, now: Date = Date()) -> VoiceIntent {
        let t = normalize(raw)
        if t.isEmpty { return .unknown }
        let tomorrow = t.contains("tomorrow")

        if contains(t, ["cancel the timer", "cancel timer", "stop the timer", "stop timer", "delete the timer"]) {
            return .cancelTimer
        }
        if let note = noteCommand(t) {
            if case .addNote(let text, let idea) = note { return .addNote(noteText(text, raw: raw), idea: idea) }
            return note
        }
        if isGermanPractice(t) { return .germanPractice }
        if isLookRequest(t) { return .lookAt(capitalizeFirst(raw.trimmingCharacters(in: .whitespacesAndNewlines))) }
        if let edit = editCommand(t) { return edit }
        if t.contains("timer") || t.hasPrefix("count down") {
            let seconds = durationSeconds(t)
            return seconds > 0 ? .timer(seconds: seconds) : .needsTime(kind: "timer")
        }
        if contains(t, ["remind me", "reminder"]) {
            return reminder(t, now: now)
        }
        if t.contains("alarm") || t.contains("wake me") {
            // "alarm at 6:30", "alarm to 430", "alarm 7", "wake me at 6 30 am"
            guard let clock = clockTime(t) ?? bareTime(t),
                  let date = resolve(clock, dayOffset: 0, tonight: t.contains("tonight"),
                                     preferMorning: (t.contains("wake me") || t.contains("morning")) && !t.contains("pm"),
                                     now: now) else {
                return .needsTime(kind: "alarm")
            }
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            return .alarm(hour: parts.hour ?? 7, minute: parts.minute ?? 0)
        }
        if let item = listItem(t) { return .addTask(item) }
        if contains(t, ["task", "to do", "todo", "my list", "need to do", "have to do", "my reminders", "pending"]) {
            return .tasks
        }
        if contains(t, ["what can you do", "help me", "what do you do"]) || t == "help" { return .help }
        if contains(t, ["stop focus", "pause focus", "end focus", "stop the focus", "end the focus", "stop pomodoro"]) {
            return .stopFocus
        }
        if (contains(t, ["focus", "pomodoro"]) && contains(t, ["start", "begin", "let's", "lets", "time to"]))
            || t.hasPrefix("focus") || t.hasPrefix("pomodoro") {
            let minutes = durationSeconds(t) / 60
            return .startFocus(minutes: minutes > 0 ? minutes : nil)
        }
        if contains(t, ["weather", "temperature", "rain", "umbrella", "how hot", "how cold", "forecast", "sunny"]) {
            return .weather(dayOffset: tomorrow ? 1 : 0, rainQuestion: contains(t, ["rain", "umbrella"]))
        }
        let day = dayReference(t, now: now)
        if contains(t, ["what's on", "what is on", "schedule", "calendar", "agenda", "events", "meetings", "my day", "plans", "anything on"]) {
            return .agenda(dayOffset: day?.offset ?? (tomorrow ? 1 : 0))
        }
        if let day = day {
            // "anything on December 25?", "do I have something on Thursday", or just "on Thursday"
            let words = t.split(separator: " ").count
            if contains(t, ["anything", "something", "do i have", "is there", "holiday", "busy", "free", "what about", "how about"])
                || words <= 4 {
                return .agenda(dayOffset: day.offset)
            }
        }
        if contains(t, ["what time", "the time", "time is it"]) { return .time }
        if contains(t, ["what day", "the date", "what's the date", "today's date", "which day"]) { return .date }
        return .unknown
    }

    // MARK: - Normalising

    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19
    ]
    private static let tens: [String: Int] = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50]

    /// Lower case, no punctuation (except ':' and '), number words → digits ("six thirty" → "6 30").
    static func normalize(_ raw: String) -> String {
        var t = raw.lowercased()
        t = t.replacingOccurrences(of: "a.m.", with: "am")
        t = t.replacingOccurrences(of: "p.m.", with: "pm")
        t = t.replacingOccurrences(of: "\u{2019}", with: "'")
        t = t.replacingOccurrences(of: "o'clock", with: " ")
        t = String(t.map { ch -> Character in
            (ch.isLetter || ch.isNumber || ch == " " || ch == ":" || ch == "'") ? ch : " "
        })
        let words = t.split(separator: " ").map(String.init)
        var out: [String] = []
        var i = 0
        while i < words.count {
            let word = words[i]
            if let ten = tens[word] {
                if i + 1 < words.count, let unit = units[words[i + 1]], unit > 0, unit < 10 {
                    out.append(String(ten + unit))
                    i += 2
                    continue
                }
                out.append(String(ten))
            } else if let unit = units[word] {
                out.append(String(unit))
            } else {
                out.append(word)
            }
            i += 1
        }
        return out.joined(separator: " ")
    }

    private static func contains(_ text: String, _ phrases: [String]) -> Bool {
        phrases.contains { text.contains($0) }
    }

    // MARK: - Durations ("10 minutes", "an hour", "half an hour", "1 hour 30 minutes")

    static func durationSeconds(_ t: String) -> Int {
        var total = 0
        for match in matches(#"(\d+)\s*(?:hours?|hrs?)\b"#, in: t) { total += (Int(match[1]) ?? 0) * 3600 }
        for match in matches(#"(\d+)\s*(?:minutes?|mins?)\b"#, in: t) { total += (Int(match[1]) ?? 0) * 60 }
        for match in matches(#"(\d+)\s*(?:seconds?|secs?)\b"#, in: t) { total += Int(match[1]) ?? 0 }
        if !matches(#"(\d+) and a half hours?"#, in: t).isEmpty { total += 1800 }
        if t.contains("half an hour") || t.contains("half hour") { total += 1800 }
        if !matches(#"\b(?:an|a)\s+hour\b"#, in: t).isEmpty && matches(#"(\d+)\s*(?:hours?|hrs?)\b"#, in: t).isEmpty {
            total += 3600
        }
        if !matches(#"\b(?:a|an)\s+minute\b"#, in: t).isEmpty { total += 60 }
        return total
    }

    // MARK: - Clock times ("at 6", "at 6:30 pm", "for 7 am", "6 30", "noon")

    struct ClockTime {
        let hour: Int
        let minute: Int
        let meridiem: String?
        let range: Range<String.Index>
    }

    static func clockTime(_ t: String) -> ClockTime? {
        let patterns = [
            #"\b(?:at|for|by|to|on)\s+(\d{1,2})(?::(\d{2})|\s(\d{2}))?\s*(am|pm)?\b"#,
            #"\b(?:at|for|by|to|on)\s+(\d{1,2})(\d{2})()\s*(am|pm)?\b"#,
            #"\b(\d{1,2}):(\d{2})()\s*(am|pm)?\b"#,
            #"\b(\d{1,2})()()\s*(am|pm)\b"#
        ]
        for pattern in patterns {
            guard let found = firstMatch(pattern, in: t) else { continue }
            let groups = found.0
            let range = found.1
            guard let hour = Int(groups[1]), hour <= 23 else { continue }
            let minuteText = !groups[2].isEmpty ? groups[2] : groups[3]
            let minute = Int(minuteText) ?? 0
            guard minute < 60 else { continue }
            let meridiem = groups[4].isEmpty ? nil : groups[4]
            return ClockTime(hour: hour, minute: minute, meridiem: meridiem, range: range)
        }
        for (word, hour) in [("noon", 12), ("midday", 12), ("midnight", 0)] {
            if let range = t.range(of: word) {
                return ClockTime(hour: hour, minute: 0, meridiem: hour == 0 ? "am" : "pm", range: range)
            }
        }
        return nil
    }

    /// Any time-looking number, for alarms: "7", "430", "1630", "6 30", "6:30 pm".
    static func bareTime(_ t: String) -> ClockTime? {
        let patterns = [
            #"\b(\d{1,2}):(\d{2})()\s*(am|pm)?\b"#,
            #"\b(\d{1,2})(\d{2})()\s*(am|pm)?\b"#,
            #"\b(\d{1,2})\s(\d{2})()\s*(am|pm)?\b"#,
            #"\b(\d{1,2})()()\s*(am|pm)?\b"#
        ]
        for pattern in patterns {
            guard let found = firstMatch(pattern, in: t) else { continue }
            let groups = found.0
            guard let hour = Int(groups[1]), hour <= 23 else { continue }
            let minute = Int(groups[2]) ?? 0
            guard minute < 60 else { continue }
            return ClockTime(hour: hour, minute: minute, meridiem: groups[4].isEmpty ? nil : groups[4], range: found.1)
        }
        return nil
    }

    /// Picks the actual date: "6" means the next 6 o'clock coming up (alarms prefer the morning).
    static func resolve(_ clock: ClockTime, dayOffset: Int, tonight: Bool, preferMorning: Bool, now: Date) -> Date? {
        let calendar = Calendar.current
        guard let base = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now)) else { return nil }
        func at(_ hour: Int) -> Date? {
            calendar.date(bySettingHour: hour, minute: clock.minute, second: 0, of: base)
        }
        func future(_ date: Date?) -> Date? {
            guard let date = date else { return nil }
            if dayOffset == 0 && date <= now { return calendar.date(byAdding: .day, value: 1, to: date) }
            return date
        }

        var hour = clock.hour
        if let meridiem = clock.meridiem {
            if meridiem == "pm" && hour < 12 { hour += 12 }
            if meridiem == "am" && hour == 12 { hour = 0 }
            return future(at(hour))
        }
        if hour == 0 || hour > 12 { return future(at(hour)) }               // 24-hour time
        if tonight { return future(at(hour < 12 ? hour + 12 : hour)) }
        if preferMorning { return future(at(hour == 12 ? 12 : hour)) }       // alarms: "6" = 6 AM
        if dayOffset > 0 {
            // Tomorrow without am/pm: 7–11 → morning, 12 → noon, 1–6 → afternoon/evening.
            return at(hour >= 7 && hour <= 11 ? hour : (hour == 12 ? 12 : hour + 12))
        }
        let candidates = [hour % 12, hour % 12 + 12].compactMap { at($0) }
        if let next = candidates.first(where: { $0 > now }) { return next }
        return future(candidates.first)
    }

    // MARK: - Reminders ("remind me at 6 to call mom", "remind me to stretch in 20 minutes")

    private static func reminder(_ t: String, now: Date) -> VoiceIntent {
        var text = t
        var due: Date? = nil
        let named = dayReference(text, now: now)
        let dayOffset = named?.offset ?? (text.contains("tomorrow") ? 1 : 0)
        if let named = named { text.removeSubrange(named.range) }
        let tonight = text.contains("tonight")

        if let clock = clockTime(text) {
            due = resolve(clock, dayOffset: dayOffset, tonight: tonight, preferMorning: false, now: now)
            text.removeSubrange(clock.range)
        } else if let found = firstMatch(#"\b(?:in|within|after)\s+(\d+|an|a|one|half an)\s*(hours?|hrs?|minutes?|mins?)\b"#, in: text) {
            let groups = found.0
            let range = found.1
            let amount: Int
            switch groups[1] {
            case "an", "a", "one": amount = 1
            case "half an": amount = 0
            default: amount = Int(groups[1]) ?? 0
            }
            let isHours = groups[2].hasPrefix("h")
            let seconds = groups[1] == "half an" ? 1800 : amount * (isHours ? 3600 : 60)
            if seconds > 0 { due = now.addingTimeInterval(TimeInterval(seconds)) }
            text.removeSubrange(range)
        } else if dayOffset >= 1 {
            // "remind me tomorrow / on Friday to …" without a time: 9 AM that day.
            due = resolve(ClockTime(hour: 9, minute: 0, meridiem: "am", range: text.startIndex..<text.startIndex),
                          dayOffset: dayOffset, tonight: false, preferMorning: true, now: now)
        }

        for phrase in ["set a reminder", "create a reminder", "add a reminder", "set reminder", "remind me", "reminder",
                       "tomorrow", "tonight", "today", "please"] {
            text = text.replacingOccurrences(of: phrase, with: " ")
        }
        var title = text.split(separator: " ").joined(separator: " ")
        for lead in ["to ", "that ", "about ", "for ", "i need to ", "i have to ", "i'm going to ", "i am going to ",
                     "im going to ", "i want to ", "i should ", "i must ", "i will ", "i'll ", "i've got to ",
                     "i gotta ", "we need to ", "go to "] where title.hasPrefix(lead) {
            title = String(title.dropFirst(lead.count))
        }
        for tail in [" to", " at", " in", " for"] where title.hasSuffix(tail) {
            title = String(title.dropLast(tail.count))
        }
        title = capitalizeFirst(title.trimmingCharacters(in: .whitespaces))
        return .reminder(title: title.isEmpty ? "Reminder" : title, due: due)
    }

    // MARK: - Lists ("add milk to my list", "put eggs on the shopping list", "new task call the bank")

    private static func listItem(_ t: String) -> String? {
        if let found = firstMatch(#"^(?:please\s+)?(?:add|put)\s+(.+?)\s+(?:to|on|in)\s+(?:my|the)?\s*(?:[a-z]+\s+)?(?:list|tasks|to do|todo)$"#, in: t) {
            return capitalizeFirst(found.0[1])
        }
        if let found = firstMatch(#"^(?:please\s+)?(?:add|new task|create a task|add a task)\s+(.+)$"#, in: t) {
            return capitalizeFirst(found.0[1])
        }
        return nil
    }

    // MARK: - Changing things ("remove the bank", "tick off call mom", "delete my 4:30 alarm", "warm style")

    private static let polite = #"^(?:please\s+|okay\s+|ok\s+|now\s+|and\s+|also\s+)*(?:can you\s+|could you\s+|would you\s+|will you\s+|i want to\s+|i'd like to\s+|let's\s+|lets\s+)?"#

    private static func editCommand(_ t: String) -> VoiceIntent? {
        // Style
        if let found = firstMatch(polite + #"(?:switch|change|set|use|go|turn|make it|make)\b.*?\b(calm|minimal|futuristic|future|warm|cozy|cosy)\b"#, in: t),
           contains(t, ["style", "look", "theme", "mode", "make it", "design"]) {
            switch found.0[1] {
            case "calm", "minimal": return .setStyle("calm")
            case "futuristic", "future": return .setStyle("futuristic")
            default: return .setStyle("warm")
            }
        }
        // Delete alarms (before "alarm" creates one)
        if t.contains("alarm"),
           firstMatch(polite + #"(?:delete|remove|cancel|clear|turn off|switch off|disable|get rid of|drop)\b"#, in: t) != nil {
            let all = contains(t, ["all", "every", "alarms"])
            let clock = clockTime(t) ?? bareTime(t)
            return .deleteAlarm(hour: all ? nil : clock?.hour, minute: all ? nil : clock?.minute,
                                meridiem: all ? nil : clock?.meridiem, all: all)
        }
        // Complete
        var target: String? = nil
        var complete = false
        if let found = firstMatch(polite + #"(?:tick off|tick|check off|cross off|complete|finish|i finished|i've finished|i have finished|i completed|i've completed|i have completed|i did|i've done|i have done|done with|i'm done with|im done with)\s+(.+?)(?:\s+(?:as\s+)?(?:done|complete|completed|finished))?(?:\s+off)?$"#, in: t) {
            target = found.0[1]; complete = true
        } else if let found = firstMatch(polite + #"mark\s+(.+?)\s+(?:as\s+)?(?:done|complete|completed|finished)$"#, in: t) {
            target = found.0[1]; complete = true
        } else if let found = firstMatch(#"^(?:the\s+|my\s+)?(.+?)\s+(?:is|are|was)\s+(?:done|finished|complete|completed)$"#, in: t) {
            target = found.0[1]; complete = true
        } else if let found = firstMatch(polite + #"(?:remove|delete|drop|erase|scratch|get rid of|cancel)\s+(.+?)(?:\s+(?:from|off)\s+(?:my|the)\s+(?:[a-z]+\s+)?(?:list|tasks|reminders))?$"#, in: t) {
            target = found.0[1]
        } else if let found = firstMatch(polite + #"take\s+(.+?)\s+off\s+(?:my|the)\s+(?:[a-z]+\s+)?(?:list|tasks|reminders)$"#, in: t) {
            target = found.0[1]
        }
        guard var name = target else { return nil }
        if contains(name, ["timer"]) { return complete ? nil : .cancelTimer }
        if contains(name, ["focus", "pomodoro"]) { return complete ? nil : .stopFocus }
        for lead in ["the ", "my ", "that ", "this ", "a ", "an ", "task ", "reminder ", "item "] where name.hasPrefix(lead) {
            name = String(name.dropFirst(lead.count))
        }
        for tail in [" task", " reminder", " item", " one", " off", " from my list", " from the list", " please"] where name.hasSuffix(tail) {
            name = String(name.dropLast(tail.count))
        }
        name = name.trimmingCharacters(in: .whitespaces)
        // Vague ("remove it", "delete everything"): let the AI work out what you mean.
        if name.isEmpty || ["it", "that", "this", "them", "everything", "all", "all of them", "the last one"].contains(name) {
            return nil
        }
        return complete ? .completeTask(name) : .deleteTask(name)
    }

    // MARK: - Notes and German

    private static func noteCommand(_ t: String) -> VoiceIntent? {
        let lead = #"^(?:please |okay |ok |hey )?(?:can you |could you )?"#
        if let found = firstMatch(lead + #"(?:i have|i've got|i got|here's|heres) an idea(?:[: ,]+(?:that )?(.*))?$"#, in: t) {
            return .addNote(capitalizeFirst(found.0[1]), idea: true)
        }
        if let found = firstMatch(lead + #"(?:new|save an|save this|add an|add this|another) idea(?:[: ]+(.*))?$"#, in: t) {
            return .addNote(capitalizeFirst(found.0[1]), idea: true)
        }
        if let found = firstMatch(lead + #"(?:take|make|add|save|write) (?:a |an |this |another )?note(?: that| saying| to say)?(?:[: ]+(.*))?$"#, in: t) {
            return .addNote(capitalizeFirst(found.0[1]), idea: false)
        }
        if let found = firstMatch(#"^(?:note|note down|jot down|write down|note that)[: ]+(.+)$"#, in: t) {
            return .addNote(capitalizeFirst(found.0[1]), idea: false)
        }
        if let found = firstMatch(#"\b(?:read|what are|what's|whats|show|tell me|list) (?:me )?(?:all )?(?:my |the )?(?:last |latest |recent )?(notes|ideas|note|idea)\b"#, in: t) {
            let word = found.0[1]
            return .readNotes(ideas: word.hasPrefix("idea") ? true : nil)
        }
        return nil
    }

    /// The note in your own words and capitals ("coorg" → "Coorg"), without "that …" or "… save it".
    private static func noteText(_ found: String, raw: String) -> String {
        guard !found.isEmpty else { return "" }
        let count = found.split(separator: " ").count
        let rawWords = raw.components(separatedBy: CharacterSet.whitespaces)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ",:;.!?\"“”")) }
            .filter { !$0.isEmpty }
        var words = rawWords.count >= count ? Array(rawWords.suffix(count)) : found.split(separator: " ").map(String.init)
        while let first = words.first, ["that", "to", "about"].contains(first.lowercased()), words.count > 1 {
            words.removeFirst()
        }
        var text = words.joined(separator: " ")
        for tail in [" save it", " please", " for me", " thanks", " thank you", " save that"] {
            if text.lowercased().hasSuffix(tail) { text = String(text.dropLast(tail.count)) }
        }
        return capitalizeFirst(text.trimmingCharacters(in: .whitespaces))
    }

    static func isGermanPractice(_ t: String) -> Bool {
        guard t.contains("german") else { return false }
        let pattern = #"\b(?:practi[cs]e|practicing|practising|learn|learning|study|teach me|quiz me|quiz|lesson|class|tutor|let's do|lets do|revise|review)\b"#
        return firstMatch(pattern, in: t) != nil && !t.contains("how do you say") && !t.contains("translate")
    }

    /// "what's this", "what am I holding", "read this label", "translate this" (not "what's this week").
    static func isLookRequest(_ t: String) -> Bool {
        let pattern = #"^(?:hey |ok |okay |so |and )?(?:can you |could you |please )?(?:what(?:'s| is) (?:this|that)|what am i holding|what i'm holding|look at (?:this|that)|take a look|read (?:this|that|it)|translate (?:this|that)|what does (?:this|that|it) say|can you see (?:this|that|what)|what do you see|describe (?:this|that|what you see)|identify (?:this|that)|tell me what (?:this|that) is)\b"#
        guard firstMatch(pattern, in: t) != nil else { return false }
        let notAboutAThing = ["week", "weekend", "month", "year", "morning", "afternoon", "evening", "tonight",
                              "song", "word", "mean", "called in", "time"]
        return !notAboutAThing.contains { t.contains($0) }
    }

    /// True for sentences that clearly start a command, even as an answer to the AI's question.
    static func isExplicitCommand(_ raw: String) -> Bool {
        let t = normalize(raw)
        let verbs = ["set ", "start ", "stop ", "cancel ", "remind ", "add ", "put ", "delete ", "remove ", "tick ",
                     "mark ", "switch ", "change ", "wake me", "begin ", "turn ", "create ", "new task", "check off",
                     "cross off", "what's on", "what is on", "what's the weather", "what time"]
        let body = t.replacingOccurrences(of: #"^(?:please|okay|ok|now|and|also)\s+"#, with: "", options: .regularExpression)
        return verbs.contains { body.hasPrefix($0) }
    }

    // MARK: - Days ("on Thursday", "next Monday", "December 25", "25th of December", "day after tomorrow")

    private static let weekdays = ["sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7]
    private static let months = ["january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3, "april": 4, "apr": 4,
                                 "may": 5, "june": 6, "jun": 6, "july": 7, "jul": 7, "august": 8, "aug": 8,
                                 "september": 9, "sep": 9, "sept": 9, "october": 10, "oct": 10, "november": 11, "nov": 11,
                                 "december": 12, "dec": 12]

    /// Days from today to a named day in the sentence, plus where it was said (so reminders can remove it).
    static func dayReference(_ t: String, now: Date) -> (offset: Int, range: Range<String.Index>)? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        func days(to date: Date) -> Int {
            calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: date)).day ?? 0
        }
        if let range = t.range(of: "day after tomorrow") { return (2, range) }

        let monthNames = months.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        let patterns = [
            #"\b(?:on\s+)?(?:the\s+)?("# + monthNames + #")\s+(\d{1,2})(?:st|nd|rd|th)?\b"#,
            #"\b(?:on\s+)?(?:the\s+)?(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?("# + monthNames + #")\b"#
        ]
        for (index, pattern) in patterns.enumerated() {
            guard let found = firstMatch(pattern, in: t) else { continue }
            let monthText = index == 0 ? found.0[1] : found.0[2]
            let dayText = index == 0 ? found.0[2] : found.0[1]
            guard let month = months[monthText], let dayNumber = Int(dayText), (1...31).contains(dayNumber) else { continue }
            var parts = calendar.dateComponents([.year], from: now)
            parts.month = month
            parts.day = dayNumber
            guard var date = calendar.date(from: parts) else { continue }
            if date < today, let next = calendar.date(byAdding: .year, value: 1, to: date) { date = next }
            return (days(to: date), found.1)
        }

        let dayNames = weekdays.keys.joined(separator: "|")
        if let found = firstMatch(#"\b(?:on\s+)?(next|this|coming)?\s*("# + dayNames + #")\b"#, in: t),
           let weekday = weekdays[found.0[2]] {
            let current = calendar.component(.weekday, from: now)
            var ahead = (weekday - current + 7) % 7
            if found.0[1] == "next" && ahead == 0 { ahead = 7 }
            return (ahead, found.1)
        }
        return nil
    }

    // MARK: - Helpers

    static func capitalizeFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (0..<match.numberOfRanges).map { index in
                let r = match.range(at: index)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> ([String], Range<String.Index>)? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              let range = Range(match.range, in: text) else { return nil }
        let ns = text as NSString
        let groups = (0..<match.numberOfRanges).map { index -> String in
            let r = match.range(at: index)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
        return (groups, range)
    }
}
