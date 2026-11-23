import UIKit
import Combine

/// Automatic night clock: shows the dim Night screen on a schedule and lowers screen brightness.
/// Tap the night clock to brighten for 30 seconds ("peek").
final class NightMode: ObservableObject {
    @Published var enabled: Bool { didSet { save(); evaluate() } }
    @Published var startMinutes: Int { didSet { save(); evaluate() } }   // minutes after midnight
    @Published var endMinutes: Int { didSet { save(); evaluate() } }
    @Published var brightness: Double {                                     // 0.01 ... 0.4
        didSet {
            save()
            if showNight { UIScreen.main.brightness = CGFloat(brightness) }
        }
    }
    @Published private(set) var showNight = false

    private var peekUntil: Date?
    private var previewUntil: Date?
    private var savedBrightness: CGFloat?
    private let defaults = UserDefaults.standard

    init() {
        let d = UserDefaults.standard
        enabled = d.object(forKey: "night.enabled") as? Bool ?? true
        startMinutes = d.object(forKey: "night.start") as? Int ?? (22 * 60 + 30)
        endMinutes = d.object(forKey: "night.end") as? Int ?? (6 * 60 + 30)
        brightness = d.object(forKey: "night.brightness") as? Double ?? 0.05
    }

    func isInWindow(_ date: Date) -> Bool {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if startMinutes == endMinutes { return false }
        if startMinutes < endMinutes {
            return minute >= startMinutes && minute < endMinutes
        }
        return minute >= startMinutes || minute < endMinutes     // crosses midnight
    }

    /// Re-check the schedule. Called every minute and whenever settings change.
    func evaluate(now: Date = Date()) {
        if let until = peekUntil, now >= until { peekUntil = nil }
        if let until = previewUntil, now >= until { previewUntil = nil }
        let previewing = previewUntil != nil
        let night = (enabled && isInWindow(now)) || previewing
        let peeking = peekUntil != nil && !previewing
        setShowNight(night && !peeking)
    }

    /// Tap on the night clock: normal screen for a short time, then back to night.
    func peek(seconds: TimeInterval = 30) {
        peekUntil = Date().addingTimeInterval(seconds)
        previewUntil = nil
        evaluate()
        recheck(after: seconds)
    }

    /// "Preview night clock" button in Settings.
    func preview(seconds: TimeInterval = 10) {
        previewUntil = Date().addingTimeInterval(seconds)
        peekUntil = nil
        evaluate()
        recheck(after: seconds)
    }

    /// App going to the background: give the user their normal brightness back.
    func restoreBrightness() {
        if let saved = savedBrightness {
            UIScreen.main.brightness = saved
            savedBrightness = nil
        }
    }

    /// App back in the foreground: dim again if it's night.
    func appBecameActive() {
        if showNight {
            if savedBrightness == nil { savedBrightness = UIScreen.main.brightness }
            UIScreen.main.brightness = CGFloat(brightness)
        }
        evaluate()
    }

    private func recheck(after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.3) { [weak self] in
            self?.evaluate()
        }
    }

    private func setShowNight(_ value: Bool) {
        guard value != showNight else { return }
        showNight = value
        if value {
            if savedBrightness == nil { savedBrightness = UIScreen.main.brightness }
            UIScreen.main.brightness = CGFloat(brightness)
        } else {
            restoreBrightness()
        }
    }

    private func save() {
        defaults.set(enabled, forKey: "night.enabled")
        defaults.set(startMinutes, forKey: "night.start")
        defaults.set(endMinutes, forKey: "night.end")
        defaults.set(brightness, forKey: "night.brightness")
    }
}
