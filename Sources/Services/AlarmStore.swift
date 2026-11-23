import Foundation
import Combine
import UserNotifications

struct Alarm: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var hour: Int
    var minute: Int
    var days: [Int] = []          // Calendar weekdays: 1 = Sun … 7 = Sat. Empty = rings once.
    var enabled: Bool = true
    var label: String = "Alarm"
    var tone: String = SoundEngine.AlarmTone.chime.rawValue
    var rising: Bool = true       // "Gentle start": gets louder over 30 s
    var lastFired: Date? = nil

    static let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]                 // Mon first
    static let shortNames = [1: "Sun", 2: "Mon", 3: "Tue", 4: "Wed", 5: "Thu", 6: "Fri", 7: "Sat"]
    static let letters = [1: "S", 2: "M", 3: "T", 4: "W", 5: "T", 6: "F", 7: "S"]

    var timeText: String {
        let h12 = hour % 12 == 0 ? 12 : hour % 12
        return "\(h12):\(String(format: "%02d", minute)) \(hour < 12 ? "AM" : "PM")"
    }

    var daysText: String {
        let set = Set(days)
        if set.isEmpty { return "Once" }
        if set.count == 7 { return "Every day" }
        if set == [2, 3, 4, 5, 6] { return "Weekdays" }
        if set == [1, 7] { return "Weekends" }
        return Self.weekdayOrder.filter { set.contains($0) }.compactMap { Self.shortNames[$0] }.joined(separator: ", ")
    }

    func nextFire(after now: Date, calendar: Calendar = .current) -> Date? {
        let today = calendar.startOfDay(for: now)
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let fire = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                  fire > now else { continue }
            if days.isEmpty || days.contains(calendar.component(.weekday, from: fire)) { return fire }
        }
        return nil
    }

    func previousFire(atOrBefore now: Date, calendar: Calendar = .current) -> Date? {
        let today = calendar.startOfDay(for: now)
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today),
                  let fire = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                  fire <= now else { continue }
            if days.isEmpty || days.contains(calendar.component(.weekday, from: fire)) { return fire }
        }
        return nil
    }
}

/// In-app alarms. The app is always open on the desk, so it rings itself (full screen, looping tone).
/// A local notification is scheduled as a backup in case the app isn't running.
final class AlarmStore: ObservableObject {
    @Published var featureEnabled: Bool { didSet { save(); reschedule() } }
    @Published var alarms: [Alarm] { didSet { save(); reschedule() } }
    @Published var snoozeMinutes: Int { didSet { save() } }
    @Published var volume: Double { didSet { save() } }
    @Published private(set) var ringing: Alarm? = nil

    private var snoozedID: UUID?
    private var snoozedUntil: Date?
    private var ringStarted: Date?

    private static let alarmsKey = "alarms.list.v1"

    init() {
        let d = UserDefaults.standard
        featureEnabled = d.object(forKey: "alarms.enabled") as? Bool ?? true
        snoozeMinutes = d.object(forKey: "alarms.snooze") as? Int ?? 9
        volume = d.object(forKey: "alarms.volume") as? Double ?? 0.8
        if let data = d.data(forKey: Self.alarmsKey), let saved = try? JSONDecoder().decode([Alarm].self, from: data) {
            alarms = saved
        } else {
            alarms = []
        }
    }

    /// Soonest enabled alarm (for the Night screen chip).
    var nextAlarm: (alarm: Alarm, date: Date)? {
        guard featureEnabled else { return nil }
        let now = Date()
        if let id = snoozedID, let until = snoozedUntil, let alarm = alarms.first(where: { $0.id == id }) {
            return (alarm, until)
        }
        return alarms
            .filter { $0.enabled }
            .compactMap { alarm in alarm.nextFire(after: now).map { (alarm: alarm, date: $0) } }
            .min { $0.date < $1.date }
    }

    // MARK: Ringing

    /// Called every few seconds by RootView.
    func check(now: Date = Date()) {
        guard featureEnabled else { return }
        if ringing != nil {
            if let started = ringStarted, now.timeIntervalSince(started) > 10 * 60 { stop() }   // auto-stop
            return
        }
        if let until = snoozedUntil, now >= until, let id = snoozedID,
           let alarm = alarms.first(where: { $0.id == id }) {
            snoozedUntil = nil
            snoozedID = nil
            ring(alarm)
            return
        }
        for index in alarms.indices where alarms[index].enabled {
            let alarm = alarms[index]
            guard let previous = alarm.previousFire(atOrBefore: now),
                  now.timeIntervalSince(previous) < 120 else { continue }
            if let last = alarm.lastFired, abs(last.timeIntervalSince(previous)) < 1 { continue }
            var updated = alarm
            updated.lastFired = previous
            if alarm.days.isEmpty { updated.enabled = false }      // one-time alarm
            alarms[index] = updated
            ring(updated)
            return
        }
    }

    private func ring(_ alarm: Alarm) {
        ringing = alarm
        ringStarted = Date()
        SoundEngine.shared.startAlarm(tone: SoundEngine.AlarmTone(rawValue: alarm.tone) ?? .chime,
                                      volume: Float(volume), rising: alarm.rising)
    }

    func stop() {
        ringing = nil
        ringStarted = nil
        SoundEngine.shared.stopAlarm()
    }

    func snooze() {
        guard let alarm = ringing else { return }
        snoozedID = alarm.id
        snoozedUntil = Date().addingTimeInterval(TimeInterval(snoozeMinutes * 60))
        stop()
    }

    // MARK: Editing

    @discardableResult
    func add() -> UUID {
        let alarm = Alarm(hour: 7, minute: 0, days: [2, 3, 4, 5, 6])
        alarms.append(alarm)
        requestNotificationPermission()
        return alarm.id
    }

    func remove(_ id: UUID) {
        alarms.removeAll { $0.id == id }
        if snoozedID == id { snoozedID = nil; snoozedUntil = nil }
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: Persistence + backup notifications

    private func save() {
        let d = UserDefaults.standard
        d.set(featureEnabled, forKey: "alarms.enabled")
        d.set(snoozeMinutes, forKey: "alarms.snooze")
        d.set(volume, forKey: "alarms.volume")
        if let data = try? JSONEncoder().encode(alarms) { d.set(data, forKey: Self.alarmsKey) }
    }

    private func reschedule() {
        let snapshot = alarms
        let enabled = featureEnabled
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let old = requests.map { $0.identifier }.filter { $0.hasPrefix("alarm-") }
            center.removePendingNotificationRequests(withIdentifiers: old)
            guard enabled else { return }
            for alarm in snapshot where alarm.enabled {
                let content = UNMutableNotificationContent()
                content.title = alarm.label
                content.body = "Alarm · \(alarm.timeText)"
                content.sound = .default
                if alarm.days.isEmpty {
                    guard let fire = alarm.nextFire(after: Date()) else { continue }
                    let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
                    let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
                    center.add(UNNotificationRequest(identifier: "alarm-\(alarm.id.uuidString)",
                                                     content: content, trigger: trigger))
                } else {
                    for day in alarm.days {
                        var parts = DateComponents()
                        parts.weekday = day
                        parts.hour = alarm.hour
                        parts.minute = alarm.minute
                        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: true)
                        center.add(UNNotificationRequest(identifier: "alarm-\(alarm.id.uuidString)-\(day)",
                                                         content: content, trigger: trigger))
                    }
                }
            }
        }
    }
}

/// While the app is open it rings by itself, so the backup notification is not shown on top.
final class NotificationRelay: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRelay()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])
    }
}
