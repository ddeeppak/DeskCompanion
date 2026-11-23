import SwiftUI

/// 03 Away: nobody at the desk. Small dim clock that drifts a little each minute,
/// date + temperature, and a note. Tap (or sit down) to wake. Design: clock 68, #6e6e73.
struct AwayView: View {
    @EnvironmentObject private var weather: WeatherService
    @EnvironmentObject private var presence: PresenceService
    @Environment(\.theme) private var theme

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            let minute = Calendar.current.component(.minute, from: now)
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    Color.black.ignoresSafeArea()

                    VStack(alignment: .leading, spacing: 6) {
                        Text(TimeText.clock(now))
                            .font(theme.numberFont(68))
                            .tracking(-68 * 0.03)
                            .foregroundColor(Color(hex: 0x6E6E73))
                        Text(subtitle(now))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Color(hex: 0x545458))
                    }
                    // Drift slowly around the right-middle of the screen (changes once a minute).
                    .offset(x: geo.size.width * 0.52 + CGFloat((minute * 37) % 120) - 60,
                            y: geo.size.height * 0.30 + CGFloat((minute * 53) % 80) - 40)

                    HStack(spacing: 7) {
                        Image(systemName: "eye").font(.system(size: 15))
                        Text("Away · wakes when you sit down")
                    }
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: 0x48484A))
                    .offset(x: 20, y: geo.size.height - 32)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { presence.markPresent() }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Double-tap to wake")
    }

    private func subtitle(_ now: Date) -> String {
        let date = DateText.short(now)
        guard let w = weather.snapshot else { return date }
        return "\(date) · \(Int(w.temperature.rounded()))°"
    }
}
