import SwiftUI
import AVFoundation
import UIKit

/// Settings → Voice: speech recognition language, spoken replies, voice and speed, history.
struct VoiceSettings: View {
    @EnvironmentObject private var speech: SpeechService
    @EnvironmentObject private var voice: VoiceService
    @EnvironmentObject private var assistant: AssistantService
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            listeningSection
            repliesSection
                .padding(.top, 12)
            historySection
                .padding(.top, 12)
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
