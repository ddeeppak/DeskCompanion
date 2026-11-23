import SwiftUI

enum AppScreen: String, CaseIterable, Identifiable {
    case home, assistant, today, notes, focus, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .assistant: return "Assistant"
        case .today: return "Today"
        case .notes: return "Notes"
        case .focus: return "Focus"
        case .settings: return "Settings"
        }
    }

    /// SF Symbols available on iOS 15
    var symbol: String {
        switch self {
        case .home: return "house"
        case .assistant: return "sparkles"
        case .today: return "checkmark.circle"
        case .notes: return "lightbulb"
        case .focus: return "timer"
        case .settings: return "gearshape"
        }
    }

    var selectedSymbol: String {
        switch self {
        case .home: return "house.fill"
        case .assistant: return "sparkles"
        case .today: return "checkmark.circle.fill"
        case .notes: return "lightbulb.fill"
        case .focus: return "timer"
        case .settings: return "gearshape.fill"
        }
    }
}

enum AIStatus {
    case notSetUp, online, offline
}

final class AppState: ObservableObject {
    @Published var screen: AppScreen = .home {
        didSet { registerTouch() }
    }
    @Published var railVisible = true
    @Published var aiStatus: AIStatus = .notSetUp
    /// Opens a specific Settings section next time Settings appears (e.g. "alarms" from the assistant's Edit button).
    @Published var pendingSettingsSection: String? = nil
    @Published var style: AppStyle {
        didSet { UserDefaults.standard.set(style.rawValue, forKey: Self.styleKey) }
    }

    /// Seconds without a touch before the rail hides on Home.
    let railHideDelay: TimeInterval = 30

    private static let styleKey = "appStyle"
    private var hideWork: DispatchWorkItem?

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.styleKey) ?? ""
        style = AppStyle(rawValue: saved) ?? .calm
    }

    private var lastTouch = Date.distantPast

    /// Called continuously while a finger moves; throttled so the timer restarts at most twice a second.
    func touchBegan() {
        let now = Date()
        guard now.timeIntervalSince(lastTouch) > 0.5 else { return }
        lastTouch = now
        registerTouch()
    }

    /// Call on any touch: shows the rail again and restarts the 30 s timer.
    func registerTouch() {
        if !railVisible {
            withAnimation(.easeOut(duration: 0.25)) { railVisible = true }
        }
        scheduleRailHide()
    }

    func scheduleRailHide() {
        hideWork?.cancel()
        guard screen == .home else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.screen == .home else { return }
            withAnimation(.easeInOut(duration: 0.45)) { self.railVisible = false }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + railHideDelay, execute: work)
    }
}
