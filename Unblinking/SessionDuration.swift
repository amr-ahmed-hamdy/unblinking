import Foundation

/// How long a wake session should last.
enum SessionDuration: Equatable, Hashable {
    case indefinite
    case seconds(Int)

    static let presets: [SessionDuration] = [
        .seconds(15 * 60),
        .seconds(30 * 60),
        .seconds(60 * 60),
        .seconds(2 * 60 * 60),
        .seconds(4 * 60 * 60),
        .indefinite,
    ]

    var title: String {
        switch self {
        case .indefinite:
            return "Indefinitely"
        case .seconds(let total):
            if total >= 3600 {
                let hours = Double(total) / 3600
                let trimmed = hours.rounded() == hours
                    ? String(Int(hours))
                    : String(format: "%.1f", hours)
                return "\(trimmed) hour\(hours == 1 ? "" : "s")"
            }
            let minutes = total / 60
            return "\(minutes) minute\(minutes == 1 ? "" : "s")"
        }
    }

    /// Seconds, or `nil` for an open-ended session.
    var secondsValue: Int? {
        if case .seconds(let value) = self { return value }
        return nil
    }

    /// Round-trips through `UserDefaults` and `NSMenuItem.tag`, where 0 means indefinite.
    var tagValue: Int { secondsValue ?? 0 }

    init(tagValue: Int) {
        self = tagValue > 0 ? .seconds(tagValue) : .indefinite
    }
}

enum TimeFormatting {
    /// Compact duration for the menu bar and menu, e.g. "42m" or "1h 18m".
    static func compact(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60

        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }
}
