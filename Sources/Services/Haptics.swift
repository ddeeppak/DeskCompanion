import UIKit

/// Short system haptics, used the way Apple's HIG describes them (success, warning, error, selection, light impact).
/// Optional (Settings → Display & Night → Haptics), and silent while the microphone is listening.
enum Haptics {
    static let enabledKey = "haptics.enabled"

    /// Set by SpeechService while listening, so vibrations don't disturb the microphone.
    static var suppressed = false

    private static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    private static let notification = UINotificationFeedbackGenerator()
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let impact = UIImpactFeedbackGenerator(style: .light)

    private static var allowed: Bool { enabled && !suppressed }

    /// Completed something (task ticked, habit done, voice action done, focus session finished).
    static func success() {
        guard allowed else { return }
        notification.notificationOccurred(.success)
    }

    /// Needs attention (timer finished, alarm ringing).
    static func warning() {
        guard allowed else { return }
        notification.notificationOccurred(.warning)
    }

    /// Something failed ("Didn't catch that").
    static func error() {
        guard allowed else { return }
        notification.notificationOccurred(.error)
    }

    /// A value changed (segments, pickers).
    static func selection() {
        guard allowed else { return }
        selectionGenerator.selectionChanged()
    }

    /// Small confirmation (start/pause, snooze, undo).
    static func tap() {
        guard allowed else { return }
        impact.impactOccurred()
    }
}
