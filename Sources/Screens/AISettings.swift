import SwiftUI

/// Settings → AI & Network: the Desk Bridge on your PC (found automatically), pairing code, model, speed, test.
struct AISettings: View {
    @EnvironmentObject private var ai: AIService
    @EnvironmentObject private var voice: VoiceService
    @Environment(\.theme) private var theme
    @State private var testing = false
    @State private var testResult = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            serverSection
            setupSection
                .padding(.top, 12)
            memorySection
                .padding(.top, 12)
            footnote("On your PC, open the DeskCompanion folder → bridge → double-click start_bridge.bat. Keep that window open. It shows the 6-digit pairing code. Your PC and iPhone must be on the same Wi-Fi, and Windows must treat that Wi-Fi as a Private network.")
            footnote("The AI can also do things for you: \"remind me after lunch to call the bank\" or \"wake me 30 minutes before my first meeting\". Questions go to Claude through your PC; event and task titles are included only when sharing is on.")
        }
        .onAppear {
            ai.startDiscovery()
            ai.check()
            ai.loadMemories()
        }
    }

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Local AI server")
            VStack(spacing: 0) {
                SettingsRow {
                    Circle().fill(statusColor).frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ai.serverName.isEmpty ? "Looking for your PC…" : ai.serverName)
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundColor(theme.secondaryLabel)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(statusText).foregroundColor(ai.state == .online ? theme.secondaryLabel : statusColor)
                }
                .padding(.vertical, 4)
                RowSeparator()
                SettingsRow {
                    Text("Model")
                    Spacer(minLength: 8)
                    Text(ai.model.isEmpty ? "—" : "\(ai.model) · Claude Code")
                        .foregroundColor(theme.secondaryLabel)
                }
                RowSeparator()
                SettingsRow {
                    Text("Reply speed")
                    Spacer(minLength: 8)
                    Text(ai.lastAnswerMs.map { "~\(String(format: "%.1f", Double($0) / 1000)) s" } ?? "—")
                        .font(.system(size: 16).monospacedDigit())
                        .foregroundColor(theme.secondaryLabel)
                }
            }
            .groupedBox()
        }
    }

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Setup")
            VStack(spacing: 0) {
                SettingsRow {
                    Text("Pairing code")
                    Spacer(minLength: 8)
                    TextField("6 digits", text: codeBinding)
                        .keyboardType(.numbersAndPunctuation)
                        .submitLabel(.done)
                        .multilineTextAlignment(.trailing)
                        .font(.system(size: 17, weight: .bold).monospacedDigit())
                        .frame(width: 120)
                        .accessibilityLabel("Pairing code")
                }
                RowSeparator()
                SettingsRow {
                    Text("PC address")
                    Spacer(minLength: 8)
                    TextField(ai.foundAutomatically ? (ai.host ?? "Automatic") : "Automatic", text: $ai.manualHost)
                        .keyboardType(.numbersAndPunctuation)
                        .submitLabel(.done)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 170)
                        .accessibilityLabel("PC address, leave empty for automatic")
                }
                RowSeparator()
                SettingsRow {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Share today's events and tasks")
                        Text("Lets the AI answer \"what should I do first?\"")
                            .font(.system(size: 13))
                            .foregroundColor(theme.secondaryLabel)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: $ai.shareDay)
                        .labelsHidden()
                        .toggleStyle(SwitchToggleStyle(tint: theme.toggleOn))
                }
                .padding(.vertical, 3)
                RowSeparator()
                Button {
                    ai.manualHost = ""
                    ai.startDiscovery()
                    ai.check()
                } label: {
                    SettingsRow {
                        Image(systemName: "magnifyingglass").foregroundColor(theme.accent)
                        Text("Search again").foregroundColor(theme.accent)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                RowSeparator()
                Button(action: test) {
                    SettingsRow {
                        if testing { ProgressView() } else { Image(systemName: "play.circle.fill").foregroundColor(theme.accent) }
                        Text("Test the AI").foregroundColor(theme.accent)
                        Spacer(minLength: 8)
                        Text(testResult)
                            .font(.system(size: 14))
                            .foregroundColor(theme.secondaryLabel)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(testing || !ai.isConfigured)
            }
            .groupedBox()
        }
    }

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Memory")
            VStack(spacing: 0) {
                if ai.memories.isEmpty {
                    SettingsRow {
                        Image(systemName: "brain.head.profile").foregroundColor(theme.accent2).frame(width: 24)
                        Text(ai.state == .online ? "Nothing remembered yet" : "Connect to see what the AI remembers")
                            .foregroundColor(theme.secondaryLabel)
                        Spacer(minLength: 0)
                    }
                } else {
                    ForEach(ai.memories, id: \.self) { fact in
                        SettingsRow {
                            Image(systemName: "brain.head.profile").foregroundColor(theme.accent2).frame(width: 24)
                            Text(fact).lineLimit(2)
                            Spacer(minLength: 8)
                            Button { ai.removeMemory(fact) } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundColor(theme.red)
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Forget \(fact)")
                        }
                        RowSeparator()
                    }
                    Button { ai.clearMemories() } label: {
                        SettingsRow {
                            Text("Forget everything").foregroundColor(theme.red)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .groupedBox()
            footnote("Say \"remember that…\" to add, \"forget…\" to remove, or \"what do you know about me?\". Stored only on your PC, in bridge/memory.local.json.")
        }
    }

    // MARK: Helpers

    private var codeBinding: Binding<String> {
        Binding(get: { ai.code },
                set: { ai.code = String($0.filter { $0.isNumber }.prefix(6)) })
    }

    private var statusColor: Color {
        switch ai.state {
        case .online: return theme.green
        case .offline, .wrongCode: return theme.red
        case .notSetUp, .searching: return theme.orange
        }
    }

    private var statusText: String {
        switch ai.state {
        case .online: return "Connected"
        case .offline: return "Offline"
        case .wrongCode: return "Wrong code"
        case .searching: return "Searching…"
        case .notSetUp: return ai.host == nil ? "Searching…" : "Enter code"
        }
    }

    private var subtitle: String {
        guard let host = ai.host else { return "Start Desk Bridge on your PC" }
        return (ai.foundAutomatically ? "Found automatically on Wi-Fi · " : "Manual address · ") + host
    }

    private func test() {
        testing = true
        testResult = ""
        Task {
            do {
                let result = try await ai.ask("Say hello in five words.", context: [:], history: []) { _ in }
                await MainActor.run {
                    testResult = "\(result.answer) (\(String(format: "%.1f", Double(result.ms) / 1000)) s)"
                    voice.speak(result.answer, force: true)
                    testing = false
                }
            } catch {
                await MainActor.run {
                    testResult = error.localizedDescription
                    testing = false
                }
            }
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
