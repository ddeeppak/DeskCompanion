import Foundation
import Combine

/// Result of one action: what to say, an optional card, and how to undo it.
struct ControlResult {
    let text: String
    let card: ActionCard?
    let undo: (() -> Void)?

    init(_ text: String, card: ActionCard? = nil, undo: (() -> Void)? = nil) {
        self.text = text
        self.card = card
        self.undo = undo
    }
}

/// Full control of the app: every setting, screen, sound and feature as an action the AI (or your own
/// commands) can run. The App Intents idea: one catalog used by voice, the AI and routines.
final class AppControl: ObservableObject {
    weak var app: AppState?
    weak var night: NightMode?
    weak var voice: VoiceService?
    weak var assistant: AssistantService?
    weak var briefing: BriefingService?
    weak var presence: PresenceService?
    weak var proximity: ProximityService?
    weak var noise: NoiseMeter?
    weak var alarms: AlarmStore?
    weak var focus: FocusTimer?
    weak var library: SoundLibrary?
    weak var ai: AIService?
    weak var habits: HabitStore?
    weak var commands: CommandStore?

    func configure(app: AppState, night: NightMode, voice: VoiceService, assistant: AssistantService,
                   briefing: BriefingService, presence: PresenceService, proximity: ProximityService,
                   noise: NoiseMeter, alarms: AlarmStore, focus: FocusTimer, library: SoundLibrary,
                   ai: AIService, habits: HabitStore, commands: CommandStore) {
        self.app = app
        self.night = night
        self.voice = voice
        self.assistant = assistant
        self.briefing = briefing
        self.presence = presence
        self.proximity = proximity
        self.noise = noise
        self.alarms = alarms
        self.focus = focus
        self.library = library
        self.ai = ai
        self.habits = habits
        self.commands = commands
    }

    // MARK: Settings catalog

    struct Setting {
        let key: String
        let name: String                  // spoken: "Haptics"
        let get: () -> String
        let set: (String) -> Bool         // false = value not understood
    }

    private static func bool(_ value: String, current: Bool) -> Bool? {
        switch value.lowercased() {
        case "on", "true", "yes", "1", "enable", "enabled": return true
        case "off", "false", "no", "0", "disable", "disabled": return false
        case "toggle", "switch": return !current
        default: return nil
        }
    }

    private static func number(_ value: String) -> Int? {
        let digits = value.filter { "0123456789.".contains($0) }
        guard let d = Double(digits) else { return nil }
        return Int(d.rounded())
    }

    /// "22:30" / "6:30" → minutes after midnight.
    private static func clockMinutes(_ value: String) -> Int? {
        let parts = value.split(separator: ":").compactMap { Int($0.filter { $0.isNumber }) }
        guard parts.count == 2, parts[0] < 24, parts[1] < 60 else { return nil }
        var hour = parts[0]
        let lower = value.lowercased()
        if lower.contains("pm"), hour < 12 { hour += 12 }
        if lower.contains("am"), hour == 12 { hour = 0 }
        return hour * 60 + parts[1]
    }

    private static func clockText(_ minutes: Int) -> String {
        String(format: "%02d:%02d", (minutes / 60) % 24, minutes % 60)
    }

    private func toggle(_ key: String, _ name: String, get: @escaping () -> Bool, set: @escaping (Bool) -> Void) -> Setting {
        Setting(key: key, name: name, get: { get() ? "on" : "off" }, set: { value in
            guard let on = Self.bool(value, current: get()) else { return false }
            set(on)
            return true
        })
    }

    private func range(_ key: String, _ name: String, _ bounds: ClosedRange<Int>,
                       get: @escaping () -> Int, set: @escaping (Int) -> Void) -> Setting {
        Setting(key: key, name: name, get: { String(get()) }, set: { value in
            guard let n = Self.number(value) else { return false }
            set(min(bounds.upperBound, max(bounds.lowerBound, n)))
            return true
        })
    }

    private func choice(_ key: String, _ name: String, _ options: [String: String],
                        get: @escaping () -> String, set: @escaping (String) -> Void) -> Setting {
        Setting(key: key, name: name, get: get, set: { value in
            guard let picked = options[value.lowercased()] else { return false }
            set(picked)
            return true
        })
    }

    var settings: [Setting] {
        var list: [Setting] = []
        if let app = app {
            list.append(choice("style", "Style", ["calm": "calm", "minimal": "calm", "futuristic": "futuristic",
                                                  "future": "futuristic", "warm": "warm", "cozy": "warm", "cosy": "warm"],
                               get: { app.style.rawValue },
                               set: { if let s = AppStyle(rawValue: $0) { app.style = s } }))
        }
        if let night = night {
            list.append(toggle("night_mode", "Night mode", get: { night.enabled }, set: { night.enabled = $0 }))
            list.append(Setting(key: "night_start", name: "Night start", get: { Self.clockText(night.startMinutes) },
                                set: { v in guard let m = Self.clockMinutes(v) else { return false }; night.startMinutes = m; return true }))
            list.append(Setting(key: "night_end", name: "Night end", get: { Self.clockText(night.endMinutes) },
                                set: { v in guard let m = Self.clockMinutes(v) else { return false }; night.endMinutes = m; return true }))
            list.append(range("night_brightness", "Night brightness", 1...40,
                              get: { Int((night.brightness * 100).rounded()) },
                              set: { night.brightness = Double($0) / 100 }))
        }
        if let voice = voice {
            list.append(toggle("voice_replies", "Spoken replies", get: { voice.enabled }, set: { voice.enabled = $0 }))
            list.append(choice("voice_speed", "Voice speed", ["slow": "slow", "slower": "slow", "normal": "normal",
                                                              "default": "normal", "fast": "fast", "faster": "fast"],
                               get: { voice.rate < 0.46 ? "slow" : (voice.rate > 0.54 ? "fast" : "normal") },
                               set: { voice.rate = $0 == "slow" ? 0.42 : ($0 == "fast" ? 0.57 : 0.5) }))
        }
        if let assistant = assistant {
            list.append(toggle("keep_listening", "Keep listening", get: { assistant.keepListening },
                               set: { assistant.keepListening = $0 }))
            list.append(choice("command_routing", "Command understanding", ["ai": "ai", "phone": "phone", "local": "phone"],
                               get: { assistant.routing }, set: { assistant.routing = $0 }))
        }
        list.append(choice("assistant_text", "Conversation text", ["standard": "1.0", "normal": "1.0", "large": "1.2",
                                                                   "extra large": "1.4", "extra_large": "1.4", "larger": "1.4"],
                           get: {
                               let scale = UserDefaults.standard.object(forKey: "assistant.textScale") as? Double ?? 1.0
                               return scale >= 1.35 ? "extra large" : (scale >= 1.15 ? "large" : "standard")
                           },
                           set: { UserDefaults.standard.set(Double($0) ?? 1.0, forKey: "assistant.textScale") }))
        list.append(toggle("haptics", "Haptics",
                           get: { UserDefaults.standard.object(forKey: Haptics.enabledKey) as? Bool ?? true },
                           set: { UserDefaults.standard.set($0, forKey: Haptics.enabledKey) }))
        if let briefing = briefing {
            list.append(toggle("morning_briefing", "Morning briefing", get: { briefing.morningOn }, set: { briefing.morningOn = $0 }))
            list.append(toggle("evening_wrapup", "Evening wrap-up", get: { briefing.eveningOn }, set: { briefing.eveningOn = $0 }))
            list.append(toggle("event_headsup", "Event heads-up", get: { briefing.headsUpOn }, set: { briefing.headsUpOn = $0 }))
            list.append(range("headsup_minutes", "Heads-up time", 1...60, get: { briefing.headsUpMinutes },
                              set: { briefing.headsUpMinutes = $0 }))
        }
        if let presence = presence {
            list.append(toggle("presence_camera", "Presence detection", get: { presence.enabled }, set: { presence.enabled = $0 }))
            list.append(range("away_minutes", "Away after", 1...30, get: { presence.awayMinutes }, set: { presence.awayMinutes = $0 }))
        }
        if let proximity = proximity {
            list.append(toggle("wave", "Wave sensor", get: { proximity.enabled }, set: { proximity.enabled = $0 }))
            list.append(choice("wave_action", "Wave action", ["talk": "talk", "listen": "talk", "brighten": "brighten", "wake": "brighten"],
                               get: { proximity.action }, set: { proximity.action = $0 }))
        }
        if let noise = noise {
            list.append(toggle("noise_meter", "Noise meter", get: { noise.enabled }, set: { noise.enabled = $0 }))
        }
        if let alarms = alarms {
            list.append(toggle("alarms", "Alarms", get: { alarms.featureEnabled }, set: { alarms.featureEnabled = $0 }))
            list.append(range("snooze_minutes", "Snooze length", 1...30, get: { alarms.snoozeMinutes }, set: { alarms.snoozeMinutes = $0 }))
            list.append(range("alarm_volume", "Alarm volume", 5...100, get: { Int((alarms.volume * 100).rounded()) },
                              set: { alarms.volume = Double($0) / 100 }))
        }
        if let focus = focus {
            list.append(choice("focus_preset", "Focus length", ["short": "short", "25": "short", "long": "long", "50": "long",
                                                                "custom": "custom"],
                               get: { focus.preset.rawValue },
                               set: { if let p = FocusTimer.Preset(rawValue: $0) { focus.preset = p } }))
            list.append(range("focus_minutes", "Focus minutes", 5...120, get: { Int(focus.focusLength / 60) }, set: {
                focus.customFocusMinutes = $0
                focus.preset = .custom
            }))
            list.append(range("break_minutes", "Break minutes", 1...60, get: { focus.customBreakMinutes }, set: {
                focus.customBreakMinutes = $0
                focus.preset = .custom
            }))
            list.append(Setting(key: "focus_sound", name: "Focus sound", get: { [weak self] in
                self?.library?.label(for: focus.soundID) ?? focus.soundID
            }, set: { [weak self] value in
                guard let id = self?.soundID(value) else { return false }
                focus.soundID = id
                return true
            }))
        }
        if let library = library {
            list.append(range("focus_volume", "Sound volume", 0...100, get: { Int((library.focusVolume * 100).rounded()) },
                              set: { library.focusVolume = Double($0) / 100 }))
        }
        if let ai = ai {
            list.append(toggle("share_day", "Share my day with the AI", get: { ai.shareDay }, set: { ai.shareDay = $0 }))
        }
        if let commands = commands {
            list.append(toggle("learn_phrases", "Learn new phrases", get: { commands.learningOn }, set: { commands.learningOn = $0 }))
        }
        return list
    }

    /// "style=warm, haptics=on, …" for the AI's context.
    var summary: String {
        settings.map { "\($0.key)=\($0.get())" }.joined(separator: ", ")
    }

    /// "off", "rain", "Forest" → a focus sound id.
    func soundID(_ value: String) -> String? {
        let v = value.lowercased().replacingOccurrences(of: "file:", with: "").trimmingCharacters(in: .whitespaces)
        if ["off", "none", "no sound", "silence", "stop"].contains(v) { return "off" }
        if ["rain", "noise", "cafe"].contains(v) { return v }
        if v.contains("rain") { return "rain" }
        if v.contains("white") || v.contains("noise") { return "noise" }
        if v.contains("cafe") || v.contains("coffee") { return "cafe" }
        if let custom = library?.customSounds.first(where: {
            $0.name.lowercased() == v || $0.id.lowercased() == v || $0.name.lowercased().contains(v)
        }) {
            return "file:\(custom.id)"
        }
        return nil
    }

    var soundNames: String {
        (["rain", "noise", "cafe"] + (library?.customSounds.map { $0.name } ?? [])).joined(separator: ", ")
    }

    // MARK: Confirmation (bulk or destructive changes ask first)

    func confirmationPrompt(_ object: [String: Any]) -> String? {
        let type = CommandStore.type(object)
        switch type {
        case "deletealarm":
            let time = CommandStore.value(object["time"])
            let count = alarms?.alarms.count ?? 0
            if (time.isEmpty || time == "all"), count > 1 { return "Delete all \(count) alarms?" }
        case "forgetall":
            let count = commands?.memory.count ?? 0
            return count == 0 ? nil : "Forget all \(count) things I remember about you?"
        case "deleteroutine":
            let name = CommandStore.value(object["name"])
            if let routine = commands?.routine(named: name) { return "Delete your command “\(routine.name)”?" }
        default:
            break
        }
        return nil
    }

    // MARK: Running an action

    /// nil = not an action this catalog handles (the assistant tries its own).
    func apply(_ object: [String: Any]) -> ControlResult? {
        let type = CommandStore.type(object)
        func text(_ key: String) -> String { CommandStore.value(object[key]) }

        switch type {
        case "setsetting", "set", "setstyle", "changesetting":
            let key = type == "setstyle" ? "style" : text("key").lowercased().replacingOccurrences(of: " ", with: "_")
            let value = type == "setstyle" ? text("style") : text("value")
            return applySetting(key: key, value: value)

        case "open", "show", "navigate":
            let screenName = text("screen").lowercased()
            guard let screen = AppScreen.allCases.first(where: { $0.rawValue == screenName || $0.title.lowercased() == screenName })
            else { return ControlResult("I can't open that.") }
            let section = text("section").lowercased()
            if screen == .settings, !section.isEmpty { app?.pendingSettingsSection = section }
            let previous = app?.screen
            // Leave time for the reply to be spoken before switching away from the assistant.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.app?.screen = screen }
            return ControlResult("Opening \(screen.title).", undo: { [weak self] in
                if let previous = previous { self?.app?.screen = previous }
            })

        case "playsound":
            guard let focus = focus, let id = soundID(text("sound")) else { return ControlResult("I don't have that sound.") }
            let old = focus.soundID
            focus.soundID = id
            SoundEngine.shared.setFocusSound(id)
            let label = library?.label(for: id) ?? id
            return ControlResult(id == "off" ? "Sound off." : "Playing \(label.lowercased()).", undo: {
                SoundEngine.shared.setFocusSound("off")
                focus.soundID = old
            })

        case "stopsound":
            SoundEngine.shared.setFocusSound("off")
            return ControlResult("Sound stopped.")

        case "extendfocus":
            guard let focus = focus, focus.canResetOrSkip else { return ControlResult("Focus isn't running.") }
            let minutes = max(1, Self.number(text("minutes")) ?? 5)
            focus.extend(minutes: minutes)
            return ControlResult("Added \(minutes) minutes.")

        case "skip":
            guard let focus = focus, focus.canResetOrSkip else { return ControlResult("There's no session to skip.") }
            focus.skip()
            return ControlResult("Skipped to the next session.")

        case "startbreak":
            guard let focus = focus else { return nil }
            focus.startBreak()
            return ControlResult("Break started.")

        case "alarmonoff", "togglealarm":
            guard let alarms = alarms else { return nil }
            let on = Self.bool(text("on"), current: false) ?? false
            let minutes = Self.clockMinutes(text("time"))
            let matching = alarms.alarms.indices.filter { i in
                guard let m = minutes else { return true }
                return alarms.alarms[i].hour * 60 + alarms.alarms[i].minute == m
            }
            guard !matching.isEmpty else { return ControlResult("I couldn't find that alarm.") }
            let old = matching.map { alarms.alarms[$0].enabled }
            for i in matching { alarms.alarms[i].enabled = on }
            if on, !alarms.featureEnabled { alarms.featureEnabled = true }
            let label = matching.count == 1 ? "The \(alarms.alarms[matching[0]].timeText) alarm is" : "\(matching.count) alarms are"
            return ControlResult("\(label) \(on ? "on" : "off").", undo: {
                for (n, i) in matching.enumerated() where i < alarms.alarms.count { alarms.alarms[i].enabled = old[n] }
            })

        case "snooze":
            guard let alarms = alarms, alarms.ringing != nil else { return ControlResult("No alarm is ringing.") }
            alarms.snooze()
            return ControlResult("Snoozed for \(alarms.snoozeMinutes) minutes.")

        case "stopalarm":
            guard let alarms = alarms, alarms.ringing != nil else { return ControlResult("No alarm is ringing.") }
            alarms.stop()
            return ControlResult("Alarm stopped.")

        case "briefing":
            guard let briefing = briefing else { return nil }
            let evening = text("kind").lowercased().contains("even")
            return ControlResult(evening ? briefing.eveningText(Date()) : briefing.morningText(Date()))

        case "completehabit", "habit":
            guard let habits = habits else { return nil }
            let name = text("name").lowercased()
            guard let habit = habits.habits.first(where: { $0.name.lowercased() == name })
                    ?? habits.habits.first(where: { $0.name.lowercased().contains(name) || name.contains($0.name.lowercased()) })
            else { return ControlResult("I couldn't find a habit called \(text("name")).") }
            if habits.isDone(habit) { return ControlResult("\(habit.name) is already done today.") }
            habits.tap(habit)
            return ControlResult(habits.isDone(habit) ? "Ticked off \(habit.name)." : "\(habit.name): \(habits.subtitle(habit)).",
                                 undo: nil)

        case "remember":
            guard let commands = commands else { return nil }
            let fact = text("fact")
            guard commands.remember(fact) else { return ControlResult("I already know that.") }
            ai?.backupMemories(commands.memory)
            return ControlResult("Got it, I'll remember that.",
                                 card: ActionCard(kind: .info, heading: "Remembered", title: fact,
                                                  detail: "Stored on this iPhone", undo: nil, canEdit: false),
                                 undo: { [weak self] in
                                     commands.forgetExact(fact)
                                     self?.ai?.backupMemories(commands.memory)
                                 })

        case "forget":
            guard let commands = commands else { return nil }
            let before = commands.memory
            let removed = commands.forget(text("fact"))
            guard !removed.isEmpty else { return ControlResult("I didn't have anything about that.") }
            ai?.backupMemories(commands.memory)
            return ControlResult("Okay, I've forgotten that.", undo: { [weak self] in
                commands.restoreMemory(before)
                self?.ai?.backupMemories(before)
            })

        case "forgetall":
            guard let commands = commands else { return nil }
            let before = commands.memory
            commands.clearMemory()
            ai?.backupMemories([])
            return ControlResult("Done. I've forgotten everything.", undo: { [weak self] in
                commands.restoreMemory(before)
                self?.ai?.backupMemories(before)
            })

        case "createroutine", "addroutine", "createcommand":
            guard let commands = commands else { return nil }
            let name = text("name").trimmingCharacters(in: .whitespaces)
            var phrases = (object["phrases"] as? [Any])?.map { CommandStore.value($0) } ?? []
            if phrases.isEmpty, !name.isEmpty { phrases = [name] }
            let steps = ((object["actions"] as? [Any]) ?? (object["steps"] as? [Any]) ?? [])
                .compactMap { $0 as? [String: Any] }
                .map { CommandStore.step($0) }
            guard !name.isEmpty, !steps.isEmpty else { return ControlResult("Sorry, I couldn't make that command.") }
            var routine = commands.routine(named: name) ?? Routine.blank()
            let isNew = routine.name.isEmpty
            routine.name = name.prefix(1).uppercased() + name.dropFirst()
            routine.phrases = phrases
            routine.steps = steps
            let time = text("time")
            if !time.isEmpty, let m = Self.clockMinutes(time) { routine.time = Self.clockText(m) } else { routine.time = nil }
            routine.days = ((object["days"] as? [Any]) ?? []).compactMap { Self.number(CommandStore.value($0)) }
                .filter { (1...7).contains($0) }
            routine.onArrive = Self.bool(text("on_arrive"), current: false) ?? false
            commands.upsert(routine)
            let id = routine.id
            let say = phrases.first ?? name
            var detail = "\(steps.count) step\(steps.count == 1 ? "" : "s")"
            if !routine.triggerText.isEmpty { detail += " · \(routine.triggerText)" }
            var undo: (() -> Void)? = nil
            if isNew { undo = { commands.remove(id) } }
            return ControlResult("\(isNew ? "Saved" : "Updated") your command \(routine.name). Say “\(say)” to run it.",
                                 card: ActionCard(kind: .info, heading: isNew ? "Command saved" : "Command updated",
                                                  title: routine.name, detail: detail, undo: nil, canEdit: true),
                                 undo: undo)

        case "deleteroutine", "deletecommand":
            guard let commands = commands else { return nil }
            guard let routine = commands.routine(named: text("name")) else {
                return ControlResult("I couldn't find a command called \(text("name")).")
            }
            commands.remove(routine.id)
            return ControlResult("Deleted your command \(routine.name).", undo: { commands.upsert(routine) })

        case "say":
            return ControlResult(text("text"))

        default:
            return nil
        }
    }

    func applySetting(key: String, value: String) -> ControlResult {
        let aliases = ["theme": "style", "look": "style", "voice": "voice_replies", "spoken_replies": "voice_replies",
                       "night": "night_mode", "vibration": "haptics", "wave_to_talk": "wave", "sound": "focus_sound",
                       "camera": "presence_camera", "presence": "presence_camera", "routing": "command_routing"]
        let key = aliases[key] ?? key
        guard let setting = settings.first(where: { $0.key == key }) else {
            return ControlResult("I can't change \(key.replacingOccurrences(of: "_", with: " ")).")
        }
        let old = setting.get()
        guard setting.set(value) else {
            return ControlResult("Sorry, \(value) isn't a valid value for \(setting.name.lowercased()).")
        }
        let now = setting.get()
        let spoken: String
        switch now {
        case "on", "off": spoken = "\(setting.name) \(now)."
        default: spoken = "\(setting.name): \(now.replacingOccurrences(of: "_", with: " "))."
        }
        return ControlResult(spoken, undo: { _ = setting.set(old) })
    }
}
