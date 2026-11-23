import SwiftUI
import UIKit

/// 04 Assistant · listening · 05 answer · S5 didn't understand. Layout and type follow the design.
struct AssistantView: View {
    @EnvironmentObject private var assistant: AssistantService
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScreenHeader(title: "Assistant")
            switch assistant.phase {
            case .idle: IdleView()
            case .listening: ListeningView()
            case .answered: AnswerView()
            case .misheard: MisheardView()
            case .noPermission: NoPermissionView()
            }
        }
        .screenPadding()
    }
}

// MARK: - Shared pieces

/// 116 pt orb: conic accent gradient, breathing; expanding rings while listening; muted "?" when misheard.
struct AssistantOrb: View {
    let active: Bool
    let muted: Bool
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    init(active: Bool, muted: Bool = false) {
        self.active = active
        self.muted = muted
    }

    var body: some View {
        ZStack {
            if !muted {
                Circle()
                    .fill(RadialGradient(gradient: Gradient(colors: [theme.accent.opacity(0.45), theme.accent.opacity(0)]),
                                         center: .center, startRadius: 0, endRadius: 80))
                    .frame(width: 152, height: 152)
                if active && !reduceMotion {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .stroke(theme.accent, lineWidth: 2)
                            .scaleEffect(animate ? 1.8 : 1)
                            .opacity(animate ? 0 : 0.5)
                            .animation(.easeOut(duration: 2.4).repeatForever(autoreverses: false).delay(Double(index) * 0.8),
                                       value: animate)
                    }
                }
            }
            Group {
                if muted {
                    Circle().fill(theme.fill)
                } else {
                    Circle().fill(AngularGradient(gradient: Gradient(colors: [theme.accent, theme.accent2, theme.accent]),
                                                  center: .center, angle: .degrees(210)))
                }
            }
                .overlay(
                    Circle().fill(RadialGradient(gradient: Gradient(colors: [Color.white.opacity(muted ? 0 : 0.7), Color.white.opacity(0)]),
                                                 center: UnitPoint(x: 0.32, y: 0.26), startRadius: 0, endRadius: 44))
                )
                .scaleEffect(!muted && !reduceMotion && animate ? 1.05 : 1)
                .animation(muted || reduceMotion ? nil : .easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: animate)
            Image(systemName: muted ? "questionmark" : "mic.fill")
                .font(.system(size: muted ? 44 : 38, weight: .bold))
                .foregroundColor(muted ? theme.orange : .white)
                .shadow(color: Color.black.opacity(muted ? 0 : 0.25), radius: 1, y: 1)
        }
        .frame(width: 116, height: 116)
        .onAppear { animate = true }
    }
}

/// Voice level bars (32 bars, max 34 pt). Follows the real microphone level while listening.
struct VoiceBars: View {
    let level: Float
    let count: Int
    let maxHeight: CGFloat
    let barWidth: CGFloat
    @Environment(\.theme) private var theme

    init(level: Float, count: Int = 32, maxHeight: CGFloat = 34, barWidth: CGFloat = 3) {
        self.level = level
        self.count = count
        self.maxHeight = maxHeight
        self.barWidth = barWidth
    }

    var body: some View {
        HStack(alignment: .center, spacing: barWidth) {
            ForEach(0..<count, id: \.self) { index in
                let shape = 0.3 + 0.7 * abs(sin(Double(index) * 1.7 + 0.4))
                let height = max(3, maxHeight * CGFloat(shape) * CGFloat(0.25 + 0.75 * Double(level)))
                Capsule()
                    .fill(theme.accent)
                    .frame(width: barWidth, height: height)
            }
        }
        .frame(height: maxHeight)
        .animation(.easeOut(duration: 0.12), value: level)
    }
}

/// Small animated "speaking" bars.
private struct SpeakingBars: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<12, id: \.self) { index in
                Capsule()
                    .fill(theme.accent)
                    .frame(width: 2, height: 14 * CGFloat(0.3 + 0.7 * abs(sin(Double(index) * 1.7 + 0.4))))
                    .scaleEffect(y: on ? 1 : 0.3)
                    .animation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true).delay(Double(index % 5) * 0.09),
                               value: on)
            }
        }
        .frame(height: 14)
        .onAppear { on = !reduceMotion }
    }
}

private struct SuggestionChip: View {
    let symbol: String
    let text: String
    let action: () -> Void
    @Environment(\.theme) private var theme

    init(symbol: String, text: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.text = text
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(theme.accent)
                Text(text)
                    .font(.system(size: 15))
                    .foregroundColor(theme.label)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(Capsule().fill(theme.fill))
            .overlay(Capsule().stroke(theme.cardBorder ?? .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct DefaultChips: View {
    @EnvironmentObject private var assistant: AssistantService

    var body: some View {
        HStack(spacing: 10) {
            SuggestionChip(symbol: "timer", text: "Set a 10-minute timer") { assistant.handle("Set a 10 minute timer") }
            SuggestionChip(symbol: "calendar", text: "What’s on today?") { assistant.handle("What's on today") }
            SuggestionChip(symbol: "list.bullet", text: "Add milk to my list") { assistant.handle("Add milk to my list") }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Idle

private struct IdleView: View {
    @EnvironmentObject private var assistant: AssistantService
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            Button { assistant.listen() } label: {
                VStack(spacing: 10) {
                    AssistantOrb(active: false)
                    Text("Tap to talk")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(theme.accent)
                    Text("Timers, alarms, reminders, lists, calendar and weather work offline.")
                        .font(.system(size: 15))
                        .foregroundColor(theme.secondaryLabel)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start listening")
            DefaultChips()
        }
    }
}

// MARK: - 04 Listening

private struct ListeningView: View {
    @EnvironmentObject private var assistant: AssistantService
    @EnvironmentObject private var speech: SpeechService
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var caretOn = true

    var body: some View {
        VStack(spacing: 0) {
            Button { assistant.stopListening() } label: {
                VStack(spacing: 10) {
                    AssistantOrb(active: true)
                        .padding(.bottom, 6)
                    VoiceBars(level: speech.level)
                    Text("Listening…")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(theme.accent)
                    HStack(spacing: 2) {
                        Text(speech.transcript.isEmpty ? "“…" : "“\(speech.transcript)")
                            .font(.system(size: 26, weight: .bold))
                            .tracking(-26 * 0.015)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                        Rectangle()
                            .fill(theme.accent)
                            .frame(width: 2, height: 26)
                            .opacity(caretOn ? 1 : 0)
                        Text("”").font(.system(size: 26, weight: .bold))
                    }
                    .frame(maxWidth: 540)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Listening. Double-tap to stop")
            DefaultChips()
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { caretOn = false }
        }
    }
}

// MARK: - S5 Didn't catch that

private struct MisheardView: View {
    @EnvironmentObject private var assistant: AssistantService
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            Button { assistant.listen() } label: {
                VStack(spacing: 9) {
                    AssistantOrb(active: false, muted: true)
                    Text("Didn’t catch that")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(theme.orange)
                    if !assistant.heard.isEmpty {
                        Text("“\(assistant.heard)”")
                            .font(.system(size: 17))
                            .foregroundColor(theme.secondaryLabel)
                            .lineLimit(1)
                            .frame(maxWidth: 520)
                    }
                    Text(assistant.heard.isEmpty ? "I didn’t hear anything. Tap the mic and try again."
                                                 : "Sorry, I didn’t understand. Try saying it another way.")
                        .font(.system(size: 24, weight: .bold))
                        .tracking(-24 * 0.015)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 10) {
                Button { assistant.listen() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "mic.fill").font(.system(size: 16))
                        Text("Try again").font(.system(size: 15, weight: .bold))
                    }
                    .foregroundColor(theme.onAccent)
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                    .background(Capsule().fill(theme.accent))
                    .shadow(color: theme.glow ?? .clear, radius: 10)
                }
                .buttonStyle(.plain)
                SuggestionChip(symbol: "bell.fill", text: "Remind me at 6 to call Mom") {
                    assistant.handle("Remind me at 6 pm to call Mom")
                }
                SuggestionChip(symbol: "calendar", text: "What’s on today?") { assistant.handle("What's on today") }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - 05 Answer

private struct AnswerView: View {
    @EnvironmentObject private var assistant: AssistantService
    @EnvironmentObject private var voice: VoiceService
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            conversation
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            side
                .frame(width: 236)
        }
    }

    /// Scrollable conversation, kept scrolled to the newest message (long replies are never cut off).
    private var conversation: some View {
        let recent = Array(assistant.messages.suffix(10))
        let lastUserIndex = recent.lastIndex { $0.fromUser } ?? 0
        return GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        Spacer(minLength: 0)
                        ForEach(Array(recent.enumerated()), id: \.element.id) { index, message in
                            bubble(message, faded: index < lastUserIndex, isLast: index == recent.count - 1)
                                .id(message.id)
                        }
                    }
                    .frame(minHeight: geo.size.height, alignment: .bottom)
                }
                .onAppear { scrollToEnd(proxy, recent) }
                .onChange(of: assistant.messages.count) { _ in scrollToEnd(proxy, recent) }
                .onChange(of: voice.speaking) { _ in scrollToEnd(proxy, recent) }
            }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, _ recent: [ChatMessage]) {
        guard let last = assistant.messages.last else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }

    @ViewBuilder
    private func bubble(_ message: ChatMessage, faded: Bool, isLast: Bool) -> some View {
        if message.fromUser {
            HStack {
                Spacer(minLength: 60)
                Text(message.text)
                    .font(.system(size: 16))
                    .foregroundColor(theme.onAccent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 19, style: .continuous).fill(theme.accent))
            }
            .opacity(faded ? 0.45 : 1)
        } else {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: message.source == "ai" ? "desktopcomputer" : "iphone")
                            .font(.system(size: 13))
                        Text(message.source == "ai" ? "Local AI" : "Offline command")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .foregroundColor(theme.secondaryLabel)
                    .padding(.leading, 6)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(message.text)
                            .font(.system(size: faded ? 16 : 17))
                            .fixedSize(horizontal: false, vertical: true)
                        if isLast && voice.speaking {
                            HStack(spacing: 7) {
                                Image(systemName: "speaker.wave.2.fill").font(.system(size: 14))
                                Text("Speaking").font(.system(size: 13, weight: .bold))
                                SpeakingBars()
                            }
                            .foregroundColor(theme.accent)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 19, style: .continuous).fill(theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).stroke(theme.cardBorder ?? .clear, lineWidth: 1))
                }
                Spacer(minLength: 40)
            }
            .opacity(faded ? 0.45 : 1)
        }
    }

    private var side: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let card = assistant.card {
                ResultCard(card: card)
            }
            Text(footnote)
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryLabel)
                .padding(.horizontal, 4)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { assistant.listen() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill").font(.system(size: 17))
                    Text("Ask again").font(.system(size: 17, weight: .bold))
                }
                .foregroundColor(theme.onAccent)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous).fill(theme.accent))
                .shadow(color: theme.glow ?? .clear, radius: 10)
            }
            .buttonStyle(.plain)
        }
    }

    private var footnote: String {
        let seconds = max(0.1, assistant.handledIn)
        return "Handled on this iPhone in \(String(format: "%.1f", seconds)) s. General questions go to the AI on your PC (coming in step 6)."
    }
}

private struct ResultCard: View {
    let card: ActionCard
    @EnvironmentObject private var assistant: AssistantService
    @Environment(\.theme) private var theme

    init(card: ActionCard) { self.card = card }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint))
                Text(assistant.undone ? "Undone" : card.heading)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(theme.secondaryLabel)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if card.undo != nil && !assistant.undone {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(theme.green)
                }
            }
            Text(card.title)
                .font(.system(size: 20, weight: .bold))
                .tracking(-0.2)
                .strikethrough(assistant.undone)
                .lineLimit(2)
                .padding(.top, 10)
            Text(card.detail)
                .font(.system(size: 15).monospacedDigit())
                .foregroundColor(theme.secondaryLabel)
                .lineLimit(2)
            if (card.canEdit || card.undo != nil) && !assistant.undone {
                HStack(spacing: 8) {
                    if card.canEdit {
                        tinted("Edit", symbol: "pencil") { assistant.edit() }
                    }
                    if card.undo != nil {
                        tinted("Undo", symbol: "arrow.uturn.backward") { assistant.undo() }
                    }
                }
                .padding(.top, 12)
            }
        }
        .card(padding: EdgeInsets(top: 13, leading: 14, bottom: 13, trailing: 14))
    }

    private func tinted(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 15))
                Text(title).font(.system(size: 15, weight: .bold))
            }
            .foregroundColor(theme.accent)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous).fill(theme.accentTint))
        }
        .buttonStyle(.plain)
    }

    private var symbol: String {
        switch card.kind {
        case .reminder: return "list.bullet"
        case .task: return "checklist"
        case .timer: return "timer"
        case .alarm: return "alarm.fill"
        case .focus: return "scope"
        case .weather: return "cloud.sun.fill"
        case .calendar: return "calendar"
        case .info: return "info"
        }
    }

    private var tint: Color {
        switch card.kind {
        case .reminder: return theme.orange
        case .task: return theme.green
        case .timer: return theme.accent
        case .alarm: return theme.red
        case .focus: return theme.indigo
        case .weather: return theme.accent2
        case .calendar: return theme.red
        case .info: return theme.indigo
        }
    }
}

// MARK: - Permission off

private struct NoPermissionView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 44))
                .foregroundColor(theme.secondaryLabel)
            Text("Microphone or Speech Recognition is off")
                .font(.system(size: 20, weight: .bold))
            Text("Allow both for Desk Companion in the iPhone Settings app.")
                .font(.system(size: 15))
                .foregroundColor(theme.secondaryLabel)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            } label: {
                Text("Open Settings")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(theme.onAccent)
                    .padding(.horizontal, 20)
                    .frame(height: 44)
                    .background(Capsule().fill(theme.accent))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
