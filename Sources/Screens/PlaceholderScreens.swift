import SwiftUI

/// 04/05 Assistant: arrives in step 5 (offline voice) and step 6 (local AI).
struct AssistantView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScreenHeader(title: "Assistant")
            Spacer(minLength: 0)
            ComingSoonView(
                icon: "mic.fill",
                headline: "Talk to your desk",
                step: 5,
                bullets: [
                    "Tap the mic or wave over the phone, then speak",
                    "Timers, reminders, lists and calendar work offline",
                    "Questions go to the free AI on your PC (step 6)"
                ])
            Spacer(minLength: 0)
        }
        .screenPadding()
    }
}
