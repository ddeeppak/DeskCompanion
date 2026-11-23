import Foundation
import UIKit
import Combine

/// Keeps a record for the 48-hour test (Settings → About → Stability): uptime, memory, heat, battery,
/// audio recoveries, AI availability and unexpected restarts. Everything stays on the iPhone.
final class StabilityMonitor: ObservableObject {
    static let shared = StabilityMonitor()

    @Published private(set) var memoryMB: Double = 0
    @Published private(set) var peakMemoryMB: Double
    @Published private(set) var thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    @Published private(set) var hotEvents: Int
    @Published private(set) var audioRecoveries: Int
    @Published private(set) var unexpectedRestarts: Int
    @Published private(set) var aiChecks: Int
    @Published private(set) var aiOnlineChecks: Int
    @Published private(set) var trackingSince: Date
    @Published private(set) var longestRunHours: Double
    let launchedAt = Date()

    private let d = UserDefaults.standard
    private var cancellables = Set<AnyCancellable>()

    private init() {
        let d = UserDefaults.standard
        peakMemoryMB = d.double(forKey: "stability.peakMemory")
        hotEvents = d.integer(forKey: "stability.hotEvents")
        audioRecoveries = d.integer(forKey: "stability.audioRecoveries")
        unexpectedRestarts = d.integer(forKey: "stability.unexpectedRestarts")
        aiChecks = d.integer(forKey: "stability.aiChecks")
        aiOnlineChecks = d.integer(forKey: "stability.aiOnlineChecks")
        trackingSince = d.object(forKey: "stability.since") as? Date ?? Date()
        longestRunHours = d.double(forKey: "stability.longestRun")
        if d.object(forKey: "stability.since") == nil { d.set(trackingSince, forKey: "stability.since") }

        // The last run ended without going to the background first: the app crashed or iOS closed it.
        if d.object(forKey: "stability.heartbeat") != nil, !d.bool(forKey: "stability.cleanExit") {
            unexpectedRestarts += 1
            d.set(unexpectedRestarts, forKey: "stability.unexpectedRestarts")
        }
        d.set(false, forKey: "stability.cleanExit")
        d.set(launchedAt, forKey: "stability.runStarted")

        NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.thermalChanged() }
            .store(in: &cancellables)
        UIDevice.current.isBatteryMonitoringEnabled = true
        sample()
    }

    // MARK: Recording

    /// Every minute (RootView).
    func tick(aiConfigured: Bool, aiOnline: Bool) {
        sample()
        if aiConfigured {
            aiChecks += 1
            if aiOnline { aiOnlineChecks += 1 }
            d.set(aiChecks, forKey: "stability.aiChecks")
            d.set(aiOnlineChecks, forKey: "stability.aiOnlineChecks")
        }
        d.set(Date(), forKey: "stability.heartbeat")
        let hours = uptime / 3600
        if hours > longestRunHours {
            longestRunHours = hours
            d.set(hours, forKey: "stability.longestRun")
        }
    }

    func noteAudioRecovery() {
        DispatchQueue.main.async {
            self.audioRecoveries += 1
            self.d.set(self.audioRecoveries, forKey: "stability.audioRecoveries")
        }
    }

    /// The app is going to the background normally (not a crash).
    func markBackground() { d.set(true, forKey: "stability.cleanExit") }
    func markActive() { d.set(false, forKey: "stability.cleanExit") }

    func resetCounters() {
        peakMemoryMB = memoryMB
        hotEvents = 0
        audioRecoveries = 0
        unexpectedRestarts = 0
        aiChecks = 0
        aiOnlineChecks = 0
        longestRunHours = uptime / 3600
        trackingSince = Date()
        for key in ["hotEvents", "audioRecoveries", "unexpectedRestarts", "aiChecks", "aiOnlineChecks"] {
            d.set(0, forKey: "stability.\(key)")
        }
        d.set(peakMemoryMB, forKey: "stability.peakMemory")
        d.set(longestRunHours, forKey: "stability.longestRun")
        d.set(trackingSince, forKey: "stability.since")
    }

    private func sample() {
        memoryMB = Self.currentMemoryMB()
        if memoryMB > peakMemoryMB {
            peakMemoryMB = memoryMB
            d.set(peakMemoryMB, forKey: "stability.peakMemory")
        }
    }

    private func thermalChanged() {
        thermal = ProcessInfo.processInfo.thermalState
        if thermal == .serious || thermal == .critical {
            hotEvents += 1
            d.set(hotEvents, forKey: "stability.hotEvents")
        }
    }

    // MARK: Values for the screen

    var uptime: TimeInterval { Date().timeIntervalSince(launchedAt) }

    var aiAvailability: String {
        guard aiChecks > 0 else { return "Not set up" }
        return "\(Int((Double(aiOnlineChecks) / Double(aiChecks) * 100).rounded())) %"
    }

    var thermalText: String {
        switch thermal {
        case .nominal: return "Normal"
        case .fair: return "Warm"
        case .serious: return "Hot (camera paused)"
        case .critical: return "Very hot"
        @unknown default: return "Unknown"
        }
    }

    var batteryText: String {
        let device = UIDevice.current
        let level = device.batteryLevel < 0 ? "?" : "\(Int((device.batteryLevel * 100).rounded())) %"
        switch device.batteryState {
        case .charging: return "\(level), charging"
        case .full: return "\(level), full (plugged in)"
        case .unplugged: return "\(level), on battery"
        default: return level
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        let days = minutes / 1440, hours = (minutes % 1440) / 60, mins = minutes % 60
        if days > 0 { return "\(days) d \(hours) h" }
        if hours > 0 { return "\(hours) h \(mins) min" }
        return "\(mins) min"
    }

    /// Memory the app really uses (the number iOS checks before closing apps).
    static func currentMemoryMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), raw, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }
}
