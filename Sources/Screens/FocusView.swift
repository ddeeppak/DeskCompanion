import SwiftUI

/// 07 Focus timer (+ S3 "Session done"). Ring 236 · time 64 (number font) · controls 62 · side column 252.
struct FocusView: View {
    @EnvironmentObject private var focus: FocusTimer
    @EnvironmentObject private var sound: SoundEngine
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScreenHeader(title: "Focus")
            HStack(alignment: .top, spacing: 16) {
                Group {
                    if focus.state == .finished {
                        DoneView()
                    } else {
                        RunningView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                FocusSide()
                    .frame(width: 252)
            }
        }
        .screenPadding()
    }
}

// MARK: - Ring + controls

private struct RunningView: View {
    @EnvironmentObject private var focus: FocusTimer
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().stroke(theme.fill, lineWidth: 10)
                Circle()
                    .trim(from: 0, to: CGFloat(focus.progress))
                    .stroke(focus.phase == .focus ? theme.accent : theme.green,
                            style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: theme.glow ?? .clear, radius: 8)
                    .animation(.linear(duration: 0.5), value: focus.progress)
                VStack(spacing: 4) {
                    Text(timeText)
                        .font(theme.numberFont(64))
                        .tracking(-64 * 0.02)
                        .shadow(color: theme.glow ?? .clear, radius: 12)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(subtitle)
                        .font(.system(size: 15))
                        .foregroundColor(theme.secondaryLabel)
                }
                .padding(.horizontal, 20)
            }
            .frame(width: 226, height: 226)
            .padding(5)

            HStack(spacing: 18) {
                CircleControl(title: "Reset", fill: theme.fill, foreground: theme.label, bold: false) { focus.reset() }
                CircleControl(title: playTitle, fill: theme.accentTint, foreground: theme.accent, bold: true) { focus.toggle() }
                CircleControl(title: "Skip", fill: theme.fill, foreground: theme.label, bold: false) { focus.skip() }
            }
        }
    }

    private var timeText: String {
        let total = Int(focus.remaining.rounded(.up))
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }

    private var playTitle: String {
        switch focus.state {
        case .running: return "Pause"
        case .paused: return "Resume"
        default: return "Start"
        }
    }

    private var subtitle: String {
        if focus.phase == .rest { return focus.state == .paused ? "Break paused" : "Break · \(focus.breakMinutes) min" }
        let count = "\(focus.session) of \(focus.sessionsPerCycle)"
        switch focus.state {
        case .paused: return "Paused · \(count)"
        case .ready: return "Ready · \(count)"
        default: return "Focus · \(count)"
        }
    }
}

/// 62 pt round button with a thin outer ring (iOS Clock style).
private struct CircleControl: View {
    let title: String
    let fill: Color
    let foreground: Color
    let bold: Bool
    let action: () -> Void

    init(title: String, fill: Color, foreground: Color, bold: Bool, action: @escaping () -> Void) {
        self.title = title
        self.fill = fill
        self.foreground = foreground
        self.bold = bold
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: bold ? .semibold : .medium))
                .foregroundColor(foreground)
                .frame(width: 62, height: 62)
                .background(Circle().fill(fill))
                .overlay(Circle().stroke(fill, lineWidth: 1.5).padding(-2.75))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - S3 Session done

private struct DoneView: View {
    @EnvironmentObject private var focus: FocusTimer
    @EnvironmentObject private var sound: SoundEngine
    @Environment(\.theme) private var theme
    @State private var pulse = false

    var body: some View {
        let focusEnded = focus.lastFinishedPhase == .focus
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(theme.green, lineWidth: 6)
                    .scaleEffect(pulse ? 1.6 : 1)
                    .opacity(pulse ? 0 : 0.55)
                    .animation(.easeOut(duration: 2).repeatForever(autoreverses: false), value: pulse)
                Circle().stroke(theme.green, lineWidth: 10)
                VStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 46))
                        .foregroundColor(theme.green)
                    Text(focusEnded ? "Session done" : "Break over")
                        .font(.system(size: 22, weight: .bold))
                    Text(focusEnded
                         ? "\(focus.lastFinishedMinutes) min · \(focus.sessionsDone) of \(focus.sessionsPerCycle)"
                         : "Ready for session \(focus.session)")
                        .font(.system(size: 15))
                        .foregroundColor(theme.secondaryLabel)
                }
            }
            .frame(width: 226, height: 226)
            .padding(5)
            .onAppear { pulse = true }

            HStack(spacing: 10) {
                Button { focus.extend(minutes: 5) } label: {
                    Text("+5 min")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(theme.label)
                        .padding(.horizontal, 18)
                        .frame(height: 48)
                        .background(RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous).fill(theme.fill))
                }
                .buttonStyle(.plain)
                Button {
                    if focusEnded { focus.startBreak() } else { focus.startFocus() }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "play.fill").font(.system(size: 14))
                        Text(focusEnded ? "Start \(focus.breakMinutes)-min break" : "Start focus")
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.onAccent)
                    .padding(.horizontal, 20)
                    .frame(height: 48)
                    .background(RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous).fill(theme.accent))
                    .shadow(color: theme.glow ?? .clear, radius: 10)
                }
                .buttonStyle(.plain)
            }

            if sound.chimePlaying {
                Button { sound.stopChime() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "bell.fill").font(.system(size: 14))
                        Text("Chime playing · tap to stop")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.accent)
                    .frame(height: 30)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Side column

private struct FocusSide: View {
    @EnvironmentObject private var focus: FocusTimer
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Working on")
                    .font(.system(size: 13))
                    .foregroundColor(theme.secondaryLabel)
                TextField("What are you focusing on?", text: $focus.task)
                    .font(.system(size: 17, weight: .semibold))
                    .submitLabel(.done)
            }
            .card(padding: EdgeInsets(top: 11, leading: 13, bottom: 11, trailing: 13))

            VStack(alignment: .leading, spacing: 7) {
                Text("Timer")
                    .font(.system(size: 13))
                    .foregroundColor(theme.secondaryLabel)
                SegmentedBar(options: FocusTimer.Preset.allCases.map { ($0, $0.label) }, selection: $focus.preset)
                if focus.preset == .custom {
                    HStack(spacing: 6) {
                        MinuteStepper(label: "Focus", value: $focus.customFocusMinutes, range: 5...120, step: 5)
                        MinuteStepper(label: "Break", value: $focus.customBreakMinutes, range: 1...30, step: 1)
                    }
                }
            }
            .card(padding: EdgeInsets(top: 11, leading: 13, bottom: 11, trailing: 13))

            VStack(alignment: .leading, spacing: 7) {
                Text("Sound")
                    .font(.system(size: 13))
                    .foregroundColor(theme.secondaryLabel)
                SegmentedBar(options: SoundEngine.Ambient.allCases.map { ($0, $0.label) }, selection: $focus.ambient)
            }
            .card(padding: EdgeInsets(top: 11, leading: 13, bottom: 11, trailing: 13))

            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text(Self.duration(focus.liveFocusedToday))
                        .font(theme.numberFont(28))
                        .shadow(color: theme.glow ?? .clear, radius: 8)
                    Text("Focused today")
                        .font(.system(size: 13))
                        .foregroundColor(theme.secondaryLabel)
                }
                Spacer(minLength: 4)
                HStack(spacing: 5) {
                    ForEach(0..<focus.sessionsPerCycle, id: \.self) { index in
                        Circle()
                            .fill(index < focus.sessionsDone ? theme.accent : theme.fill)
                            .frame(width: 11, height: 11)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .card(padding: EdgeInsets(top: 11, leading: 13, bottom: 11, trailing: 13))
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        let h = minutes / 60
        let m = minutes % 60
        return h > 0 ? "\(h) h \(m) m" : "\(m) m"
    }
}

/// iOS-style segmented control drawn with the theme (design: 38 pt segments, selected segment raised).
struct SegmentedBar<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    @Environment(\.theme) private var theme

    init(options: [(Value, String)], selection: Binding<Value>) {
        self.options = options
        self._selection = selection
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let selected = option.0 == selection
                Button {
                    selection = option.0
                } label: {
                    Text(option.1)
                        .font(.system(size: 14, weight: selected ? .semibold : .regular).monospacedDigit())
                        .foregroundColor(theme.label)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(selected ? theme.segmentSelected : Color.clear)
                                        .shadow(color: selected ? Color.black.opacity(0.18) : .clear, radius: 4, y: 3))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.fill))
    }
}

private struct MinuteStepper: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    @Environment(\.theme) private var theme

    init(label: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int) {
        self.label = label
        self._value = value
        self.range = range
        self.step = step
    }

    var body: some View {
        HStack(spacing: 2) {
            button("minus") { value = max(range.lowerBound, value - step) }
            VStack(spacing: 0) {
                Text("\(value)").font(.system(size: 15, weight: .semibold).monospacedDigit())
                Text(label).font(.system(size: 11)).foregroundColor(theme.secondaryLabel)
            }
            .frame(maxWidth: .infinity)
            button("plus") { value = min(range.upperBound, value + step) }
        }
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.fill))
    }

    private func button(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.accent)
                .frame(width: 32, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
