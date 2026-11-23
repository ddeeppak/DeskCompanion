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
    @StateObject private var ai = AIService()
    @StateObject private var presence = PresenceService()
    @StateObject private var proximity = ProximityService()
    @StateObject private var noise = NoiseMeter()
    @StateObject private var briefing = BriefingService()

    init() {
        // Alarms ring inside the app; the backup notification is only for when the app isn't open.
        UNUserNotificationCenter.current().delegate = NotificationRelay.shared
        // No rubber-band stretch when pulling on lists/panels (SwiftUI on iOS 15 always bounces, even when
        // the content fits). Lists still scroll; they just stop firmly at the ends.
        UIScrollView.appearance().bounces = false
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
                .environmentObject(ai)
                .environmentObject(presence)
                .environmentObject(proximity)
                .environmentObject(noise)
                .environmentObject(briefing)
                .onAppear {
                    ai.app = app
                    noise.speech = speech
                    // Someone came back to the desk: wake up.
                    briefing.configure(planner: planner, weather: weather, focus: focus, presence: presence,
                                       night: night, voice: voice, speech: speech, habits: habits)
                    presence.onReturn = {
                        night.setAway(false)
                        app.registerTouch()
                        // Morning briefing / evening wrap-up when you sit down.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { briefing.check() }
                    }
                    // Wave over the sensor near the earpiece.
                    proximity.onWave = {
                        if presence.isAway {
                            presence.markPresent()
                        } else if night.showNight {
                            night.peek()
                        } else if proximity.action == "talk" {
                            assistant.listen()
                        } else {
                            app.registerTouch()
                        }
                    }
                    presence.start()
                    proximity.apply()
                    noise.start()
                    assistant.configure(app: app, planner: planner, alarms: alarms, timer: quickTimer,
                                        focus: focus, weather: weather, speech: speech, voice: voice, ai: ai)
                    ai.startDiscovery()
                    ai.check()
                }
        }
    }
}
