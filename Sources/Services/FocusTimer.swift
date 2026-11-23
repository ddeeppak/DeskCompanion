import Foundation
import Combine

extension Notification.Name {
    /// Posted when a focus session or break ends (RootView switches to the Focus screen).
    static let focusPhaseFinished = Notification.Name("focusPhaseFinished")
}

/// Pomodoro timer: focus → break, 4 sessions per cycle. Uses an end time, so it stays accurate.
final class FocusTimer: ObservableObject {
    enum Phase { case focus, rest }
    enum RunState { case ready, running, paused, finished }

    enum Preset: String, CaseIterable, Identifiable {
        case short, long, custom
        var id: String { rawValue }
        var label: String {
            switch self {
            case .short: return "25 / 5"
            case .long: return "50 / 10"
            case .custom: return "Custom"
            }
        }
    }

    @Published var preset: Preset { didSet { settingsChanged() } }
    @Published var customFocusMinutes: Int { didSet { settingsChanged() } }
    @Published var customBreakMinutes: Int { didSet { settingsChanged() } }
    @Published var task: String { didSet { defaults.set(task, forKey: "focus.task") } }
    /// "off", "rain", "noise", "cafe" or "file:<name>" (see SoundLibrary)
    @Published var soundID: String {
        didSet {
            defaults.set(soundID, forKey: "focus.sound")
            updateSound()
        }
    }

    @Published private(set) var phase: Phase = .focus
    @Published private(set) var state: RunState = .ready { didSet { updateSound() } }
    @Published private(set) var remaining: TimeInterval = 25 * 60
    @Published private(set) var phaseTotal: TimeInterval = 25 * 60
    @Published private(set) var sessionsDone = 0               // finished focus sessions in this cycle
    @Published private(set) var lastFinishedPhase: Phase = .focus
    @Published private(set) var lastFinishedMinutes = 0
    @Published private(set) var focusedToday: TimeInterval = 0

    let sessionsPerCycle = 4

    private var endDate: Date?
    private var runStartedAt: Date?
    private var ticker: Timer?
    private let defaults = UserDefaults.standard
    private var dayKey: String

    init() {
        let d = UserDefaults.standard
        preset = Preset(rawValue: d.string(forKey: "focus.preset") ?? "") ?? .short
        customFocusMinutes = d.object(forKey: "focus.customFocus") as? Int ?? 30
        customBreakMinutes = d.object(forKey: "focus.customBreak") as? Int ?? 5
        task = d.string(forKey: "focus.task") ?? "Focus"
        soundID = d.string(forKey: "focus.sound") ?? "off"
        dayKey = HabitStore.key(Date())
        if d.string(forKey: "focus.day") == dayKey {
            focusedToday = d.double(forKey: "focus.today")
            sessionsDone = min(d.integer(forKey: "focus.sessions"), 4)
        }
        remaining = focusLength
        phaseTotal = remaining
    }

    // MARK: Lengths

    var focusLength: TimeInterval {
        switch preset {
        case .short: return 25 * 60
        case .long: return 50 * 60
        case .custom: return TimeInterval(customFocusMinutes * 60)
        }
    }

    var breakLength: TimeInterval {
        switch preset {
        case .short: return 5 * 60
        case .long: return 10 * 60
        case .custom: return TimeInterval(customBreakMinutes * 60)
        }
    }

    var breakMinutes: Int { Int(breakLength / 60) }

    /// Current session number shown as "2 of 4".
    var session: Int { min(sessionsDone + 1, sessionsPerCycle) }

    /// Ring fill: 1 = full time left.
    var progress: Double { phaseTotal > 0 ? max(0, min(1, remaining / phaseTotal)) : 0 }

    /// Focused time today including the session that is running now.
    var liveFocusedToday: TimeInterval {
        var total = HabitStore.key(Date()) == dayKey ? focusedToday : 0
        if state == .running, phase == .focus, let started = runStartedAt {
            total += Date().timeIntervalSince(started)
        }
        return total
    }

    // MARK: Controls

    func toggle() {
        switch state {
        case .running: pause()
        case .ready, .paused: start()
        case .finished: break
        }
    }

    func start() {
        guard state == .ready || state == .paused else { return }
        if state == .ready { phaseTotal = remaining }
        endDate = Date().addingTimeInterval(remaining)
        runStartedAt = Date()
        state = .running
        startTicker()
    }

    func pause() {
        guard state == .running else { return }
        tick()
        guard state == .running else { return }
        accumulate()
        endDate = nil
        state = .paused
        stopTicker()
    }

    func reset() {
        if state == .running { accumulate() }
        stopTicker()
        SoundEngine.shared.stopChime()
        endDate = nil
        if state == .finished { phase = .focus }
        remaining = phase == .focus ? focusLength : breakLength
        phaseTotal = remaining
        state = .ready
    }

    func skip() {
        guard state != .finished else { return }
        finish()
    }

    /// "+5 min" on the finished screen: continue the phase that just ended.
    func extend(minutes: Int) {
        SoundEngine.shared.stopChime()
        if lastFinishedPhase == .focus { sessionsDone = max(0, sessionsDone - 1) }
        phase = lastFinishedPhase
        remaining = TimeInterval(minutes * 60)
        state = .ready
        start()
    }

    func startBreak() {
        SoundEngine.shared.stopChime()
        phase = .rest
        remaining = breakLength
        state = .ready
        start()
    }

    func startFocus() {
        SoundEngine.shared.stopChime()
        if sessionsDone >= sessionsPerCycle { sessionsDone = 0 }
        phase = .focus
        remaining = focusLength
        state = .ready
        start()
    }

    // MARK: Internals

    private func settingsChanged() {
        defaults.set(preset.rawValue, forKey: "focus.preset")
        defaults.set(customFocusMinutes, forKey: "focus.customFocus")
        defaults.set(customBreakMinutes, forKey: "focus.customBreak")
        if state == .ready {
            remaining = phase == .focus ? focusLength : breakLength
            phaseTotal = remaining
        }
    }

    private func tick() {
        guard state == .running, let end = endDate else { return }
        let left = end.timeIntervalSinceNow
        if left <= 0 {
            remaining = 0
            finish()
        } else {
            remaining = left
        }
    }

    private func finish() {
        if state == .running { accumulate() }
        stopTicker()
        endDate = nil
        lastFinishedPhase = phase
        if phase == .focus {
            lastFinishedMinutes = max(1, Int(((phaseTotal - remaining) / 60).rounded()))
            sessionsDone = min(sessionsPerCycle, sessionsDone + 1)
            defaults.set(sessionsDone, forKey: "focus.sessions")
        }
        remaining = 0
        state = .finished
        SoundEngine.shared.startChime()
        NotificationCenter.default.post(name: .focusPhaseFinished, object: nil)
    }

    private func accumulate() {
        defer { runStartedAt = nil }
        guard phase == .focus, let started = runStartedAt else { return }
        let today = HabitStore.key(Date())
        if today != dayKey {
            dayKey = today
            focusedToday = 0
            sessionsDone = 0
        }
        focusedToday += Date().timeIntervalSince(started)
        defaults.set(focusedToday, forKey: "focus.today")
        defaults.set(dayKey, forKey: "focus.day")
    }

    private func updateSound() {
        SoundEngine.shared.setFocusSound(state == .running && phase == .focus ? soundID : "off")
    }

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}
