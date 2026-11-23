import SwiftUI
import UIKit

/// 06 Today: Schedule (Calendar) · Tasks (Reminders) · Habits. Columns 1.12 : 1.08 : 1 as in the design.
struct TodayView: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 10) {
                ScreenHeader(title: "Today", subtitle: DateText.short(context.date))
                GeometryReader { geo in
                    let total = geo.size.width - 24
                    HStack(alignment: .top, spacing: 12) {
                        ScheduleCard(now: context.date)
                            .frame(width: total * 1.12 / 3.2)
                        TasksCard()
                            .frame(width: total * 1.08 / 3.2)
                        HabitsCard()
                            .frame(width: total * 1.0 / 3.2)
                    }
                    .frame(height: geo.size.height)
                }
            }
            .screenPadding()
        }
    }
}

// MARK: - Shared bits

private struct CardHeader: View {
    let title: String
    let trailing: String
    @Environment(\.theme) private var theme

    init(_ title: String, trailing: String) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 15, weight: .bold))
            Spacer(minLength: 4)
            Text(trailing)
                .font(.system(size: 13).monospacedDigit())
                .foregroundColor(theme.secondaryLabel)
                .lineLimit(1)
        }
    }
}

private struct EmptyColumn: View {
    let symbol: String
    let title: String
    let message: String
    @Environment(\.theme) private var theme

    init(symbol: String, title: String, message: String) {
        self.symbol = symbol
        self.title = title
        self.message = message
    }

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 36))
                .foregroundColor(theme.secondaryLabel)
                .padding(.bottom, 6)
            Text(title).font(.system(size: 17, weight: .bold))
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryLabel)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 180)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PermissionPrompt: View {
    let text: String
    @Environment(\.theme) private var theme

    init(_ text: String) { self.text = text }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 28))
                .foregroundColor(theme.secondaryLabel)
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryLabel)
                .multilineTextAlignment(.center)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            } label: {
                Text("Allow in Settings")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(theme.accent)
                    .frame(height: 44)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Schedule

private struct ScheduleCard: View {
    let now: Date
    @EnvironmentObject private var planner: PlannerService
    @Environment(\.theme) private var theme

    init(now: Date) { self.now = now }

    private enum Row: Identifiable {
        case event(DayEvent)
        case now
        var id: String {
            switch self {
            case .event(let e): return e.id
            case .now: return "now-marker"
            }
        }
    }

    /// Events with the red "now" marker inserted before the first event that hasn't started yet.
    private var rows: [Row] {
        var result: [Row] = []
        var placed = false
        for event in planner.events {
            if !placed && !event.isAllDay && event.start > now {
                result.append(.now)
                placed = true
            }
            result.append(.event(event))
        }
        if !placed { result.append(.now) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader("Schedule", trailing: countLabel)
            if planner.calendarAccess == .denied {
                PermissionPrompt("Calendar access is off.")
            } else if planner.events.isEmpty {
                EmptyColumn(symbol: "calendar", title: "No Events", message: "Your calendar is clear today.")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(rows) { row in
                            switch row {
                            case .event(let event): eventRow(event)
                            case .now: nowMarker
                            }
                        }
                    }
                    .padding(.top, 9)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .card(padding: EdgeInsets(top: 12, leading: 13, bottom: 12, trailing: 13))
    }

    private var countLabel: String {
        let n = planner.events.count
        if planner.calendarAccess != .granted { return "" }
        return n == 0 ? "None" : (n == 1 ? "1 event" : "\(n) events")
    }

    private func eventRow(_ event: DayEvent) -> some View {
        let past = !event.isAllDay && event.end <= now
        return HStack(alignment: .top, spacing: 8) {
            Text(event.isAllDay ? "All day" : TimeText.clock(event.start))
                .font(.system(size: 13).monospacedDigit())
                .foregroundColor(theme.secondaryLabel)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .frame(width: 36, alignment: .trailing)
                .padding(.top, 5)
            HStack(alignment: .top, spacing: 7) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(past ? theme.secondaryLabel : event.color)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title)
                        .font(.system(size: 14, weight: .bold))
                        .lineLimit(1)
                    if let location = event.location, !past {
                        Text(location)
                            .font(.system(size: 13))
                            .foregroundColor(theme.secondaryLabel)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(past ? theme.fill : event.color.opacity(0.2)))
            .fixedSize(horizontal: false, vertical: true)
        }
        .opacity(past ? 0.5 : 1)
    }

    private var nowMarker: some View {
        HStack(spacing: 0) {
            Text(TimeText.clock(now))
                .font(.system(size: 13, weight: .bold).monospacedDigit())
                .foregroundColor(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.red))
                .frame(width: 44, alignment: .trailing)
            ZStack(alignment: .leading) {
                Rectangle().fill(theme.red).frame(height: 2)
                Circle().fill(theme.red).frame(width: 10, height: 10).offset(x: -4)
            }
        }
        .padding(.vertical, 1)
    }
}

// MARK: - Tasks

private struct TasksCard: View {
    @EnvironmentObject private var planner: PlannerService
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var assistant: AssistantService
    @Environment(\.theme) private var theme
    @State private var adding = false
    @State private var newTitle = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader("Tasks", trailing: planner.remindersAccess == .granted && !planner.tasks.isEmpty
                       ? "\(planner.doneCount) of \(planner.tasks.count)" : "")
            if planner.remindersAccess == .denied {
                PermissionPrompt("Reminders access is off.")
            } else if planner.tasks.isEmpty && !adding {
                VStack(spacing: 5) {
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 36))
                        .foregroundColor(theme.secondaryLabel)
                        .padding(.bottom, 6)
                    Text("No Tasks").font(.system(size: 17, weight: .bold))
                    Text("Say “Add buy milk to my list”.")
                        .font(.system(size: 13))
                        .foregroundColor(theme.secondaryLabel)
                        .multilineTextAlignment(.center)
                    Button {
                        assistant.listen()
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "mic.fill")
                            Text("Add by Voice")
                        }
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(theme.onAccent)
                        .padding(.horizontal, 18)
                        .frame(height: 44)
                        .background(Capsule().fill(theme.accent))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 10)
                    Button("or type a task") { startAdding() }
                        .font(.system(size: 13))
                        .foregroundColor(theme.accent)
                        .frame(height: 32)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(planner.tasks) { task in
                            taskRow(task)
                        }
                        if adding { newTaskField }
                    }
                    .padding(.top, 4)
                }
                footer
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .card(padding: EdgeInsets(top: 12, leading: 13, bottom: 12, trailing: 13))
    }

    private func taskRow(_ task: TaskItem) -> some View {
        Button {
            planner.toggle(task)
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(task.isCompleted ? theme.accent : Color.clear)
                    Circle()
                        .strokeBorder(task.isCompleted ? theme.accent : theme.tertiaryLabel, lineWidth: 1.5)
                    if task.isCompleted {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(theme.onAccent)
                    }
                }
                .frame(width: 22, height: 22)
                VStack(spacing: 0) {
                    HStack {
                        Text(task.title)
                            .font(.system(size: 15))
                            .foregroundColor(task.isCompleted ? theme.secondaryLabel : theme.label)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .frame(height: 32)
                    Rectangle().fill(theme.separator).frame(height: 1)
                }
            }
            .frame(height: 33)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(task.title)
        .accessibilityValue(task.isCompleted ? "Done" : "Not done")
        .accessibilityHint("Double-tap to toggle")
    }

    private var newTaskField: some View {
        HStack(spacing: 10) {
            Circle().strokeBorder(theme.accent, lineWidth: 1.5).frame(width: 22, height: 22)
            TextField("New task", text: $newTitle)
                .font(.system(size: 15))
                .focused($fieldFocused)
                .submitLabel(.done)
                .onSubmit {
                    planner.add(title: newTitle)
                    newTitle = ""
                    adding = false
                }
        }
        .frame(height: 33)
    }

    private var footer: some View {
        HStack {
            Button { startAdding() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill").font(.system(size: 22))
                    Text("New Task").font(.system(size: 15, weight: .bold))
                }
                .foregroundColor(theme.accent)
                .frame(height: 44)
            }
            .buttonStyle(.plain)
            Spacer()
            Button { assistant.listen() } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 19))
                    .foregroundColor(theme.accent)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(theme.accentTint))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add a task by voice")
        }
        .padding(.top, 4)
    }

    private func startAdding() {
        adding = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { fieldFocused = true }
    }
}

// MARK: - Habits

private struct HabitsCard: View {
    @EnvironmentObject private var habits: HabitStore
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Habits").font(.system(size: 15, weight: .bold))
                Spacer(minLength: 4)
                if habits.perfectStreak > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "flame.fill").font(.system(size: 13))
                        Text("\(habits.perfectStreak) days")
                    }
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(theme.orange)
                }
            }
            if habits.habits.isEmpty {
                EmptyColumn(symbol: "star", title: "No Habits", message: "Add habits in Settings → Today & Habits.")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(Array(habits.habits.enumerated()), id: \.element.id) { index, habit in
                            Button { habits.tap(habit) } label: { row(habit) }
                                .buttonStyle(.plain)
                                .accessibilityElement(children: .combine)
                                .accessibilityHint("Double-tap to tick or count")
                            if index < habits.habits.count - 1 {
                                Rectangle().fill(theme.separator).frame(height: 1)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .card(padding: EdgeInsets(top: 12, leading: 13, bottom: 12, trailing: 13))
    }

    private func row(_ habit: Habit) -> some View {
        HStack(spacing: 10) {
            HabitRing(progress: habits.progress(habit), done: habits.isDone(habit))
            VStack(alignment: .leading, spacing: 1) {
                Text(habit.name)
                    .font(.system(size: 15))
                    .lineLimit(1)
                Text(habits.subtitle(habit))
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundColor(theme.secondaryLabel)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

struct HabitRing: View {
    let progress: Double
    let done: Bool
    @Environment(\.theme) private var theme

    init(progress: Double, done: Bool) {
        self.progress = progress
        self.done = done
    }

    var body: some View {
        ZStack {
            if done {
                Circle().fill(theme.green)
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Color(hex: 0x06140E))
            } else {
                Circle().stroke(theme.fill, lineWidth: 4.5)
                Circle()
                    .trim(from: 0, to: CGFloat(progress))
                    .stroke(theme.accent2, style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: done ? 34 : 29.5, height: done ? 34 : 29.5)
        .frame(width: 34, height: 34)
    }
}
