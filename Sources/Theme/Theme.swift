import SwiftUI

// MARK: - Styles the user can pick in Settings -> Display & Night -> Style

enum AppStyle: String, CaseIterable, Identifiable {
    case calm, futuristic, warm

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .calm: return "Calm minimal"
        case .futuristic: return "Futuristic"
        case .warm: return "Warm & cozy"
        }
    }

    var subtitle: String {
        switch self {
        case .calm: return "iOS dark, blue, quiet"
        case .futuristic: return "Cyan glow, grid, mono"
        case .warm: return "Orange, soft gradients"
        }
    }
}

// MARK: - Design tokens (from the Claude Design export, named like iOS system colours)

struct Theme {
    let style: AppStyle
    let background: Color        // systemBackground
    let bar: Color               // rail background
    let surface: Color           // secondarySystemBackground (cards)
    let fill: Color              // tertiarySystemFill (chips, segmented track)
    let separator: Color
    let label: Color
    let secondaryLabel: Color
    let tertiaryLabel: Color
    let accent: Color
    let onAccent: Color          // text/icon on accent
    let accentTint: Color        // light accent background
    let accent2: Color
    let green: Color
    let orange: Color
    let red: Color
    let night: Color             // night clock colour
    let cardRadius: CGFloat
    let listRadius: CGFloat
    let controlRadius: CGFloat
    let cardBorder: Color?       // Futuristic hairline
    let glow: Color?             // Futuristic glow
    let segmentSelected: Color
    let toggleOn: Color

    /// Large digits (clock, timer). Calm: SF Pro Thin · Futuristic: SF Mono Light · Warm: SF Rounded Light
    func clockFont(_ size: CGFloat) -> Font {
        switch style {
        case .calm: return Font.system(size: size, weight: .thin, design: .default).monospacedDigit()
        case .futuristic: return Font.system(size: size, weight: .light, design: .monospaced)
        case .warm: return Font.system(size: size, weight: .light, design: .rounded).monospacedDigit()
        }
    }

    /// Medium numbers (temperature, stats)
    func numberFont(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch style {
        case .calm: return Font.system(size: size, weight: weight, design: .default).monospacedDigit()
        case .futuristic: return Font.system(size: size, weight: weight, design: .monospaced)
        case .warm: return Font.system(size: size, weight: weight, design: .rounded).monospacedDigit()
        }
    }

    static func make(_ style: AppStyle) -> Theme {
        switch style {
        case .calm:
            return Theme(
                style: .calm,
                background: Color(hex: 0x000000),
                bar: .rgba(28, 28, 30, 0.55),
                surface: Color(hex: 0x1C1C1E),
                fill: .rgba(118, 118, 128, 0.24),
                separator: .rgba(84, 84, 88, 0.55),
                label: Color(hex: 0xFFFFFF),
                secondaryLabel: .rgba(235, 235, 245, 0.6),
                tertiaryLabel: .rgba(235, 235, 245, 0.3),
                accent: Color(hex: 0x0A84FF),
                onAccent: Color(hex: 0xFFFFFF),
                accentTint: .rgba(10, 132, 255, 0.2),
                accent2: Color(hex: 0x64D2FF),
                green: Color(hex: 0x30D158),
                orange: Color(hex: 0xFF9F0A),
                red: Color(hex: 0xFF453A),
                night: Color(hex: 0xC42B21),
                cardRadius: 20, listRadius: 12, controlRadius: 12,
                cardBorder: nil, glow: nil,
                segmentSelected: Color(hex: 0x636366),
                toggleOn: Color(hex: 0x30D158))
        case .futuristic:
            return Theme(
                style: .futuristic,
                background: Color(hex: 0x000000),
                bar: .rgba(100, 210, 255, 0.04),
                surface: .rgba(100, 210, 255, 0.06),
                fill: .rgba(100, 210, 255, 0.13),
                separator: .rgba(100, 210, 255, 0.16),
                label: Color(hex: 0xE8FAFF),
                secondaryLabel: .rgba(205, 240, 255, 0.62),
                tertiaryLabel: .rgba(205, 240, 255, 0.32),
                accent: Color(hex: 0x64D2FF),
                onAccent: Color(hex: 0x00131C),
                accentTint: .rgba(100, 210, 255, 0.16),
                accent2: Color(hex: 0xBF5AF2),
                green: Color(hex: 0x30D158),
                orange: Color(hex: 0xFF9F0A),
                red: Color(hex: 0xFF453A),
                night: Color(hex: 0xD0283F),
                cardRadius: 12, listRadius: 10, controlRadius: 8,
                cardBorder: .rgba(100, 210, 255, 0.22),
                glow: .rgba(100, 210, 255, 0.45),
                segmentSelected: .rgba(100, 210, 255, 0.3),
                toggleOn: Color(hex: 0x64D2FF))
        case .warm:
            return Theme(
                style: .warm,
                background: Color(hex: 0x18110E),
                bar: .rgba(255, 236, 220, 0.04),
                surface: .rgba(255, 236, 220, 0.08),
                fill: .rgba(255, 236, 220, 0.13),
                separator: .rgba(255, 236, 220, 0.11),
                label: Color(hex: 0xFFF6EE),
                secondaryLabel: .rgba(255, 236, 220, 0.64),
                tertiaryLabel: .rgba(255, 236, 220, 0.32),
                accent: Color(hex: 0xFF9F0A),
                onAccent: Color(hex: 0x1F1206),
                accentTint: .rgba(255, 159, 10, 0.18),
                accent2: Color(hex: 0xFF6482),
                green: Color(hex: 0x30D158),
                orange: Color(hex: 0xFFB340),
                red: Color(hex: 0xFF6961),
                night: Color(hex: 0xC87A2A),
                cardRadius: 24, listRadius: 16, controlRadius: 16,
                cardBorder: nil, glow: nil,
                segmentSelected: .rgba(255, 236, 220, 0.26),
                toggleOn: Color(hex: 0xFF9F0A))
        }
    }
}

// MARK: - Environment

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.make(.calm)
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

// MARK: - Colour helpers

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }

    static func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> Color {
        Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
    }
}
