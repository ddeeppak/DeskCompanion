import Foundation
import CoreMotion
import Combine

/// Air pressure from the iPhone's barometer, with a 3-hour trend (rising / steady / falling).
final class PressureService: ObservableObject {
    enum Trend {
        case rising, steady, falling, unknown

        var text: String {
            switch self {
            case .rising: return "rising"
            case .steady: return "steady"
            case .falling: return "falling"
            case .unknown: return ""
            }
        }
    }

    /// Station pressure in hPa (what the sensor measures at your altitude).
    @Published private(set) var hPa: Double? = nil
    @Published private(set) var trend: Trend = .unknown

    let isAvailable = CMAltimeter.isRelativeAltitudeAvailable()

    private struct Sample: Codable {
        let t: Date
        let p: Double
    }

    private let altimeter = CMAltimeter()
    private var samples: [Sample] = []
    private var running = false
    private let samplesKey = "pressure.samples.v1"
    private let sampleEvery: TimeInterval = 5 * 60
    private let keepFor: TimeInterval = 6 * 3600

    init() {
        if let data = UserDefaults.standard.data(forKey: samplesKey),
           let saved = try? JSONDecoder().decode([Sample].self, from: data) {
            samples = saved.filter { Date().timeIntervalSince($0.t) < keepFor }
        }
        computeTrend()
    }

    func start() {
        guard isAvailable, !running else { return }
        running = true
        altimeter.startRelativeAltitudeUpdates(to: OperationQueue.main) { [weak self] data, _ in
            guard let self = self, let data = data else { return }
            let reading = data.pressure.doubleValue * 10          // kPa -> hPa
            let smoothed = self.hPa.map { $0 * 0.8 + reading * 0.2 } ?? reading
            self.hPa = smoothed
            self.record(smoothed)
        }
    }

    func stop() {
        guard running else { return }
        running = false
        altimeter.stopRelativeAltitudeUpdates()
    }

    /// Value to display: converted to sea-level pressure when the weather service provides the offset.
    func displayValue(seaLevelOffset: Double?) -> Double? {
        guard let hPa = hPa else { return nil }
        return hPa + (seaLevelOffset ?? 0)
    }

    private func record(_ value: Double) {
        let now = Date()
        if let last = samples.last, now.timeIntervalSince(last.t) < sampleEvery { return }
        samples.append(Sample(t: now, p: value))
        samples.removeAll { now.timeIntervalSince($0.t) > keepFor }
        if let data = try? JSONEncoder().encode(samples) {
            UserDefaults.standard.set(data, forKey: samplesKey)
        }
        computeTrend()
    }

    /// Compares with the reading about 3 hours ago (needs at least 45 minutes of data).
    /// More than ±1 hPa per 3 hours counts as rising / falling.
    private func computeTrend() {
        guard let latest = samples.last else { trend = .unknown; return }
        let windowStart = latest.t.addingTimeInterval(-3 * 3600)
        guard let reference = samples.first(where: { $0.t >= windowStart }) else { trend = .unknown; return }
        let span = latest.t.timeIntervalSince(reference.t)
        guard span >= 45 * 60 else { trend = .unknown; return }
        let changePer3h = (latest.p - reference.p) / span * 3 * 3600
        if changePer3h > 1.0 {
            trend = .rising
        } else if changePer3h < -1.0 {
            trend = .falling
        } else {
            trend = .steady
        }
    }
}
