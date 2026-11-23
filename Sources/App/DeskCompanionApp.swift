import SwiftUI

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
        }
    }
}
