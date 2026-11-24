import SwiftUI
import AVFoundation
import UIKit

/// Settings → Voice: speech recognition language, spoken replies, voice and speed, history.
struct VoiceSettings: View {
    @EnvironmentObject private var speech: SpeechService
    @EnvironmentObject private var voice: VoiceService
    @EnvironmentObject private var assistant: AssistantService
    @EnvironmentObject private var briefing: BriefingService
    @ObservedObject private var wake = WakeWordService.shared
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            listeningSection
            repliesSection
                .padding(.top, 12)
            wakeSection
                .padding(.top, 12)
            briefingsSection
                .padding(.top, 12)
            historySection
                .padding(.top, 12)
        }
    }

    private var wakeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Wake phrase")
            VStack(spacing: 0) {
                SettingsRow {
                    Image(systemName: "waveform.circle.fill").foregroundColor(theme.accent).frame(width: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Listen for “\(wake.phrase)”")
                        Text(wakeStatus).font(.system(size: 13)).foregroundColor(theme.secondaryLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: $wake.enabled).labelsHidden().toggleStyle(SwitchToggleStyle(tint: theme.toggleOn))
                }
                .padding(.vertical, 3)
                RowSeparator()
                SettingsRow {
                    Image(systemName: "text.bubble.fill").foregroundColor(theme.accent2).frame(width: 24)
                    Text("Phrase")
                    Spacer(minLength: 8)
                    Menu {
                        ForEach(WakeWordService.presets, id: \.self) { preset in
                            Button(preset) { wake.phrase = preset }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(wake.phrase)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 12, weight: .bold))
                        }
                        .foregroundColor(theme.accent)
                    }
                }
                RowSeparator()
                testRow
                if wake.enabled {
                    RowSeparator()
                    SettingsRow {
                        Image(systemName: "moon.fill").foregroundColor(theme.indigo).frame(width: 24)
                        Text("Also at night")
                        Spacer(minLength: 8)
                        Toggle("", isOn: $wake.atNight).labelsHidden().toggleStyle(SwitchToggleStyle(tint: theme.toggleOn))
                    }
                }
            }
            .groupedBox()
            footnote("Say “\(wake.phrase)” or “\(wake.phrase), what's the weather?”. Listening happens only on this iPhone and only while someone is at the desk; nothing is recorded or sent until you say the phrase. Longer phrases (Hey Companion) are caught more reliably than short ones. It uses some battery and warmth, and pauses if the phone gets hot.")
        }
    }

    /// "Test": say the phrase and see what the phone hears.
    private var testRow: some View {
        SettingsRow {
            Image(systemName: testSymbol).foregroundColor(testColor).frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(testTitle)
                if !testDetail.isEmpty {
                    Text(testDetail).font(.system(size: 13)).foregroundColor(theme.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if wake.testState == .listening {
                Button("Stop") { wake.cancelTest() }
                    .foregroundColor(theme.red)
                    .frame(minWidth: 44, minHeight: 44)
            } else {
                Button(wake.testState == .idle ? "Test" : "Try again") { wake.startTest() }
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(theme.accent)
                    .frame(minWidth: 44, minHeight: 44)
            }
        }
        .padding(.vertical, 3)
        .animation(.easeInOut(duration: 0.2), value: wake.testState)
    }

    private var testSymbol: String {
        switch wake.testState {
        case .idle: return "mic.circle"
        case .listening: return "mic.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private var testColor: Color {
        switch wake.testState {
        case .idle: return theme.secondaryLabel
        case .listening: return theme.accent
        case .success: return theme.green
        case .failed: return theme.red
        }
    }

    private var testTitle: String {
        switch wake.testState {
        case .idle: return "Test the wake phrase"
        case .listening: return "Say “\(wake.phrase)” now…"
        case .success: return "Heard it, it works!"
        case .failed: return "Didn't catch “\(wake.phrase)”"
        }
    }

    private var testDetail: String {
        switch wake.testState {
        case .idle: return "Checks that this iPhone hears your phrase (doesn't open the assistant)"
        case .listening: return wake.heardPreview.isEmpty ? "Listening…" : "Hearing: “\(wake.heardPreview)”"
        case .success: return "It heard: “\(wake.testHeard)”"
        case .failed:
            if let reason = wake.unavailableReason { return reason }
            if wake.testHeard.isEmpty { return "It heard nothing. Speak a little louder, facing the phone." }
            return "It heard: “\(wake.testHeard)”. Try again a bit slower, or pick a longer phrase like Hey Companion."
        }
    }

    private var wakeStatus: String {
        if let reason = wake.unavailableReason, wake.enabled { return reason }
        return wake.status
    }

    private var briefingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Briefings")
            VStack(spacing: 0) {
                SettingsRow {
                    Image(systemName: "sun.max.fill").symbolRenderingMode(.multicolor).frame(width: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Morning briefing")
                        Text("When you sit down, 5–11 AM").font(.system(size: 13)).foregroundColor(theme.secondaryLabel)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: $briefing.morningOn).labelsHidden().toggleStyle(SwitchToggleStyle(tint: theme.toggleOn))
                }
                .padding(.vertical, 3)
                RowSeparator()
                SettingsRow {
                    Image(systemName: "moon.stars.fill").symbolRenderingMode(.multicolor).frame(width: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Evening wrap-up")
                        Text("When you're at the desk, 6–10 PM").font(.system(size: 13)).foregroundColor(theme.secondaryLabel)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: $briefing.eveningOn).labelsHidden().toggleStyle(SwitchToggleStyle(tint: theme.toggleOn))
                }
                .padding(.vertical, 3)
                RowSeparator()
                SettingsRow {
                    Image(systemName: "calendar.badge.clock").foregroundColor(theme.red).frame(width: 24)
                    Text("Heads-up before events")
                    Spacer(minLength: 8)
                    if briefing.headsUpOn {
                        Menu {
                            ForEach([5, 10, 15, 30], id: \.self) { minutes in
                                Button("\(minutes) min before") { briefing.headsUpMinutes = minutes }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text("\(briefing.headsUpMinutes) min")
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 12, weight: .bold))
                            }
                            .foregroundColor(theme.accent)
                        }
                    }
                    Toggle("", isOn: $briefing.headsUpOn).labelsHidden().toggleStyle(SwitchToggleStyle(tint: theme.toggleOn))
                }
                RowSeparator()
                HStack(spacing: 0) {
                    Button { briefing.playMorningNow() } label: {
                        SettingsRow {
                            Image(systemName: "play.circle.fill").foregroundColor(theme.accent)
                            Text("Hear morning").foregroundColor(theme.accent)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button { briefing.playEveningNow() } label: {
                        SettingsRow {
                            Image(systemName: "play.circle.fill").foregroundColor(theme.accent)
                            Text("Hear evening").foregroundColor(theme.accent)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .groupedBox()
        }
    }

    private var listeningSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Listening")
            VStack(spacing: 0) {
                SettingsRow {
                    Text("Microphone & speech")
                    Spacer(minLength: 8)
                    Text(permissionText).foregroundColor(theme.secondaryLabel)
                }
                RowSeparator()
                SettingsRow {
                    Text("Language")
                    Spacer(minLength: 8)
                    Menu {
                        ForEach(SpeechService.locales, id: \.id) { locale in
                            Button(locale.name) { speech.localeID = locale.id }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(SpeechService.locales.first { $0.id == speech.localeID }?.name ?? speech.localeID)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 12, weight: .bold))
                        }
                        .foregroundColor(theme.accent)
                    }
                }
                RowSeparator()
                SettingsRow {
                    Text("Works without internet")
                    Spacer(minLength: 8)
                    Text(speech.worksOffline ? "Yes" : "No, needs Wi-Fi")
                        .foregroundColor(speech.worksOffline ? theme.green : theme.secondaryLabel)
                }
            }
            .groupedBox()
            if speech.permission == .denied {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                } label: {
                    Text("Open iPhone Settings to allow Microphone and Speech Recognition")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(theme.accent)
                        .frame(height: 44)
                }
                .buttonStyle(.plain)
                .padding(.leading, 14)
            }
            footnote("Apple's speech recognition turns your voice into text. On this iPhone it may use Apple's servers, so it needs Wi-Fi.")

        }
    }

    private var repliesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Spoken replies")
            VStack(spacing: 0) {
                SettingsRow {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Keep listening after answers")
                        Text("Say a follow-up without tapping the mic")
                            .font(.system(size: 13))
                            .foregroundColor(theme.secondaryLabel)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: $assistant.keepListening)
                        .labelsHidden()
                        .toggleStyle(SwitchToggleStyle(tint: theme.toggleOn))
                }
                .padding(.vertical, 3)
                RowSeparator()
                SettingsRow {
                    Text("Speak replies out loud")
                    Spacer(minLength: 8)
                    Toggle("", isOn: $voice.enabled)
                        .labelsHidden()
                        .toggleStyle(SwitchToggleStyle(tint: theme.toggleOn))
                }
                RowSeparator()
                SettingsRow {
                    Text("Voice")
                    Spacer(minLength: 8)
                    Menu {
                        Button("Automatic") { voice.voiceID = "" }
                        ForEach(voice.voices, id: \.identifier) { item in
                            Button("\(item.name) · \(item.language)\(item.quality == .enhanced ? " · Enhanced" : "")") {
                                voice.voiceID = item.identifier
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(voice.voiceName)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 12, weight: .bold))
                        }
                        .foregroundColor(theme.accent)
                    }
                }
                RowSeparator()
                SettingsRow {
                    Text("Speed")
                    Spacer(minLength: 8)
                    Slider(value: $voice.rate, in: 0.35...0.6)
                        .frame(width: 150)
                    Text(String(format: "%.1f×", voice.rate / AVSpeechUtteranceDefaultSpeechRate))
                        .font(.system(size: 16).monospacedDigit())
                        .foregroundColor(theme.secondaryLabel)
                        .frame(width: 48, alignment: .trailing)
                }
                RowSeparator()
                Button {
                    voice.speak("Hello! I'm your desk companion. Try saying: remind me at six to call mom.", force: true)
                } label: {
                    SettingsRow {
                        Image(systemName: "play.circle.fill").foregroundColor(theme.accent)
                        Text("Test voice").foregroundColor(theme.accent)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .groupedBox()
            footnote("For a more natural voice, download an \"Enhanced\" voice in iPhone Settings → Accessibility → Spoken Content → Voices, then pick it here.")

        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("History")
            VStack(spacing: 0) {
                SettingsRow {
                    Text("Today's conversation")
                    Spacer(minLength: 8)
                    Text("\(assistant.messages.count) messages").foregroundColor(theme.secondaryLabel)
                }
                RowSeparator()
                Button { assistant.clearHistory() } label: {
                    SettingsRow {
                        Text("Clear conversation").foregroundColor(theme.red)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .groupedBox()
            footnote("Only today's conversation is kept, on this iPhone. Nothing is recorded.")
        }
    }

    private var permissionText: String {
        switch speech.permission {
        case .granted: return "Allowed"
        case .denied: return "Not allowed"
        case .unknown: return "Asks on first use"
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
