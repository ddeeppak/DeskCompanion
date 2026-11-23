import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        let theme = Theme.make(app.style)

        HStack(spacing: 0) {
            if app.railVisible {
                RailView()
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            currentScreen
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(ThemeBackground())
        .environment(\.theme, theme)
        .foregroundColor(theme.label)
        .preferredColorScheme(.dark)
        .statusBar(hidden: true)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { app.registerTouch() })
        .onAppear {
            // Desk display: never auto-lock while the app is open.
            UIApplication.shared.isIdleTimerDisabled = true
            app.scheduleRailHide()
        }
    }

    @ViewBuilder
    private var currentScreen: some View {
        switch app.screen {
        case .home: HomeView()
        case .assistant: AssistantView()
        case .today: TodayView()
        case .focus: FocusView()
        case .settings: SettingsView()
        }
    }
}
