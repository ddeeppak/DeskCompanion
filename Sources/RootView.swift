import SwiftUI
import Combine

struct RootView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var location: LocationService
    @EnvironmentObject private var weather: WeatherService
    @EnvironmentObject private var pressure: PressureService
    @EnvironmentObject private var night: NightMode
    @EnvironmentObject private var planner: PlannerService
    @EnvironmentObject private var alarms: AlarmStore
    @EnvironmentObject private var library: SoundLibrary
    @EnvironmentObject private var quickTimer: QuickTimer
    // Note: RootView deliberately does not observe FocusTimer (it ticks twice a second).
    @Environment(\.scenePhase) private var scenePhase

    /// Once a minute: night schedule, weather, location, calendar + reminders.
    private let minuteTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    /// Every 15 s: check for reminders that just became due.
    private let alertTimer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()
    /// Every 5 s: alarms (rings within a few seconds of the set time).
    private let alarmTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        let theme = Theme.make(app.style)

        ZStack {
            HStack(spacing: 0) {
                if app.railVisible {
                    RailView()
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                currentScreen
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(ThemeBackground())

            overlays
        }
        .animation(.easeInOut(duration: 0.6), value: night.showNight)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: planner.alert)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: quickTimer.ringing)
        .animation(.easeInOut(duration: 0.4), value: alarms.ringing)
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
            location.start()
            pressure.start()
            night.evaluate()
            weather.refreshIfNeeded(location: location.location)
            planner.start()
        }
        .onReceive(minuteTimer) { _ in
            night.evaluate()
            location.refreshIfStale()
            weather.refreshIfNeeded(location: location.location)
            planner.refresh()
        }
        .onReceive(alertTimer) { _ in
            planner.checkAlerts()
        }
        .onReceive(alarmTimer) { _ in
            alarms.check()
        }
        .onChange(of: quickTimer.ringing) { ringing in
            guard ringing else { return }
            if night.showNight { night.peek(seconds: 60) }
            app.registerTouch()
        }
        .onChange(of: alarms.ringing) { ringing in
            guard ringing != nil else { return }
            // Alarm: full brightness for up to 10 minutes.
            if night.showNight { night.peek(seconds: 600) }
            app.registerTouch()
        }
        .onReceive(location.$location) { newLocation in
            weather.refreshIfNeeded(location: newLocation)
        }
        .onChange(of: planner.alert) { alert in
            guard alert != nil else { return }
            // A reminder is due: wake up the screen and chime once.
            if night.showNight { night.peek(seconds: 60) }
            app.registerTouch()
            SoundEngine.shared.playChimeOnce()
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusPhaseFinished)) { _ in
            // Timer finished: show the "Session done" screen, brighten if it's night.
            if night.showNight { night.peek(seconds: 60) }
            app.screen = .focus
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                UIApplication.shared.isIdleTimerDisabled = true
                library.rescan()          // pick up files copied with iTunes File Sharing
                alarms.check()
                app.registerTouch()
                night.appBecameActive()
                pressure.start()
                weather.refreshIfNeeded(location: location.location)
                planner.refresh()
            case .background:
                night.restoreBrightness()
                pressure.stop()
            default:
                break
            }
        }
    }

    /// Night clock, alert banners and the alarm, layered over the app.
    @ViewBuilder
    private var overlays: some View {
        if night.showNight {
            NightView()
                .transition(.opacity)
                .zIndex(1)
        }

        if let task = planner.alert {
            AlertBanner(title: task.title,
                        subtitle: reminderSubtitle(task),
                        secondaryTitle: "Snooze 10 min", primaryTitle: "Done",
                        onSecondary: { withAnimation { planner.snoozeAlert() } },
                        onPrimary: { withAnimation { planner.completeAlert() } })
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(2)
        } else if quickTimer.ringing {
            AlertBanner(title: "Timer done",
                        subtitle: "\(quickTimer.label) · ended now",
                        symbol: "timer",
                        secondaryTitle: "+1 min", primaryTitle: "Stop",
                        onSecondary: { withAnimation { quickTimer.addMinute() } },
                        onPrimary: { withAnimation { quickTimer.stopRinging() } })
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(2)
        }

        if let alarm = alarms.ringing {
            AlarmRingingView(alarm: alarm, snoozeMinutes: alarms.snoozeMinutes,
                             onSnooze: { withAnimation { alarms.snooze() } },
                             onStop: { withAnimation { alarms.stop() } })
                .transition(.opacity)
                .zIndex(3)
        }
    }

    private func reminderSubtitle(_ task: TaskItem) -> String {
        if let created = planner.voiceCreatedAt(task.id) {
            return "Reminder · set by voice at \(TimeText.time(created))"
        }
        if let due = task.dueDate { return "Reminder · due \(TimeText.time(due))" }
        return "Reminder"
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
