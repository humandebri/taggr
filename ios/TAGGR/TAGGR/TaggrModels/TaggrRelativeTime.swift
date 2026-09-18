import Foundation

enum TaggrRelativeTime {
    private static let second: TimeInterval = 1
    private static let minute = 60 * second
    private static let hour = 60 * minute
    private static let day = 24 * hour

    static func string(from timestamp: LosslessInt, now: Date = .now) -> String {
        let date = Date(timeIntervalSince1970: Double(timestamp.value) / 1_000_000_000)
        let diff = max(0, now.timeIntervalSince(date))
        if diff < minute {
            return "\(max(1, Int((diff / second).rounded())))s ago"
        }
        if diff < hour {
            return "\(Int((diff / minute).rounded()))m ago"
        }
        if diff < day {
            return "\(Int((diff / hour).rounded()))h ago"
        }
        if diff < 90 * day {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.year(.twoDigits).month(.abbreviated).day())
    }

    static func refreshInterval(from timestamp: LosslessInt, now: Date = .now) -> TimeInterval {
        let date = Date(timeIntervalSince1970: Double(timestamp.value) / 1_000_000_000)
        return now.timeIntervalSince(date) < day ? 30 : 3_600
    }
}
