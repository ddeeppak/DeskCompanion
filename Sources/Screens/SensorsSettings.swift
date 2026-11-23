import SwiftUI
import UIKit

/// Settings → Sensors: presence (front camera), wave (proximity), noise meter, barometer.
struct SensorsSettings: View {
    @EnvironmentObject private var presence: PresenceService
    @EnvironmentObject private var proximity: ProximityService
    @EnvironmentObject private var noise: NoiseMeter
    @EnvironmentObject private var pressure: PressureService
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            presenceSection
            waveSection
                .padding(.top, 12)
            roomSection
                .padding(.top, 12)
            footnote("Privacy: camera frames and sound are checked on this iPhone only. Nothing is recorded, saved or sent. iOS shows a small green (camera) or orange (microphone) dot while a sensor is in use.")
        }
    }

    // MARK: Presence

    private var presenceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Away mode")
            VStack(spacing: 0) {
                SettingsRow {
                    Image(systemName: "eye.fill").foregroundColor(theme.green).frame(width: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Presence detection")
                        Text(presenceStatus)
                            .font(.system(size: 13))
                            .foregroundColor(theme.secondaryLabel)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: $presence.enabled)
                        .labelsHidden()
                        .toggleStyle(SwitchToggleStyle(tint: theme.toggleOn))
                }
                .padding(.vertical, 3)
                if presence.enabled {
                    RowSeparator()
                    SettingsRow {
                        Text("Dim after nobody for")
                        Spacer(minLength: 8)
                        Menu {
                            ForEach([1, 2, 5, 10, 15], id: \.self) { minutes in
                                Button("\(minutes) min") { presence.awayMinutes = minutes }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text("\(presence.awayMinutes) min")
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 12, weight: .bold))
                            }
                            .foregroundColor(theme.accent)
                        }
                    }
                }
            }
            .groupedBox()
            if presence.cameraDenied { settingsButton("Allow Camera in iPhone Settings") }
        }
    }

    private var presenceStatus: String {
        if presence.cameraDenied { return "Camera access is off" }
        if !presence.enabled { return "Off" }
        if presence.pausedForHeat { return "Paused: iPhone is warm" }
        if presence.isAway { return "Nobody here: screen dimmed" }
        if let seen = presence.lastSeen {
            let seconds = Int(Date().timeIntervalSince(seen))
            return seconds < 10 ? "You're here" : "Last seen \(TimeText.time(seen))"
        }
        return presence.running ? "Watching" : "Starting…"
    }

    // MARK: Wave

    private var waveSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Wave")
            VStack(spacing: 0) {
                SettingsRow {
                    Image(systemName: "hand.wave.fill").foregroundColor(theme.orange).frame(width: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Wave over the phone")
                        Text(waveStatus)
                            .font(.system(size: 13))
                            .foregroundColor(theme.secondaryLabel)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: $proximity.enabled)
                        .labelsHidden()
                        .toggleStyle(SwitchToggleStyle(tint: theme.toggleOn))
                }
                .padding(.vertical, 3)
                if proximity.enabled {
                    RowSeparator()
                    SettingsRow {
                        Text("A wave")
                        Spacer(minLength: 8)
                        SegmentedBar(options: [("talk", "Starts listening"), ("brighten", "Only wakes")],
                                     selection: $proximity.action)
                            .frame(width: 270)
                    }
                }
            }
            .groupedBox()
            footnote("Wave a hand over the top edge of the phone, near the earpiece (on the Home button's opposite side). At night or in Away mode a wave just wakes the screen.")
        }
    }

    private var waveStatus: String {
        if !proximity.enabled { return "Off" }
        if !proximity.supported { return "Not available on this iPhone" }
        if proximity.blocked { return "Sensor covered: paused for 2 minutes" }
        if let wave = proximity.lastWave { return "Last wave \(TimeText.time(wave))" }
        return "No wave yet: try it"
    }

    // MARK: Room

    private var roomSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Room")
            VStack(spacing: 0) {
                SettingsRow {
                    Image(systemName: "waveform").foregroundColor(theme.green).frame(width: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Noise meter")
                        Text(noise.enabled ? (noise.decibels.map { "\($0) dB · \(noise.levelText) · checked once a minute" } ?? "Measuring…") : "Off")
                            .font(.system(size: 13))
                            .foregroundColor(theme.secondaryLabel)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: $noise.enabled)
                        .labelsHidden()
                        .toggleStyle(SwitchToggleStyle(tint: theme.toggleOn))
                }
                .padding(.vertical, 3)
                RowSeparator()
                SettingsRow {
                    Image(systemName: "gauge").foregroundColor(theme.accent2).frame(width: 24)
                    Text("Barometer")
                    Spacer(minLength: 8)
                    Text(pressureText).foregroundColor(theme.secondaryLabel)
                }
            }
            .groupedBox()
        }
    }

    private var pressureText: String {
        guard pressure.isAvailable else { return "Not available" }
        guard let value = pressure.hPa else { return "Waiting…" }
        let trend = pressure.trend == .unknown ? "" : " · \(pressure.trend.text)"
        return "\(Int(value.rounded())) hPa (sensor)\(trend)"
    }

    // MARK: Helpers

    private func settingsButton(_ title: String) -> some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        } label: {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(theme.accent)
                .frame(height: 44)
        }
        .buttonStyle(.plain)
        .padding(.leading, 14)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(theme.secondaryLabel)
            .padding(.leading, 14)
            .fixedSize(horizontal: false, vertical: true)
    }
}
