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

/// 06 Today: arrives in step 3.
struct TodayView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 12) {
                ScreenHeader(title: "Today", subtitle: DateText.short(context.date))
                Spacer(minLength: 0)
                ComingSoonView(
                    icon: "checkmark.circle.fill",
                    headline: "Your day at a glance",
                    step: 3,
                    bullets: [
                        "Schedule from your iPhone Calendar with a \"now\" marker",
                        "Tasks from Reminders: tick, add, add by voice",
                        "Habits with progress rings and streaks"
                    ])
                Spacer(minLength: 0)
            }
            .screenPadding()
        }
    }
}

/// 07 Focus: arrives in step 4.
struct FocusView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScreenHeader(title: "Focus")
            Spacer(minLength: 0)
            ComingSoonView(
                icon: "timer",
                headline: "Deep work timer",
                step: 4,
                bullets: [
                    "Big countdown ring readable from your chair",
                    "Presets 25/5, 50/10 or custom",
                    "Rain, noise or café sounds and a gentle chime"
                ])
            Spacer(minLength: 0)
        }
        .screenPadding()
    }
}
