import SwiftUI

// MARK: - Status cluster (top right): Local AI capsule + battery

struct StatusCluster: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var battery: BatteryMonitor
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Circle()
                    .fill(aiColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: app.aiStatus == .online ? aiColor : .clear, radius: 4)
                Text(aiText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(app.aiStatus == .offline ? theme.red : theme.label)
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(theme.surface))
            .overlay(Capsule().stroke(theme.cardBorder ?? .clear, lineWidth: 1))

            HStack(spacing: 5) {
                Text("\(battery.level)%")
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                Image(systemName: battery.symbol)
                    .font(.system(size: 16))
                    .foregroundColor(battery.charging ? theme.green : theme.label)
            }
        }
    }

    private var aiColor: Color {
        switch app.aiStatus {
        case .online: return theme.green
        case .offline: return theme.red
        case .notSetUp: return theme.tertiaryLabel
        }
    }

    private var aiText: String {
        switch app.aiStatus {
        case .online: return "Local AI"
        case .offline: return "PC offline"
        case .notSetUp: return "AI not set up"
        }
    }
}

// MARK: - Screen header: big title + optional subtitle + status cluster

struct ScreenHeader: View {
    let title: String
    let subtitle: String?
    @Environment(\.theme) private var theme

    init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.system(size: 28, weight: .bold))
            if let subtitle = subtitle {
                Text(subtitle)
                    .font(.system(size: 17))
                    .foregroundColor(theme.secondaryLabel)
                    .padding(.top, 4)
            }
            Spacer(minLength: 8)
            StatusCluster()
        }
        .frame(height: 34)
    }
}

// MARK: - Card

struct CardStyle: ViewModifier {
    @Environment(\.theme) private var theme
    let padding: EdgeInsets

    init(padding: EdgeInsets) { self.padding = padding }

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous).fill(theme.surface))
            .overlay(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
                        .stroke(theme.cardBorder ?? .clear, lineWidth: 1))
    }
}

extension View {
    func card(padding: EdgeInsets = EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)) -> some View {
        modifier(CardStyle(padding: padding))
    }

    /// Standard screen padding: 14 top · 18 sides · 16 bottom
    func screenPadding() -> some View {
        padding(EdgeInsets(top: 14, leading: 18, bottom: 16, trailing: 18))
    }
}

// MARK: - Small pieces

struct SectionLabel: View {
    let text: String
    @Environment(\.theme) private var theme

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(theme.secondaryLabel)
            .padding(.leading, 4)
    }
}

struct IconTile: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color))
    }
}

struct InfoRow: Identifiable {
    let id = UUID()
    let title: String
    let value: String
    var showsChevron = false
}

/// iOS "inset grouped" style list.
struct InfoList: View {
    let rows: [InfoRow]
    @Environment(\.theme) private var theme

    init(rows: [InfoRow]) { self.rows = rows }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                HStack(spacing: 8) {
                    Text(row.title)
                        .font(.system(size: 16))
                    Spacer(minLength: 8)
                    Text(row.value)
                        .font(.system(size: 15))
                        .foregroundColor(theme.secondaryLabel)
                        .lineLimit(1)
                    if row.showsChevron {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(theme.tertiaryLabel)
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                if index < rows.count - 1 {
                    Rectangle().fill(theme.separator).frame(height: 0.5).padding(.leading, 14)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: theme.listRadius, style: .continuous).fill(theme.surface))
        .overlay(RoundedRectangle(cornerRadius: theme.listRadius, style: .continuous)
                    .stroke(theme.cardBorder ?? .clear, lineWidth: 1))
    }
}

/// Placeholder used by screens that arrive in later build steps.
struct ComingSoonView: View {
    let icon: String
    let headline: String
    let step: Int
    let bullets: [String]
    @Environment(\.theme) private var theme

    init(icon: String, headline: String, step: Int, bullets: [String]) {
        self.icon = icon
        self.headline = headline
        self.step = step
        self.bullets = bullets
    }

    var body: some View {
        HStack(spacing: 22) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .medium))
                .foregroundColor(theme.onAccent)
                .frame(width: 104, height: 104)
                .background(Circle().fill(theme.accent))
                .shadow(color: theme.glow ?? theme.accent.opacity(0.25), radius: 18)

            VStack(alignment: .leading, spacing: 10) {
                Text("Arrives in step \(step)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.accent)
                Text(headline)
                    .font(.system(size: 22, weight: .semibold))
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(bullets, id: \.self) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(theme.tertiaryLabel).frame(width: 5, height: 5).offset(y: -3)
                            Text(item)
                                .font(.system(size: 15))
                                .foregroundColor(theme.secondaryLabel)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .card(padding: EdgeInsets(top: 22, leading: 24, bottom: 22, trailing: 24))
    }
}
