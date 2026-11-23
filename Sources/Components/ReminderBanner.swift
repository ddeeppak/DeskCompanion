import SwiftUI

/// S4 Reminder alert: dimmed screen + blurred banner (448 wide, radius 22) with Snooze 10 min / Done.
struct ReminderBanner: View {
    let task: TaskItem
    let onSnooze: () -> Void
    let onDone: () -> Void
    @Environment(\.theme) private var theme

    init(task: TaskItem, onSnooze: @escaping () -> Void, onDone: @escaping () -> Void) {
        self.task = task
        self.onSnooze = onSnooze
        self.onDone = onDone
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.38).ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    AppBadge()
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(task.title)
                                .font(.system(size: 17, weight: .semibold))
                                .lineLimit(2)
                            Spacer(minLength: 6)
                            Text("now")
                                .font(.system(size: 13))
                                .foregroundColor(theme.secondaryLabel)
                        }
                        Text(subtitle)
                            .font(.system(size: 15))
                            .foregroundColor(theme.secondaryLabel)
                    }
                }
                .padding(EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 16))

                Rectangle().fill(theme.separator).frame(height: 1)

                HStack(spacing: 0) {
                    Button(action: onSnooze) {
                        Text("Snooze 10 min")
                            .font(.system(size: 17))
                            .foregroundColor(theme.accent)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Rectangle().fill(theme.separator).frame(width: 1)
                    Button(action: onDone) {
                        Text("Done")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(theme.accent)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .frame(height: 48)
            }
            .frame(width: 448)
            .background(theme.material)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(theme.cardBorder ?? Color.white.opacity(0.08), lineWidth: 1))
            .shadow(color: Color.black.opacity(0.5), radius: 25, x: 0, y: 20)
            .padding(.top, 14)
        }
    }

    private var subtitle: String {
        if let due = task.dueDate { return "Reminder · due \(TimeText.time(due))" }
        return "Reminder"
    }
}

/// 40 pt app badge with the paw, gently pulsing.
private struct AppBadge: View {
    @Environment(\.theme) private var theme
    @State private var pulse = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.accent)
                .scaleEffect(pulse ? 1.6 : 1)
                .opacity(pulse ? 0 : 0.55)
                .animation(.easeOut(duration: 1.8).repeatForever(autoreverses: false), value: pulse)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(gradient: Gradient(colors: [theme.accent2, theme.accent]),
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Image("Paw")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
        }
        .frame(width: 40, height: 40)
        .onAppear { pulse = true }
    }
}
