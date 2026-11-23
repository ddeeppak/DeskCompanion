import Foundation

/// Time formats used across the app (12-hour clock, as in the design).
enum TimeText {
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    private static let clockFormatter = formatter("h:mm")       // 6:21
    private static let timeFormatter = formatter("h:mm a")      // 6:21 AM
    private static let hourFormatter = formatter("ha")          // 11AM

    static func clock(_ date: Date) -> String { clockFormatter.string(from: date) }
    static func time(_ date: Date) -> String { timeFormatter.string(from: date) }
    static func hour(_ date: Date) -> String { hourFormatter.string(from: date) }
}
