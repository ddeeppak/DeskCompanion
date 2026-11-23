import SwiftUI

/// Small banner at the top while a briefing or heads-up is spoken. Doesn't block the screen. Tap to dismiss.
struct AnnouncementBanner: View {
    let text: String
    let symbol: String
    let onDismiss: () -> Void
    @Environment(\.theme) private var theme

    init(text: String, symbol: String, onDismiss: @escaping () -> Void) {
        self.text = text
        self.symbol = symbol
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack {
            Button(action: onDismiss) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: symbol)
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 22))
                        .frame(width: 30)
                    Text(text)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.label)
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 14))
                        .foregroundColor(theme.accent)
                }
                .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
                .frame(width: 560)
                .background(theme.material)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(theme.cardBorder ?? Color.white.opacity(0.08), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.45), radius: 20, x: 0, y: 12)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Double-tap to dismiss")
            .padding(.top, 10)
            Spacer()
        }
    }
}
