import SwiftUI

@main
struct DeskCompanionApp: App {
    @StateObject private var app = AppState()
    @StateObject private var battery = BatteryMonitor()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(battery)
        }
    }
}
