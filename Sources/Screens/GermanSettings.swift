import SwiftUI

/// Settings → German: progress, practice, word of the day and your words.
struct GermanSettings: View {
    @EnvironmentObject private var german: GermanStore
    @EnvironmentObject private var assistant: AssistantService
    @Environment(\.theme) private var theme
    @State private var confirmReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            progressSection
            wordsSection
                .padding(.top, 12)
        }
        .alert("Start German from scratch?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { german.reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes your \(german.words.count) practised words and your streak.")
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("German")
            HStack(spacing: 10) {
                stat("\(german.words.count)", "words practised")
                stat("\(german.learnedCount)", "well known")
                stat("\(german.due.count)", "due today")
                stat("\(german.streak)", german.streak == 1 ? "day streak" : "days streak")
            }
            VStack(spacing: 0) {
                Button { assistant.startGerman() } label: {
                    SettingsRow {
                        Image(systemName: "play.circle.fill").foregroundColor(theme.accent)
                        Text("Practise now").foregroundColor(theme.accent)
                        Spacer(minLength: 0)
                        Text("or say “Let's practise German”")
                            .font(.system(size: 13))
                            .foregroundColor(theme.secondaryLabel)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                RowSeparator()
                SettingsRow {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Word of the day")
                        let word = german.wordOfTheDay()
                        Text("In the morning briefing · today: \(word.de), \(word.en)")
                            .font(.system(size: 13))
                            .foregroundColor(theme.secondaryLabel)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: $german.wordOfDayOn)
                        .labelsHidden()
                        .toggleStyle(SwitchToggleStyle(tint: theme.toggleOn))
                }
                .padding(.vertical, 3)
            }
            .groupedBox()
            footnote("The AI on your PC is your tutor: it asks one word at a time, German is read in a German voice, and your German answers are heard in German. Words you get right come back later (1, 2, 4, 8, 16 days), ones you miss come back tomorrow. Say “stop” or “that's enough” to finish.")
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(theme.numberFont(28))
            Text(label).font(.system(size: 13)).foregroundColor(theme.secondaryLabel).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var wordsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Your words")
            VStack(spacing: 0) {
                if german.words.isEmpty {
                    SettingsRow {
                        Text("No words yet: start a practice").foregroundColor(theme.secondaryLabel)
                        Spacer(minLength: 0)
                    }
                } else {
                    ForEach(german.words.sorted { $0.due < $1.due }) { word in
                        SettingsRow {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(word.de).font(.system(size: 16, weight: .semibold))
                                Text(word.en).font(.system(size: 13)).foregroundColor(theme.secondaryLabel)
                            }
                            Spacer(minLength: 8)
                            boxDots(word.box)
                            Text(word.seen == 0 ? "new" : "\(word.right)/\(word.seen)")
                                .font(.system(size: 13))
                                .foregroundColor(theme.secondaryLabel)
                                .frame(width: 44, alignment: .trailing)
                        }
                        RowSeparator()
                    }
                    Button { confirmReset = true } label: {
                        SettingsRow {
                            Text("Start from scratch").foregroundColor(theme.red)
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

    private func boxDots(_ box: Int) -> some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { i in
                Circle()
                    .fill(i <= box ? theme.green : theme.fill)
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityLabel("Box \(box) of 5")
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(theme.secondaryLabel)
            .padding(.leading, 14)
            .fixedSize(horizontal: false, vertical: true)
    }
}
