import UIKit
import Combine

/// Live battery level and charging state for the status row.
final class BatteryMonitor: ObservableObject {
    @Published private(set) var level: Int = 100
    @Published private(set) var charging = false

    private var observers: [NSObjectProtocol] = []

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        update()
        let center = NotificationCenter.default
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.update()
            }
            observers.append(token)
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func update() {
        let raw = UIDevice.current.batteryLevel          // -1 when unknown
        level = raw < 0 ? 100 : Int((raw * 100).rounded())
        let state = UIDevice.current.batteryState
        charging = (state == .charging || state == .full)
    }

    var symbol: String {
        if charging { return "battery.100.bolt" }
        return level <= 20 ? "battery.25" : "battery.100"
    }
}
