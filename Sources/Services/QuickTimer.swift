import Foundation
import Combine

/// Simple countdown timer set by voice ("set a 10 minute timer"). Chimes and shows a banner when done.
final class QuickTimer: ObservableObject {
    @Published private(set) var endDate: Date? = nil
    @Published private(set) var totalSeconds = 0
    @Published private(set) var ringing = false

    private var ticker: Timer?

    var isRunning: Bool { endDate != nil }

    /// "10-minute timer", "1 h 30 min timer"
    var label: String { Self.describe(totalSeconds) + " timer" }

    static func describe(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return m > 0 ? "\(h) h \(m) min" : (h == 1 ? "1-hour" : "\(h)-hour") }
        if m > 0 { return s > 0 ? "\(m) min \(s) s" : "\(m)-minute" }
        return "\(s)-second"
    }

    /// Spoken form: "10 minutes", "1 hour and 30 minutes"
    static func spoken(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        var parts: [String] = []
        if h > 0 { parts.append(h == 1 ? "1 hour" : "\(h) hours") }
        if m > 0 { parts.append(m == 1 ? "1 minute" : "\(m) minutes") }
        if s > 0 && h == 0 { parts.append(s == 1 ? "1 second" : "\(s) seconds") }
        return parts.joined(separator: " and ")
    }

    func start(seconds: Int) {
        stopRinging()
        totalSeconds = seconds
        endDate = Date().addingTimeInterval(TimeInterval(seconds))
        ticker?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    func cancel() {
        ticker?.invalidate()
        ticker = nil
        endDate = nil
        stopRinging()
    }

    func addMinute() { start(seconds: 60) }

    func stopRinging() {
        guard ringing else { return }
        ringing = false
        SoundEngine.shared.stopChime()
    }

    private func check() {
        guard let end = endDate, Date() >= end else { return }
        ticker?.invalidate()
        ticker = nil
        endDate = nil
        ringing = true
        Haptics.warning()
        SoundEngine.shared.startChime(maxSeconds: 60)
    }
}
