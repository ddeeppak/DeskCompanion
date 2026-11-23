import SwiftUI

/// Full-screen alarm: big clock, label, Snooze and Stop.
struct AlarmRingingView: View {
    let alarm: Alarm
    let snoozeMinutes: Int
    let onSnooze: () -> Void
    let onStop: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var swing = false

    init(alarm: Alarm, snoozeMinutes: Int, onSnooze: @escaping () -> Void, onStop: @escaping () -> Void) {
        self.alarm = alarm
        self.snoozeMinutes = snoozeMinutes
        self.onSnooze = onSnooze
        self.onStop = onStop
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            ZStack {
                ThemeBackground()
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: "alarm.fill")
                            .font(.system(size: 24, weight: .bold))
                            .rotationEffect(.degrees(swing ? 14 : -14))
                            .animation(.easeInOut(duration: 0.18).repeatForever(autoreverses: true), value: swing)
                        Text(alarm.label)
                            .font(.system(size: 22, weight: .bold))
                            .lineLimit(1)
                    }
                    .foregroundColor(theme.accent)

                    Text(TimeText.clock(context.date))
                        .font(theme.clockFont(150))
                        .tracking(theme.tracking(for: 150))
                        .shadow(color: theme.glow ?? .clear, radius: 18)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.top, 4)

                    Text(DateText.long(context.date))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(theme.secondaryLabel)

                    HStack(spacing: 16) {
                        Button(action: onSnooze) {
                            Text("Snooze \(snoozeMinutes) min")
                                .font(.system(size: 19, weight: .bold))
                                .foregroundColor(theme.label)
                                .frame(width: 230, height: 64)
                                .background(RoundedRectangle(cornerRadius: theme.controlRadius + 6, style: .continuous)
                                                .fill(theme.fill))
                        }
                        .buttonStyle(.plain)
                        Button(action: onStop) {
                            Text("Stop")
                                .font(.system(size: 19, weight: .bold))
                                .foregroundColor(theme.onAccent)
                                .frame(width: 230, height: 64)
                                .background(RoundedRectangle(cornerRadius: theme.controlRadius + 6, style: .continuous)
                                                .fill(theme.accent))
                                .shadow(color: theme.glow ?? .clear, radius: 12)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 22)
                }
            }
            .foregroundColor(theme.label)
            .onAppear { swing = !reduceMotion }
        }
    }
}
