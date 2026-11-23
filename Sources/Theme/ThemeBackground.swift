import SwiftUI

/// Full-screen background for the current style:
/// Calm = pure black · Futuristic = black with a faint 24 pt cyan grid · Warm = dark brown with soft radial glows.
struct ThemeBackground: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.background
            switch theme.style {
            case .calm:
                EmptyView()
            case .futuristic:
                GridPattern(spacing: 24, color: .rgba(100, 210, 255, 0.055))
            case .warm:
                GeometryReader { geo in
                    ZStack {
                        RadialGradient(gradient: Gradient(colors: [Color(hex: 0x3F2519), Color(hex: 0x3F2519, alpha: 0)]),
                                       center: .topLeading, startRadius: 0, endRadius: geo.size.width * 0.75)
                        RadialGradient(gradient: Gradient(colors: [Color(hex: 0x2F1C2E), Color(hex: 0x2F1C2E, alpha: 0)]),
                                       center: .bottomTrailing, startRadius: 0, endRadius: geo.size.width * 0.6)
                    }
                }
            }
        }
        .ignoresSafeArea()
    }
}

struct GridPattern: View {
    let spacing: CGFloat
    let color: Color

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x: CGFloat = 0
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += spacing
            }
            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += spacing
            }
            context.stroke(path, with: .color(color), lineWidth: 1)
        }
    }
}
