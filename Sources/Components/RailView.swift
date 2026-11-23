import SwiftUI

/// 64 pt left rail: Home, Assistant, Today, Focus, Settings + mic button.
/// Selected item = filled symbol in the accent colour, others = outline in secondary label.
struct RailView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 4) {
            ForEach(AppScreen.allCases) { item in
                Button {
                    app.screen = item
                } label: {
                    Image(systemName: app.screen == item ? item.selectedSymbol : item.symbol)
                        .font(.system(size: 21, weight: app.screen == item ? .semibold : .regular))
                        .foregroundColor(app.screen == item ? theme.accent : theme.secondaryLabel)
                        .shadow(color: app.screen == item ? (theme.glow ?? .clear) : .clear, radius: 8)
                        .frame(width: 52, height: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
            }

            Spacer(minLength: 8)

            Button {
                app.screen = .assistant
            } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundColor(theme.onAccent)
                    .frame(width: 50, height: 50)
                    .background(Circle().fill(theme.accent))
                    .shadow(color: theme.glow ?? .clear, radius: 12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Talk to assistant")
        }
        .padding(.top, 14)
        .padding(.bottom, 16)
        .frame(width: 64)
        .frame(maxHeight: .infinity)
        .background(theme.bar.ignoresSafeArea())
        .overlay(Rectangle().fill(theme.separator).frame(width: 1), alignment: .trailing)
    }
}
