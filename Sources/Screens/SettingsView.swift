import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case ai, voice, sensors, display, privacy, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ai: return "AI & Network"
        case .voice: return "Voice"
        case .sensors: return "Sensors"
        case .display: return "Display & Night"
        case .privacy: return "Privacy"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .ai: return "desktopcomputer"
        case .voice: return "speaker.wave.2.fill"
        case .sensors: return "eye.fill"
        case .display: return "moon.fill"
        case .privacy: return "lock.fill"
        case .about: return "info"
        }
    }

    var tint: Color {
        switch self {
        case .ai: return Color(hex: 0x0A84FF)
        case .voice: return Color(hex: 0xFF375F)
        case .sensors: return Color(hex: 0x30D158)
        case .display: return Color(hex: 0x5E5CE6)
        case .privacy: return Color(hex: 0x0A84FF)
        case .about: return Color(hex: 0x8E8E93)
        }
    }
}

/// 08 Settings. Step 1: section list, working Style picker, About. Other sections are filled in later steps.
struct SettingsView: View {
    @Environment(\.theme) private var theme
    @State private var section: SettingsSection = .display

    var body: some View {
        // Design: no top bar on Settings. Title sits above the section list.
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings")
                    .font(.system(size: 28, weight: .bold))
                    .frame(height: 34)
                    .padding(.leading, 4)
                    .padding(.bottom, 8)
                ForEach(SettingsSection.allCases) { item in
                    let selected = section == item
                    Button {
                        section = item
                    } label: {
                        HStack(spacing: 10) {
                            IconTile(symbol: item.icon,
                                     color: selected ? Color.white.opacity(0.22) : item.tint)
                            Text(item.title)
                                .font(.system(size: 15, weight: selected ? .semibold : .regular))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 44)
                        .foregroundColor(selected ? theme.onAccent : theme.label)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(selected ? theme.accent : Color.clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 184)

            ScrollView(.vertical, showsIndicators: false) {
                detail
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 8)
            }
        }
        .screenPadding()
    }

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .display: DisplaySettings()
        case .about: AboutSettings()
        default: PlannedSettings(section: section)
        }
    }
}

// MARK: - Display & Night (Style picker works now)

private struct DisplaySettings: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Style")
            HStack(spacing: 10) {
                ForEach(AppStyle.allCases) { style in
                    StyleTile(style: style, selected: app.style == style) {
                        withAnimation(.easeInOut(duration: 0.3)) { app.style = style }
                    }
                }
            }
            Text("Change any time. Your choice is saved on the phone.")
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryLabel)
                .padding(.leading, 4)

            SectionLabel("Night mode")
                .padding(.top, 10)
            InfoList(rows: [
                InfoRow(title: "Night clock", value: "10:30 PM – 6:30 AM"),
                InfoRow(title: "Clock colour", value: app.style == .warm ? "Amber" : "Red")
            ])
            Text("Automatic night mode arrives in step 2.")
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryLabel)
                .padding(.leading, 4)
        }
    }
}

/// Mini preview of a style: its background, clock digits and accent.
private struct StyleTile: View {
    let style: AppStyle
    let selected: Bool
    let action: () -> Void
    @Environment(\.theme) private var current

    init(style: AppStyle, selected: Bool, action: @escaping () -> Void) {
        self.style = style
        self.selected = selected
        self.action = action
    }

    var body: some View {
        let t = Theme.make(style)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottomLeading) {
                    ThemeBackground()
                        .environment(\.theme, t)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("10:42")
                            .font(t.clockFont(32))
                            .foregroundColor(t.label)
                            .shadow(color: t.glow ?? .clear, radius: 6)
                        HStack(spacing: 5) {
                            Circle().fill(t.accent).frame(width: 9, height: 9)
                            RoundedRectangle(cornerRadius: 3).fill(t.surface).frame(width: 46, height: 9)
                        }
                    }
                    .padding(10)
                }
                .frame(height: 82)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(selected ? t.accent : Color.white.opacity(0.1), lineWidth: selected ? 2.5 : 1))

                HStack(spacing: 4) {
                    Text(style.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundColor(current.accent)
                    }
                }
                Text(style.subtitle)
                    .font(.system(size: 13))
                    .foregroundColor(current.secondaryLabel)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - About

private struct AboutSettings: View {
    var body: some View {
        let screen = UIScreen.main.bounds.size
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Desk Companion")
            InfoList(rows: [
                InfoRow(title: "Version", value: appVersion),
                InfoRow(title: "Build step", value: "1.1 · Foundation + design fixes"),
                InfoRow(title: "iOS", value: UIDevice.current.systemVersion),
                InfoRow(title: "Screen", value: "\(Int(max(screen.width, screen.height))) × \(Int(min(screen.width, screen.height))) pt")
            ])
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

// MARK: - Sections filled in by later steps

private struct PlannedSettings: View {
    let section: SettingsSection
    @Environment(\.theme) private var theme

    init(section: SettingsSection) { self.section = section }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(section.title)
            InfoList(rows: rows)
            Text("These settings appear as each feature is built.")
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryLabel)
                .padding(.leading, 4)
        }
    }

    private var rows: [InfoRow] {
        switch section {
        case .ai:
            return [InfoRow(title: "Local AI server", value: "Step 6"),
                    InfoRow(title: "Model", value: "Step 6"),
                    InfoRow(title: "Offline commands", value: "Step 5")]
        case .voice:
            return [InfoRow(title: "Speech recognition", value: "Step 5"),
                    InfoRow(title: "Voice & speed", value: "Step 5")]
        case .sensors:
            return [InfoRow(title: "Presence detection (camera)", value: "Step 7"),
                    InfoRow(title: "Wave to talk (proximity)", value: "Step 7"),
                    InfoRow(title: "Noise meter", value: "Step 7")]
        case .privacy:
            return [InfoRow(title: "Permissions overview", value: "Step 8"),
                    InfoRow(title: "Clear assistant history", value: "Step 5")]
        case .display, .about:
            return []
        }
    }
}
