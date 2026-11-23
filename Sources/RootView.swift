import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.scenePhase) private var scenePhase

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
        // Any touch (press or drag) brings the rail back and restarts the 30 s timer.
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in app.touchBegan() })
        .onAppear {
            // Desk display: never auto-lock while the app is open.
            UIApplication.shared.isIdleTimerDisabled = true
            app.scheduleRailHide()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                UIApplication.shared.isIdleTimerDisabled = true
                app.registerTouch()
            }
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
