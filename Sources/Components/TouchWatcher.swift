import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Notices every touch in the window without taking part in any gesture.
/// (A SwiftUI DragGesture on the root view blocks ScrollViews on iOS 15, so we watch touches at the UIKit level.)
final class PassiveTouchRecognizer: UIGestureRecognizer {
    var onTouch: (() -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouch?()
        state = .failed          // never "wins", so buttons and scroll views work normally
    }
}

enum TouchWatcher {
    private static var installed = false

    /// Installs once on the app's window. Retries briefly until the window exists.
    static func install(_ handler: @escaping () -> Void, attempt: Int = 0) {
        guard !installed else { return }
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        guard let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first else {
            if attempt < 10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { install(handler, attempt: attempt + 1) }
            }
            return
        }
        let recognizer = PassiveTouchRecognizer(target: nil, action: nil)
        recognizer.onTouch = handler
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        window.addGestureRecognizer(recognizer)
        installed = true
    }
}
