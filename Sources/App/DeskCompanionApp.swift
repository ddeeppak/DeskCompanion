import SwiftUI
import UserNotifications

@main
struct DeskCompanionApp: App {
    @StateObject private var app = AppState()
    @StateObject private var battery = BatteryMonitor()
    @StateObject private var location = LocationService()
    @StateObject private var weather = WeatherService()
    @StateObject private var pressure = PressureService()
    @StateObject private var night = NightMode()
    @StateObject private var planner = PlannerService()
    @StateObject private var habits = HabitStore()
    @StateObject private var focus = FocusTimer()
    @StateObject private var sound = SoundEngine.shared
    @StateObject private var alarms = AlarmStore()
    @StateObject private var library = SoundLibrary()
    @StateObject private var quickTimer = QuickTimer()
    @StateObject private var speech = SpeechService()
    @StateObject private var voice = VoiceService()
    @StateObject private var assistant = AssistantService()

    init() {
        // Alarms ring inside the app; the backup notification is only for when the app isn't open.
        UNUserNotificationCenter.current().delegate = NotificationRelay.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(battery)
                .environmentObject(location)
                .environmentObject(weather)
                .environmentObject(pressure)
                .environmentObject(night)
                .environmentObject(planner)
                .environmentObject(habits)
                .environmentObject(focus)
                .environmentObject(sound)
                .environmentObject(alarms)
                .environmentObject(library)
                .environmentObject(quickTimer)
                .environmentObject(speech)
                .environmentObject(voice)
                .environmentObject(assistant)
                .onAppear {
                    assistant.configure(app: app, planner: planner, alarms: alarms, timer: quickTimer,
                                        focus: focus, weather: weather, speech: speech, voice: voice)
                }
        }
    }
}
