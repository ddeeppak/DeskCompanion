import SwiftUI
import UniformTypeIdentifiers

/// Settings → Alarms & Sounds: in-app alarms (with an on/off master switch) and focus sound options.
struct AlarmsSoundsSettings: View {
    @EnvironmentObject private var alarms: AlarmStore
    @EnvironmentObject private var library: SoundLibrary
    @EnvironmentObject private var focus: FocusTimer
    @Environment(\.theme) private var theme
    @State private var editingID: UUID?
    @State private var importing = false
    @State private var previewingID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            alarmsSection
            focusSoundsSection
                .padding(.top, 12)
            mySoundsSection
                .padding(.top, 12)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                urls.forEach { library.importFile($0) }
            }
        }
        .onDisappear {
            if previewingID != nil {
                previewingID = nil
                SoundEngine.shared.setFocusSound(focus.state == .running && focus.phase == .focus ? focus.soundID : "off")
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var alarmsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Alarms")
            VStack(spacing: 0) {
                SettingsRow {
                    Text("Alarms")
                    Spacer(minLength: 8)
                    Toggle("", isOn: $alarms.featureEnabled)
                        .labelsHidden()
                        .toggleStyle(SwitchToggleStyle(tint: theme.toggleOn))
                        .onChange(of: alarms.featureEnabled) { on in
                            if on { alarms.requestNotificationPermission() }
                        }
                }
                if alarms.featureEnabled {
                    ForEach(alarms.alarms) { alarm in
                        RowSeparator()
                        alarmRow(alarm)
                        if editingID == alarm.id {
                            AlarmEditor(alarm: binding(alarm.id), onDelete: {
                                editingID = nil
                                alarms.remove(alarm.id)
                            })
                        }
                    }
                    RowSeparator()
                    Button {
                        editingID = alarms.add()
                    } label: {
                        SettingsRow {
                            Image(systemName: "plus.circle.fill").foregroundColor(theme.green)
                            Text("Add alarm").foregroundColor(theme.accent)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .groupedBox()

            if alarms.featureEnabled {
                VStack(spacing: 0) {
                    SettingsRow {
                        Text("Snooze")
                        Spacer(minLength: 8)
                        Stepper("\(alarms.snoozeMinutes) min", value: $alarms.snoozeMinutes, in: 1...30)
                            .fixedSize()
                    }
                    RowSeparator()
                    SettingsRow {
                        Text("Alarm volume")
                        Spacer(minLength: 8)
                        Slider(value: $alarms.volume, in: 0.1...1)
                            .frame(width: 150)
                        Text("\(Int((alarms.volume * 100).rounded()))%")
                            .font(.system(size: 16).monospacedDigit())
                            .foregroundColor(theme.secondaryLabel)
                            .frame(width: 48, alignment: .trailing)
                    }
                }
                .groupedBox()
                footnote("Alarms ring from this app, so keep it open on the desk. If the app isn't open, an iPhone notification plays instead (a short sound only).")
            } else {
                footnote("Alarms are off. The night clock shows tomorrow's sunrise instead.")
            }

        }
    }

    @ViewBuilder
    private var focusSoundsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Focus sounds")
            VStack(spacing: 0) {
                ForEach(SoundEngine.Builtin.allCases) { builtin in
                    SettingsRow {
                        Text(builtin.label)
                        Spacer(minLength: 8)
                        Toggle("", isOn: visibleBinding(builtin.rawValue))
                            .labelsHidden()
                            .toggleStyle(SwitchToggleStyle(tint: theme.toggleOn))
                    }
                    RowSeparator()
                }
                SettingsRow {
                    Text("Volume")
                    Spacer(minLength: 8)
                    Slider(value: $library.focusVolume, in: 0.05...1)
                        .frame(width: 150)
                    Text("\(Int((library.focusVolume * 100).rounded()))%")
                        .font(.system(size: 16).monospacedDigit())
                        .foregroundColor(theme.secondaryLabel)
                        .frame(width: 48, alignment: .trailing)
                }
            }
            .groupedBox()
            footnote("Switch off the sounds you don't want in the Focus picker.")

        }
    }

    @ViewBuilder
    private var mySoundsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("My sounds")
            VStack(spacing: 0) {
                ForEach(library.customSounds) { sound in
                    SettingsRow {
                        Button { togglePreview(sound) } label: {
                            Image(systemName: previewingID == sound.id ? "stop.circle.fill" : "play.circle.fill")
                                .font(.system(size: 24))
                                .foregroundColor(theme.accent)
                                .frame(width: 32, height: 44)
                        }
                        .buttonStyle(.plain)
                        Text(sound.name).lineLimit(1)
                        Spacer(minLength: 8)
                        Button {
                            if previewingID == sound.id { togglePreview(sound) }
                            if focus.soundID == "file:\(sound.id)" { focus.soundID = "off" }
                            library.delete(sound)
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
                Button { importing = true } label: {
                    SettingsRow {
                        Image(systemName: "square.and.arrow.down.fill").foregroundColor(theme.accent)
                        Text("Import from Files").foregroundColor(theme.accent)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                RowSeparator()
                Button { library.rescan() } label: {
                    SettingsRow {
                        Image(systemName: "arrow.clockwise").foregroundColor(theme.accent)
                        Text("Refresh list").foregroundColor(theme.accent)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .groupedBox()
            footnote("MP3, M4A, WAV or AAC. To copy from your PC: open iTunes, click the iPhone, choose File Sharing, then Desk Companion, and drag files in. Then tap Refresh list.")
        }
    }

    // MARK: Rows

    private func alarmRow(_ alarm: Alarm) -> some View {
        SettingsRow {
            Button {
                editingID = editingID == alarm.id ? nil : alarm.id
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(alarm.timeText)
                            .font(.system(size: 20, weight: .bold).monospacedDigit())
                            .foregroundColor(alarm.enabled ? theme.label : theme.secondaryLabel)
                        Text("\(alarm.label) · \(alarm.daysText) · \(SoundEngine.AlarmTone(rawValue: alarm.tone)?.label ?? "Chime")")
                            .font(.system(size: 13))
                            .foregroundColor(theme.secondaryLabel)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: editingID == alarm.id ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(theme.tertiaryLabel)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Toggle("", isOn: binding(alarm.id).enabled)
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: theme.toggleOn))
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(theme.secondaryLabel)
            .padding(.leading, 14)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Bindings

    private func binding(_ id: UUID) -> Binding<Alarm> {
        Binding(
            get: { alarms.alarms.first { $0.id == id } ?? Alarm(hour: 7, minute: 0) },
            set: { updated in
                if let index = alarms.alarms.firstIndex(where: { $0.id == id }) { alarms.alarms[index] = updated }
            })
    }

    private func visibleBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !library.hiddenBuiltIns.contains(id) },
            set: { visible in
                if visible {
                    library.hiddenBuiltIns.remove(id)
                } else {
                    library.hiddenBuiltIns.insert(id)
                    if focus.soundID == id { focus.soundID = "off" }
                }
            })
    }

    private func togglePreview(_ sound: SoundLibrary.CustomSound) {
        if previewingID == sound.id {
            previewingID = nil
            SoundEngine.shared.setFocusSound(focus.state == .running && focus.phase == .focus ? focus.soundID : "off")
        } else {
            previewingID = sound.id
            SoundEngine.shared.setFocusSound("file:\(sound.id)")
        }
    }
}

// MARK: - Alarm editor (expands under the alarm row)

private struct AlarmEditor: View {
    @Binding var alarm: Alarm
    let onDelete: () -> Void
    @EnvironmentObject private var alarms: AlarmStore
    @Environment(\.theme) private var theme

    init(alarm: Binding<Alarm>, onDelete: @escaping () -> Void) {
        self._alarm = alarm
        self.onDelete = onDelete
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                DatePicker("", selection: timeBinding, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                TextField("Label", text: $alarm.label)
                    .font(.system(size: 16))
                    .padding(.horizontal, 10)
                    .frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.fill))
            }

            HStack(spacing: 6) {
                ForEach(Alarm.weekdayOrder, id: \.self) { day in
                    let on = alarm.days.contains(day)
                    Button {
                        if on { alarm.days.removeAll { $0 == day } } else { alarm.days.append(day) }
                        alarm.enabled = true
                    } label: {
                        Text(Alarm.letters[day] ?? "")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(on ? theme.onAccent : theme.label)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(on ? theme.accent : theme.fill))
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 4)
                Text(alarm.daysText)
                    .font(.system(size: 13))
                    .foregroundColor(theme.secondaryLabel)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                SegmentedBar(options: SoundEngine.AlarmTone.allCases.map { ($0.rawValue, $0.label) },
                             selection: $alarm.tone)
                Button {
                    SoundEngine.shared.previewAlarm(tone: SoundEngine.AlarmTone(rawValue: alarm.tone) ?? .chime,
                                                    volume: Float(alarms.volume))
                } label: {
                    Text("Test")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(theme.accent)
                        .padding(.horizontal, 14)
                        .frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.accentTint))
                }
                .buttonStyle(.plain)
            }

            HStack {
                Toggle(isOn: $alarm.rising) {
                    Text("Gentle start (gets louder)").font(.system(size: 15))
                }
                .toggleStyle(SwitchToggleStyle(tint: theme.toggleOn))
                .fixedSize()
                Spacer(minLength: 8)
                Button(role: .destructive, action: onDelete) {
                    Text("Delete")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(theme.red)
                        .frame(height: 44)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(theme.fill.opacity(0.35))
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: alarm.hour, minute: alarm.minute, second: 0, of: Date()) ?? Date() },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                alarm.hour = parts.hour ?? 7
                alarm.minute = parts.minute ?? 0
                alarm.enabled = true
                alarm.lastFired = nil
            })
    }
}
