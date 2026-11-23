import SwiftUI

/// Settings → Commands: how commands are understood, your own commands, and phrases the phone has learned.
struct CommandsSettings: View {
    @EnvironmentObject private var commands: CommandStore
    @EnvironmentObject private var assistant: AssistantService
    @Environment(\.theme) private var theme
    @State private var draft: Routine? = nil

    var body: some View {
        if let editing = draft {
            RoutineEditor(initial: editing,
                          isNew: !commands.routines.contains { $0.id == editing.id },
                          onSave: { saved in
                              commands.upsert(saved)
                              draft = nil
                          },
                          onCancel: { draft = nil },
                          onDelete: {
                              commands.remove(editing.id)
                              draft = nil
                          },
                          onTest: { routine in assistant.runRoutine(routine) })
        } else {
            VStack(alignment: .leading, spacing: 0) {
                understandingSection
                myCommandsSection
                    .padding(.top, 12)
                learnedSection
                    .padding(.top, 12)
            }
        }
    }

    // MARK: Understanding

    private var understandingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Understanding")
            VStack(spacing: 0) {
                SettingsRow {
                    Text("Understand commands with")
                    Spacer(minLength: 8)
                    Picker("", selection: $assistant.routing) {
                        Text("AI first").tag("ai")
                        Text("Phone first").tag("phone")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                }
                .padding(.vertical, 3)
                RowSeparator()
                SettingsRow {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Learn new phrases")
                        Text("New ways of saying things become instant and work offline")
                            .font(.system(size: 13))
                            .foregroundColor(theme.secondaryLabel)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: $commands.learningOn)
                        .labelsHidden()
                        .toggleStyle(SwitchToggleStyle(tint: theme.toggleOn))
                }
                .padding(.vertical, 3)
            }
            .groupedBox()
            footnote("AI first: the AI on your PC understands any wording and can do several things at once. Timers, alarms and stop commands still run instantly on the phone, and everything falls back to the phone when the PC is off.")
        }
    }

    // MARK: My commands

    private var myCommandsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("My commands")
            VStack(spacing: 0) {
                ForEach(commands.routines) { routine in
                    routineRow(routine)
                    RowSeparator()
                }
                Button { draft = Routine.blank() } label: {
                    SettingsRow {
                        Image(systemName: "plus.circle.fill").foregroundColor(theme.accent)
                        Text("New command").foregroundColor(theme.accent)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .groupedBox()
            footnote("Or just say: “When I say movie time, play rain and switch to the warm style.” Your phrase runs instantly, even offline, and the AI also recognises similar wording.")
        }
    }

    private func routineRow(_ routine: Routine) -> some View {
        SettingsRow {
            Button { draft = routine } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(routine.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(routine.enabled ? theme.label : theme.secondaryLabel)
                    Text(subtitle(routine))
                        .font(.system(size: 13))
                        .foregroundColor(theme.secondaryLabel)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { assistant.runRoutine(routine) } label: {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundColor(theme.accent)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Run \(routine.name)")
            Toggle("", isOn: enabledBinding(routine))
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: theme.toggleOn))
        }
        .padding(.vertical, 4)
    }

    private func subtitle(_ routine: Routine) -> String {
        var parts = ["Say “\(routine.phrases.first ?? routine.name)”"]
        parts.append(routine.steps.map { CommandStore.describe($0) }.joined(separator: ", "))
        if !routine.triggerText.isEmpty { parts.append(routine.triggerText) }
        return parts.joined(separator: " · ")
    }

    private func enabledBinding(_ routine: Routine) -> Binding<Bool> {
        Binding(get: {
            commands.routines.first { $0.id == routine.id }?.enabled ?? false
        }, set: { on in
            var current = commands.routines.first { $0.id == routine.id } ?? routine
            current.enabled = on
            commands.upsert(current)
        })
    }

    // MARK: Learned phrases

    private var learnedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Learned phrases")
            VStack(spacing: 0) {
                if commands.learned.isEmpty {
                    SettingsRow {
                        Image(systemName: "sparkles").foregroundColor(theme.accent2).frame(width: 24)
                        Text("Nothing learned yet").foregroundColor(theme.secondaryLabel)
                        Spacer(minLength: 0)
                    }
                } else {
                    ForEach(commands.learned) { item in
                        SettingsRow {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("“\(item.phrase)”")
                                Text(item.steps.map { CommandStore.describe($0) }.joined(separator: ", ")
                                     + (item.uses > 1 ? " · used \(item.uses) times" : ""))
                                    .font(.system(size: 13))
                                    .foregroundColor(theme.secondaryLabel)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 8)
                            Button { commands.removeLearned(item.id) } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundColor(theme.red)
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Forget \(item.phrase)")
                        }
                        .padding(.vertical, 2)
                        RowSeparator()
                    }
                    Button { commands.clearLearned() } label: {
                        SettingsRow {
                            Text("Forget all learned phrases").foregroundColor(theme.red)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .groupedBox()
            footnote("Only safe, repeatable actions are learned (styles, settings, sounds, focus, timers, opening screens), never deletes or reminders.")
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(theme.secondaryLabel)
            .padding(.leading, 14)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Editor

private struct RoutineEditor: View {
    let isNew: Bool
    let onSave: (Routine) -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void
    let onTest: (Routine) -> Void
    @State private var routine: Routine
    @State private var phrasesText: String
    @State private var trigger: String          // "none", "time", "arrive"
    @State private var confirmDelete = false
    @EnvironmentObject private var library: SoundLibrary
    @Environment(\.theme) private var theme

    init(initial: Routine, isNew: Bool, onSave: @escaping (Routine) -> Void, onCancel: @escaping () -> Void,
         onDelete: @escaping () -> Void, onTest: @escaping (Routine) -> Void) {
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
        self.onDelete = onDelete
        self.onTest = onTest
        _routine = State(initialValue: initial)
        _phrasesText = State(initialValue: initial.phrases.joined(separator: ", "))
        _trigger = State(initialValue: initial.time != nil ? "time" : (initial.onArrive ? "arrive" : "none"))
    }

    private var finished: Routine {
        var r = routine
        r.phrases = phrasesText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        r.time = trigger == "time" ? (r.time ?? "07:00") : nil
        r.onArrive = trigger == "arrive"
        return r
    }

    private var canSave: Bool {
        !routine.name.trimmingCharacters(in: .whitespaces).isEmpty && !routine.steps.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            namesSection
                .padding(.top, 10)
            stepsSection
                .padding(.top, 12)
            triggerSection
                .padding(.top, 12)
            if !isNew {
                Button { confirmDelete = true } label: {
                    SettingsRow {
                        Text("Delete command").foregroundColor(theme.red)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .groupedBox()
                .padding(.top, 12)
            }
        }
        .alert("Delete “\(routine.name)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button("Cancel") { onCancel() }
                .foregroundColor(theme.accent)
                .frame(minWidth: 44, minHeight: 44)
            Spacer(minLength: 0)
            Text(isNew ? "New command" : "Edit command")
                .font(.system(size: 17, weight: .bold))
            Spacer(minLength: 0)
            Button("Test") { onTest(finished) }
                .foregroundColor(canSave ? theme.accent : theme.tertiaryLabel)
                .disabled(!canSave)
                .frame(minWidth: 44, minHeight: 44)
            Button("Save") { onSave(finished) }
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(canSave ? theme.accent : theme.tertiaryLabel)
                .disabled(!canSave)
                .frame(minWidth: 44, minHeight: 44)
        }
        .padding(.horizontal, 4)
    }

    private var namesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                SettingsRow {
                    Text("Name").frame(width: 64, alignment: .leading)
                    TextField("Movie time", text: $routine.name)
                }
                RowSeparator()
                SettingsRow {
                    Text("Say").frame(width: 64, alignment: .leading)
                    TextField("movie time, film night", text: $phrasesText)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
            }
            .groupedBox()
            footnote("Separate several phrases with commas. Close spellings work too.")
        }
    }

    // MARK: Steps

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Steps")
            VStack(spacing: 0) {
                ForEach(Array(routine.steps.enumerated()), id: \.offset) { index, step in
                    SettingsRow {
                        Text("\(index + 1)")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(theme.secondaryLabel)
                            .frame(width: 18)
                        Text(CommandStore.describe(step))
                        Spacer(minLength: 8)
                        Button {
                            if routine.steps.indices.contains(index) { routine.steps.remove(at: index) }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 22))
                                .foregroundColor(theme.red)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                    }
                    RowSeparator()
                }
                addStepMenu
            }
            .groupedBox()
        }
    }

    private func add(_ object: [String: Any]) {
        routine.steps.append(CommandStore.step(object))
    }

    private func setting(_ title: String, _ key: String, _ value: String) -> some View {
        Button(title) { add(["type": "set_setting", "key": key, "value": value]) }
    }

    private var addStepMenu: some View {
        Menu {
            Menu("Style") {
                ForEach(AppStyle.allCases) { style in
                    Button(style.displayName) { add(["type": "set_style", "style": style.rawValue]) }
                }
            }
            Menu("Focus") {
                Button("Start 25 min focus") { add(["type": "focus", "minutes": 25]) }
                Button("Start 50 min focus") { add(["type": "focus", "minutes": 50]) }
                Button("Stop focus") { add(["type": "stop_focus"]) }
            }
            Menu("Timer") {
                ForEach([1, 3, 5, 10, 15, 25, 30, 60], id: \.self) { minutes in
                    Button("\(minutes) min timer") { add(["type": "timer", "seconds": minutes * 60]) }
                }
            }
            Menu("Sound") {
                ForEach(library.focusOptions.map { $0.0 }.filter { $0 != "off" }, id: \.self) { id in
                    Button(library.label(for: id)) { add(["type": "play_sound", "sound": id]) }
                }
                Button("Stop the sound") { add(["type": "stop_sound"]) }
            }
            Menu("Settings") {
                setting("Night mode on", "night_mode", "on")
                setting("Night mode off", "night_mode", "off")
                setting("Spoken replies on", "voice_replies", "on")
                setting("Spoken replies off", "voice_replies", "off")
                setting("Haptics on", "haptics", "on")
                setting("Haptics off", "haptics", "off")
                setting("Keep listening on", "keep_listening", "on")
                setting("Keep listening off", "keep_listening", "off")
                setting("Wave sensor on", "wave", "on")
                setting("Wave sensor off", "wave", "off")
                setting("Alarms on", "alarms", "on")
                setting("Alarms off", "alarms", "off")
            }
            Menu("Open") {
                ForEach(AppScreen.allCases) { screen in
                    Button(screen.title) { add(["type": "open", "screen": screen.rawValue]) }
                }
            }
            Button("Morning briefing") { add(["type": "briefing", "kind": "morning"]) }
            Button("Evening wrap-up") { add(["type": "briefing", "kind": "evening"]) }
        } label: {
            SettingsRow {
                Image(systemName: "plus.circle.fill").foregroundColor(theme.accent)
                Text("Add step").foregroundColor(theme.accent)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
    }

    // MARK: Trigger

    private var triggerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Runs by itself")
            VStack(spacing: 0) {
                SettingsRow {
                    Picker("", selection: $trigger) {
                        Text("Only when said").tag("none")
                        Text("At a time").tag("time")
                        Text("When I sit down").tag("arrive")
                    }
                    .pickerStyle(.segmented)
                }
                .padding(.vertical, 4)
                if trigger == "time" {
                    RowSeparator()
                    SettingsRow {
                        Text("Time")
                        Spacer(minLength: 8)
                        DatePicker("", selection: timeBinding, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                    }
                    RowSeparator()
                    SettingsRow {
                        Text("Days")
                        Spacer(minLength: 8)
                        ForEach(Alarm.weekdayOrder, id: \.self) { day in dayButton(day) }
                    }
                    .padding(.vertical, 4)
                }
                if trigger == "arrive" {
                    RowSeparator()
                    SettingsRow {
                        Text("Between")
                        Spacer(minLength: 8)
                        Picker("", selection: $routine.arriveFrom) {
                            ForEach(0..<24, id: \.self) { hour in Text(Routine.hourText(hour)).tag(hour) }
                        }
                        .pickerStyle(.menu)
                        Text("and")
                        Picker("", selection: $routine.arriveTo) {
                            ForEach(1..<25, id: \.self) { hour in Text(Routine.hourText(hour)).tag(hour) }
                        }
                        .pickerStyle(.menu)
                    }
                }
            }
            .groupedBox()
            footnote(trigger == "arrive"
                     ? "Uses the front camera (Settings → Sensors). Runs once a day, the first time you sit down in those hours."
                     : "No days picked = every day.")
        }
    }

    private var timeBinding: Binding<Date> {
        Binding(get: {
            let parts = (routine.time ?? "07:00").split(separator: ":").compactMap { Int($0) }
            return Calendar.current.date(bySettingHour: parts.first ?? 7, minute: parts.count > 1 ? parts[1] : 0,
                                         second: 0, of: Date()) ?? Date()
        }, set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            routine.time = String(format: "%02d:%02d", c.hour ?? 7, c.minute ?? 0)
        })
    }

    private func dayButton(_ day: Int) -> some View {
        let on = routine.days.contains(day)
        return Button {
            if on { routine.days.removeAll { $0 == day } } else { routine.days.append(day) }
        } label: {
            Text(Alarm.letters[day] ?? "?")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(on ? theme.onAccent : theme.label)
                .frame(width: 30, height: 30)
                .background(Circle().fill(on ? theme.accent : theme.fill))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Alarm.shortNames[day] ?? "")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(theme.secondaryLabel)
            .padding(.leading, 14)
            .fixedSize(horizontal: false, vertical: true)
    }
}
