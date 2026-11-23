import SwiftUI

/// 02 Night clock: black screen, dim clock in the night colour (red, amber in Warm), lowest brightness.
/// Design type: clock 188 Thin · date line 19 Medium at 80% · chip 16 Semibold · hint 13 Medium at 60%.
struct NightView: View {
    @EnvironmentObject private var night: NightMode
    @EnvironmentObject private var weather: WeatherService
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    Text(TimeText.clock(now))
                        .font(theme.clockFont(188))
                        .tracking(theme.style == .futuristic ? -188 * 0.05 : -188 * 0.04)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text(subtitle(now))
                        .font(.system(size: 19, weight: .medium))
                        .opacity(0.8)
                        .padding(.top, 18)
                    if let sunrise = weather.snapshot?.nextSunrise(after: now) {
                        // Next alarm would go here (in-app alarm: decision pending). Shows sunrise meanwhile.
                        HStack(spacing: 7) {
                            Image(systemName: "sunrise.fill")
                                .font(.system(size: 15))
                            Text("Sunrise \(TimeText.time(sunrise))")
                        }
                        .font(.system(size: 16, weight: .semibold))
                        .padding(.horizontal, 15)
                        .frame(height: 34)
                        .background(Capsule().fill(theme.night.opacity(0.16)))
                        .opacity(0.9)
                        .padding(.top, 14)
                    }
                }

                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "hand.tap.fill")
                            .font(.system(size: 15))
                        Text("Tap to brighten")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .opacity(0.6)
                    .padding(.bottom, 16)
                }
            }
            .foregroundColor(theme.night)
            .contentShape(Rectangle())
            .onTapGesture {
                app.screen = .home
                night.peek()
            }
        }
    }

    private func subtitle(_ now: Date) -> String {
        let date = DateText.long(now)
        guard let w = weather.snapshot else { return date }
        return "\(date) · \(Int(w.temperature.rounded()))° \(WeatherCode.text(w.code))"
    }
}
