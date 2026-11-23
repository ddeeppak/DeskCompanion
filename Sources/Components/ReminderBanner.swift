import SwiftUI

/// S4-style alert: dimmed screen + blurred banner (448 wide, radius 22) with two buttons.
/// Used for due reminders ("Snooze 10 min / Done") and finished timers ("+1 min / Stop").
struct AlertBanner: View {
    let title: String
    let subtitle: String
    let symbol: String?          // nil = paw badge
    let secondaryTitle: String
    let primaryTitle: String
    let onSecondary: () -> Void
    let onPrimary: () -> Void
    @Environment(\.theme) private var theme

    init(title: String, subtitle: String, symbol: String? = nil,
         secondaryTitle: String, primaryTitle: String,
         onSecondary: @escaping () -> Void, onPrimary: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.secondaryTitle = secondaryTitle
        self.primaryTitle = primaryTitle
        self.onSecondary = onSecondary
        self.onPrimary = onPrimary
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.38).ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    AppBadge(symbol: symbol)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(title)
                                .font(.system(size: 17, weight: .bold))
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
                    Button(action: onSecondary) {
                        Text(secondaryTitle)
                            .font(.system(size: 17))
                            .foregroundColor(theme.accent)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Rectangle().fill(theme.separator).frame(width: 1)
                    Button(action: onPrimary) {
                        Text(primaryTitle)
                            .font(.system(size: 17, weight: .bold))
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
}

/// 40 pt app badge (paw, or an SF Symbol), gently pulsing.
private struct AppBadge: View {
    let symbol: String?
    @Environment(\.theme) private var theme
    @State private var pulse = false

    init(symbol: String?) { self.symbol = symbol }

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
            if let symbol = symbol {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
            } else {
                Image("Paw")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .foregroundColor(.white)
                    .frame(width: 24, height: 24)
            }
        }
        .frame(width: 40, height: 40)
        .onAppear { pulse = true }
    }
}
