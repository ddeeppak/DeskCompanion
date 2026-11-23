import EventKit
import SwiftUI
import Combine

struct DayEvent: Identifiable {
    let id: String
    let title: String
    let location: String?
    let start: Date
    let end: Date
    let isAllDay: Bool
    let color: Color
}

struct TaskItem: Identifiable, Equatable {
    let id: String
    let title: String
    let isCompleted: Bool
    let dueDate: Date?
    let hasDueTime: Bool
}

struct ReminderList: Identifiable {
    let id: String
    let title: String
}

/// Today's events (iPhone Calendar) and tasks (iPhone Reminders), plus due-reminder alerts.
final class PlannerService: ObservableObject {
    enum Access { case unknown, granted, denied }

    @Published private(set) var calendarAccess: Access = .unknown
    @Published private(set) var remindersAccess: Access = .unknown
    @Published private(set) var events: [DayEvent] = []
    @Published private(set) var tasks: [TaskItem] = []
    @Published private(set) var reminderLists: [ReminderList] = []
    @Published private(set) var alert: TaskItem? = nil
    @Published var selectedListID: String? = nil {
        didSet {
            UserDefaults.standard.set(selectedListID, forKey: listKey)
            reloadTasks()
        }
    }

    let store = EKEventStore()
    private let listKey = "planner.reminderList"
    private var changeObserver: NSObjectProtocol?
    private var alertedIDs: Set<String> = []
    private var snoozedUntil: [String: Date] = [:]
    private var started = false
    private let voiceKey = "planner.voiceCreated"
    private var voiceCreated: [String: Date] = [:]

    init() {
        selectedListID = UserDefaults.standard.string(forKey: "planner.reminderList")
        voiceCreated = UserDefaults.standard.dictionary(forKey: "planner.voiceCreated") as? [String: Date] ?? [:]
    }

    deinit {
        if let observer = changeObserver { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: Permissions + loading

    func start() {
        guard !started else { refresh(); return }
        started = true
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
                self?.refresh()
            }
        calendarAccess = Self.access(for: .event)
        remindersAccess = Self.access(for: .reminder)

        if calendarAccess == .unknown {
            store.requestAccess(to: .event) { [weak self] granted, _ in
                DispatchQueue.main.async {
                    self?.calendarAccess = granted ? .granted : .denied
                    self?.reloadEvents()
                    self?.requestRemindersIfNeeded()     // one permission prompt at a time
                }
            }
        } else {
            reloadEvents()
            requestRemindersIfNeeded()
        }
    }

    private func requestRemindersIfNeeded() {
        if remindersAccess == .unknown {
            store.requestAccess(to: .reminder) { [weak self] granted, _ in
                DispatchQueue.main.async {
                    self?.remindersAccess = granted ? .granted : .denied
                    self?.reloadTasks()
                }
            }
        } else {
            reloadTasks()
        }
    }

    func refresh() {
        calendarAccess = Self.access(for: .event)
        remindersAccess = Self.access(for: .reminder)
        reloadEvents()
        reloadTasks()
    }

    private static func access(for type: EKEntityType) -> Access {
        switch EKEventStore.authorizationStatus(for: type) {
        case .notDetermined: return .unknown
        case .restricted, .denied: return .denied
        default: return .granted
        }
    }

    private func reloadEvents() {
        events = events(on: Date())
    }

    /// Events for any day (used by the assistant for "what's on tomorrow?").
    func events(on day: Date) -> [DayEvent] {
        guard calendarAccess == .granted else { return [] }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .sorted { lhs, rhs in
                if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
                return lhs.startDate < rhs.startDate
            }
            .map { event in
                let base = event.eventIdentifier ?? UUID().uuidString
                return DayEvent(
                    id: "\(base)-\(event.startDate.timeIntervalSince1970)",
                    title: event.title ?? "Event",
                    location: (event.location?.isEmpty == false) ? event.location : nil,
                    start: event.startDate,
                    end: event.endDate,
                    isAllDay: event.isAllDay,
                    color: Color(UIColor(cgColor: event.calendar.cgColor)))
            }
    }

    private func reloadTasks() {
        guard remindersAccess == .granted else { tasks = []; reminderLists = []; return }
        let calendars = store.calendars(for: .reminder)
        reminderLists = calendars.map { ReminderList(id: $0.calendarIdentifier, title: $0.title) }
        guard let list = selectedList() else { tasks = []; return }

        let startOfDay = Calendar.current.startOfDay(for: Date())
        let incompletePredicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: [list])
        let completedPredicate = store.predicateForCompletedReminders(
            withCompletionDateStarting: startOfDay, ending: Date().addingTimeInterval(60), calendars: [list])

        _ = store.fetchReminders(matching: incompletePredicate) { [weak self] incomplete in
            guard let self = self else { return }
            _ = self.store.fetchReminders(matching: completedPredicate) { completed in
                let open = (incomplete ?? []).map(Self.item).sorted(by: Self.openOrder)
                let done = (completed ?? []).map(Self.item)
                DispatchQueue.main.async {
                    self.tasks = done + open           // design: done first, then open
                    self.checkAlerts()
                }
            }
        }
    }

    private func selectedList() -> EKCalendar? {
        if let id = selectedListID, let list = store.calendar(withIdentifier: id) { return list }
        return store.defaultCalendarForNewReminders()
    }

    var selectedListTitle: String { selectedList()?.title ?? "None" }

    private static func item(_ reminder: EKReminder) -> TaskItem {
        var due: Date? = nil
        var hasTime = false
        if let components = reminder.dueDateComponents {
            due = Calendar.current.date(from: components)
            hasTime = components.hour != nil
        }
        return TaskItem(id: reminder.calendarItemIdentifier,
                        title: reminder.title ?? "Task",
                        isCompleted: reminder.isCompleted,
                        dueDate: due,
                        hasDueTime: hasTime)
    }

    private static func openOrder(_ a: TaskItem, _ b: TaskItem) -> Bool {
        switch (a.dueDate, b.dueDate) {
        case let (x?, y?): return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    // MARK: Queries used by Home / Today

    func nextEvent(after now: Date) -> DayEvent? {
        events.first { !$0.isAllDay && $0.end > now }
    }

    var doneCount: Int { tasks.filter { $0.isCompleted }.count }
    var nextTask: TaskItem? { tasks.first { !$0.isCompleted } }

    // MARK: Changes

    func toggle(_ task: TaskItem) {
        guard let reminder = store.calendarItem(withIdentifier: task.id) as? EKReminder else { return }
        reminder.isCompleted = !reminder.isCompleted
        try? store.save(reminder, commit: true)
        reloadTasks()
    }

    func add(title: String) {
        addReminder(title: title, due: nil, byVoice: false)
    }

    /// Creates a reminder (with an alert at `due`) in the chosen list. Returns its id, for Undo.
    @discardableResult
    func addReminder(title: String, due: Date?, byVoice: Bool) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard remindersAccess == .granted, !trimmed.isEmpty, let list = selectedList() else { return nil }
        let reminder = EKReminder(eventStore: store)
        reminder.title = trimmed
        reminder.calendar = list
        if let due = due {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        do { try store.save(reminder, commit: true) } catch { return nil }
        let id = reminder.calendarItemIdentifier
        if byVoice {
            voiceCreated[id] = Date()
            UserDefaults.standard.set(voiceCreated, forKey: voiceKey)
        }
        reloadTasks()
        return id
    }

    func deleteReminder(id: String) {
        if let reminder = store.calendarItem(withIdentifier: id) as? EKReminder {
            try? store.remove(reminder, commit: true)
        }
        reloadTasks()
    }

    /// When a reminder was created by voice (for "set by voice at 9:45 AM").
    func voiceCreatedAt(_ id: String) -> Date? { voiceCreated[id] }

    // MARK: Due reminder alerts (banner over Home)

    func checkAlerts(now: Date = Date()) {
        guard alert == nil else { return }
        for task in tasks where !task.isCompleted && task.hasDueTime {
            guard let due = task.dueDate, due <= now else { continue }
            if let until = snoozedUntil[task.id] {
                if now >= until {
                    snoozedUntil[task.id] = nil
                    alert = task
                    return
                }
                continue
            }
            // Only alert for reminders that became due in the last 15 minutes.
            if !alertedIDs.contains(task.id) && now.timeIntervalSince(due) < 15 * 60 {
                alertedIDs.insert(task.id)
                alert = task
                return
            }
        }
    }

    func snoozeAlert(minutes: Int = 10) {
        guard let task = alert else { return }
        snoozedUntil[task.id] = Date().addingTimeInterval(TimeInterval(minutes * 60))
        alert = nil
    }

    func completeAlert() {
        guard let task = alert else { return }
        alert = nil
        if !task.isCompleted { toggle(task) }
    }
}
