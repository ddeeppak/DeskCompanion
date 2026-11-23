import SwiftUI

/// 01 Home (ambient default). Step 1: live clock, date, greeting, layout.
/// Weather / sunrise / pressure arrive in step 2, Up Next + tasks in step 3, noise in step 7.
struct HomeView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(Greeting.text(for: now))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(theme.secondaryLabel)
                        .frame(height: 34)
                    ClockText(date: now)
                        .padding(.top, 2)
                    Text(DateText.long(now))
                        .font(.system(size: 22, weight: .medium))
                        .padding(.top, 2)
                    Spacer(minLength: 8)
                    SensorRow()
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 10) {
                    HStack { Spacer(); StatusCluster() }
                        .frame(height: 34)
                    PlaceholderCard(title: "My Location", symbol: "cloud.sun.fill",
                                    message: "Weather and the next 4 hours arrive in step 2.", tall: true)
                    PlaceholderCard(title: "Up Next", symbol: "calendar",
                                    message: "Your next calendar event arrives in step 3.")
                    PlaceholderCard(title: "Today's tasks", symbol: "checklist",
                                    message: "Task progress arrives in step 3.")
                }
                .frame(width: 222)
            }
            .screenPadding()
        }
    }
}

// MARK: - Clock

struct ClockText: View {
    let date: Date
    @Environment(\.theme) private var theme

    init(date: Date) { self.date = date }

    var body: some View {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        let hour = parts.hour ?? 0
        let minute = parts.minute ?? 0
        let hour12 = hour % 12 == 0 ? 12 : hour % 12

        HStack(alignment: .top, spacing: 6) {
            Text("\(hour12):\(String(format: "%02d", minute))")
                .font(theme.clockFont(theme.style == .futuristic ? 108 : 126))
                .shadow(color: theme.glow ?? .clear, radius: 16)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(hour < 12 ? "AM" : "PM")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(theme.secondaryLabel)
                .padding(.top, 18)
        }
    }
}

enum Greeting {
    static func text(for date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        switch hour {
        case 0..<5: return "Good night"
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }
}

enum DateText {
    private static let longFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMMM"          // Monday, 23 November
        return f
    }()

    private static let shortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMM"            // Monday 23 Nov
        return f
    }()

    static func long(_ date: Date) -> String { longFormatter.string(from: date) }
    static func short(_ date: Date) -> String { shortFormatter.string(from: date) }
}

// MARK: - Bottom sensor row (values arrive in steps 2 and 7)

private struct SensorRow: View {
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 22) {
            item(symbol: "sunrise.fill", color: theme.orange, value: "--:--", label: "Sunrise")
            item(symbol: "sunset.fill", color: theme.orange, value: "--:--", label: "Sunset")
            item(symbol: "waveform", color: theme.green, value: "-- dB", label: "Noise")
            item(symbol: "gauge", color: theme.accent2, value: "----", label: "hPa")
        }
    }

    private func item(symbol: String, color: Color, value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(color)
                Text(value)
                    .font(theme.numberFont(19, weight: .semibold))
            }
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryLabel)
        }
    }
}

// MARK: - Placeholder card

private struct PlaceholderCard: View {
    let title: String
    let symbol: String
    let message: String
    let tall: Bool
    @Environment(\.theme) private var theme

    init(title: String, symbol: String, message: String, tall: Bool = false) {
        self.title = title
        self.symbol = symbol
        self.message = message
        self.tall = tall
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.accent)
                Spacer(minLength: 0)
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundColor(theme.tertiaryLabel)
            }
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
            if tall { Spacer(minLength: 0) }
        }
        .frame(maxHeight: tall ? .infinity : nil, alignment: .top)
        .card()
    }
}
