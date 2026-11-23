import SwiftUI
import UIKit

/// 01 Home (ambient default). Layout and type follow the Claude Design export:
/// greeting + status row (30) · clock 128 Thin · date 22 Medium · sensor row 17 Semibold / 13
/// right column 244: weather · Up Next (Calendar) · tasks (Reminders).
struct HomeView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(Greeting.text(for: now))
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(theme.secondaryLabel)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    StatusCluster()
                }
                .frame(height: 30)

                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 0) {
                        ClockText(date: now)
                            .padding(.top, 10)
                        Text(DateText.long(now))
                            .font(.system(size: 22, weight: .semibold))
                            .padding(.top, 14)
                        Spacer(minLength: 8)
                        SensorRow()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(spacing: 10) {
                        WeatherCard(now: now)
                        UpNextCard(now: now)
                        TasksCard()
                            .frame(maxHeight: .infinity)
                    }
                    .frame(width: 244)
                }
                .padding(.top, 8)
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
        let hour = Calendar.current.component(.hour, from: date)
        HStack(alignment: .top, spacing: 8) {
            Text(TimeText.clock(date))
                .font(theme.clockFont(theme.clockSize))
                .tracking(theme.tracking(for: theme.clockSize))
                .shadow(color: theme.glow ?? .clear, radius: 16)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                // Design uses line-height 0.9; SwiftUI adds ~1.19. Trim the extra space above and below.
                .padding(.vertical, -theme.clockSize * 0.145)
            Text(hour < 12 ? "AM" : "PM")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(theme.secondaryLabel)
                .padding(.top, 12)
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

// MARK: - Sensor row: Sunrise · Sunset · Noise · Pressure (4 equal columns)

private struct SensorRow: View {
    @EnvironmentObject private var weather: WeatherService
    @EnvironmentObject private var pressure: PressureService
    @Environment(\.theme) private var theme

    var body: some View {
        let snapshot = weather.snapshot
        HStack(alignment: .top, spacing: 8) {
            item(symbol: "sunrise.fill", tint: nil,
                 value: snapshot.map { TimeText.clock($0.sunrise) } ?? "--:--", label: "Sunrise")
            item(symbol: "sunset.fill", tint: nil,
                 value: snapshot.map { TimeText.clock($0.sunset) } ?? "--:--", label: "Sunset")
            item(symbol: "waveform", tint: theme.green,
                 value: "--", label: "Noise")                       // noise meter arrives in step 7
            item(symbol: "gauge", tint: theme.accent2,
                 value: pressureValue(snapshot), label: pressureLabel)
        }
    }

    private func pressureValue(_ snapshot: WeatherSnapshot?) -> String {
        if let value = pressure.displayValue(seaLevelOffset: snapshot?.seaLevelOffset) {
            return "\(Int(value.rounded()))"
        }
        if let msl = snapshot?.seaLevelPressure { return "\(Int(msl.rounded()))" }
        return "----"
    }

    private var pressureLabel: String {
        pressure.trend == .unknown ? "hPa" : "hPa · \(pressure.trend.text)"
    }

    private func item(symbol: String, tint: Color?, value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let tint = tint {
                    Image(systemName: symbol)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(tint)
                } else {
                    Image(systemName: symbol)
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 17))
                }
                Text(value)
                    .font(.system(size: 17, weight: .bold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryLabel)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Weather card

private struct WeatherCard: View {
    let now: Date
    @EnvironmentObject private var weather: WeatherService
    @EnvironmentObject private var location: LocationService
    @Environment(\.theme) private var theme

    init(now: Date) { self.now = now }

    var body: some View {
        Group {
            if let snapshot = weather.snapshot {
                content(snapshot)
            } else {
                emptyState
            }
        }
        .card()
        .accessibilityElement(children: .combine)
    }

    private func content(_ w: WeatherSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("My Location")
                            .font(.system(size: 15, weight: .bold))
                            .lineLimit(1)
                        Image(systemName: "location.fill")
                            .font(.system(size: 10, weight: .bold))
                    }
                    Text("\(Int(w.temperature.rounded()))°")
                        .font(theme.numberFont(44))
                        .shadow(color: theme.glow ?? .clear, radius: 12)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 2) {
                    Image(systemName: WeatherCode.symbol(w.code, isDay: w.isDay))
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 25))
                        .frame(height: 28)
                    Text(WeatherCode.text(w.code))
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("H:\(Int(w.high.rounded()))° L:\(Int(w.low.rounded()))°")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.secondaryLabel)
                        .lineLimit(1)
                }
            }

            Rectangle()
                .fill(theme.separator)
                .frame(height: 1)
                .padding(.top, 10)

            HStack(spacing: 0) {
                ForEach(w.nextHours(after: now, count: 4), id: \.time) { hour in
                    VStack(spacing: 5) {
                        Text(TimeText.hour(hour.time))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(theme.secondaryLabel)
                        Image(systemName: WeatherCode.symbol(hour.code, isDay: hour.isDay))
                            .symbolRenderingMode(.multicolor)
                            .font(.system(size: 17))
                            .frame(height: 20)
                        Text("\(Int(hour.temperature.rounded()))°")
                            .font(.system(size: 15, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 9)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("My Location")
                    .font(.system(size: 15, weight: .bold))
                Image(systemName: "location.fill")
                    .font(.system(size: 10, weight: .bold))
            }
            if location.isDenied {
                Text("Location is off, so weather can't load.")
                    .font(.system(size: 13))
                    .foregroundColor(theme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("Allow in Settings")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(theme.accent)
                        .frame(height: 44)
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(weather.failed ? "Weather unavailable · retrying" : "Loading weather…")
                        .font(.system(size: 13))
                        .foregroundColor(theme.secondaryLabel)
                }
                .frame(height: 44)
            }
        }
    }
}

// MARK: - Up Next (next calendar event today)

private struct UpNextCard: View {
    let now: Date
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var planner: PlannerService
    @Environment(\.theme) private var theme

    init(now: Date) { self.now = now }

    var body: some View {
        let next = planner.nextEvent(after: now)
        VStack(alignment: .leading, spacing: 0) {
            Text("Up Next")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(theme.accent)
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(next?.color ?? theme.tertiaryLabel)
                    .frame(width: 4)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title(next))
                        .font(.system(size: 16, weight: .bold))
                        .lineLimit(1)
                    Text(detail(next))
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundColor(theme.secondaryLabel)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
        }
        .card(padding: EdgeInsets(top: 11, leading: 14, bottom: 11, trailing: 14))
        .contentShape(Rectangle())
        .onTapGesture { app.screen = .today }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func title(_ event: DayEvent?) -> String {
        if planner.calendarAccess == .denied { return "Calendar is off" }
        return event?.title ?? "Nothing else today"
    }

    private func detail(_ event: DayEvent?) -> String {
        if planner.calendarAccess == .denied { return "Allow access in Settings" }
        guard let event = event else { return "Your calendar is clear" }
        if event.start <= now { return "Now · until \(TimeText.time(event.end))" }
        let range = "\(TimeText.clock(event.start)) – \(TimeText.time(event.end))"
        return "\(range) · in \(Countdown.text(from: now, to: event.start))"
    }
}

enum Countdown {
    /// "2 h 18 m" / "18 m"
    static func text(from now: Date, to date: Date) -> String {
        let minutes = max(1, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
        let h = minutes / 60
        let m = minutes % 60
        if h == 0 { return "\(m) m" }
        return m == 0 ? "\(h) h" : "\(h) h \(m) m"
    }
}

// MARK: - Today's tasks (ring + next task)

private struct TasksCard: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var planner: PlannerService
    @Environment(\.theme) private var theme

    var body: some View {
        let total = planner.tasks.count
        let done = planner.doneCount
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(theme.fill, lineWidth: 6)
                Circle()
                    .trim(from: 0, to: total == 0 ? 0 : CGFloat(done) / CGFloat(total))
                    .stroke(theme.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.4), value: done)
                Text("\(done)/\(total)")
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: 40, height: 40)
            .padding(3)
            VStack(alignment: .leading, spacing: 1) {
                Text("Today’s tasks")
                    .font(.system(size: 15, weight: .bold))
                Text(nextLine)
                    .font(.system(size: 13))
                    .foregroundColor(theme.secondaryLabel)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        .card(padding: EdgeInsets(top: 11, leading: 14, bottom: 11, trailing: 14))
        .contentShape(Rectangle())
        .onTapGesture { app.screen = .today }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var nextLine: String {
        if planner.remindersAccess == .denied { return "Reminders access is off" }
        if planner.tasks.isEmpty { return "No tasks yet" }
        if let next = planner.nextTask { return "Next: \(next.title)" }
        return "All done"
    }
}
