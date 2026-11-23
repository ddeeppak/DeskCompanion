import SwiftUI
import UIKit

/// Settings → Today & Habits: Calendar/Reminders access, which Reminders list feeds Tasks, habit list.
struct TodaySettings: View {
    @EnvironmentObject private var planner: PlannerService
    @EnvironmentObject private var habits: HabitStore
    @Environment(\.theme) private var theme
    @State private var newName = ""
    @State private var newTarget = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Calendar & Reminders")
            VStack(spacing: 0) {
                SettingsRow {
                    Text("Calendar")
                    Spacer(minLength: 8)
                    Text(accessText(planner.calendarAccess)).foregroundColor(theme.secondaryLabel)
                }
                RowSeparator()
                SettingsRow {
                    Text("Reminders")
                    Spacer(minLength: 8)
                    Text(accessText(planner.remindersAccess)).foregroundColor(theme.secondaryLabel)
                }
                RowSeparator()
                SettingsRow {
                    Text("Tasks list")
                    Spacer(minLength: 8)
                    Menu {
                        ForEach(planner.reminderLists) { list in
                            Button(list.title) { planner.selectedListID = list.id }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(planner.selectedListTitle)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(theme.accent)
                    }
                    .disabled(planner.reminderLists.isEmpty)
                }
            }
            .groupedBox()

            if planner.calendarAccess == .denied || planner.remindersAccess == .denied {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                } label: {
                    Text("Open iPhone Settings to allow access")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.accent)
                        .frame(height: 44)
                }
                .buttonStyle(.plain)
                .padding(.leading, 14)
            }

            SectionLabel("Habits")
                .padding(.top, 10)
            VStack(spacing: 0) {
                ForEach(habits.habits) { habit in
                    SettingsRow {
                        Image(systemName: habit.symbol)
                            .foregroundColor(theme.accent2)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(habit.name)
                            Text(habit.target > 1 ? "Count to \(habit.target) \(habit.unit)" : "Tick once a day")
                                .font(.system(size: 13))
                                .foregroundColor(theme.secondaryLabel)
                        }
                        Spacer(minLength: 8)
                        Button { habits.remove(habit) } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 22))
                                .foregroundColor(theme.red)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                    }
                    RowSeparator()
                }
                SettingsRow {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(theme.green)
                        .frame(width: 24)
                    TextField("New habit", text: $newName)
                        .submitLabel(.done)
                        .onSubmit(addHabit)
                    Stepper("", value: $newTarget, in: 1...20)
                        .labelsHidden()
                    Text(newTarget == 1 ? "once" : "×\(newTarget)")
                        .font(.system(size: 15).monospacedDigit())
                        .foregroundColor(theme.secondaryLabel)
                        .frame(width: 40, alignment: .leading)
                    Button("Add", action: addHabit)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(theme.accent)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .groupedBox()

            Text("Tap a habit on the Today screen to tick it. Counters go up by one per tap and reset after the goal.")
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryLabel)
                .padding(.leading, 14)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func addHabit() {
        habits.add(name: newName, target: newTarget)
        newName = ""
        newTarget = 1
    }

    private func accessText(_ access: PlannerService.Access) -> String {
        switch access {
        case .granted: return "Allowed"
        case .denied: return "Not allowed"
        case .unknown: return "Not asked yet"
        }
    }
}
