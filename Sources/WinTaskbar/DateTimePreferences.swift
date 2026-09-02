import Foundation

enum DateTimeCalendarKind: String, CaseIterable, Identifiable {
    case gregorian = "Gregorian Calendar"

    var id: String { rawValue }
    var identifier: Calendar.Identifier { .gregorian }
}

enum DateTimeFirstDayOfWeek: String, CaseIterable, Identifiable {
    case sunday = "Sunday"
    case monday = "Monday"
    case tuesday = "Tuesday"
    case wednesday = "Wednesday"
    case thursday = "Thursday"
    case friday = "Friday"
    case saturday = "Saturday"

    var id: String { rawValue }
    var calendarWeekday: Int { Self.allCases.firstIndex(of: self)! + 1 }
}

struct DateTimeFormatConfiguration: Equatable {
    let calendarKind: DateTimeCalendarKind
    let firstDayOfWeek: DateTimeFirstDayOfWeek
    let shortDatePattern: String
    let longDatePattern: String
    let longDateIncludesLunar: Bool
    let shortTimePattern: String
    let longTimePattern: String
    let amSymbol: String
    let pmSymbol: String
}

enum DateTimeLongDateStyle: String, CaseIterable, Identifiable {
    case windowsFull
    case monthDayYear
    case dayMonthYear
    case yearMonthDay
    case yearMonthDayPadded
    case chinese
    case chinesePadded
    case chineseLunar
    case chinesePaddedLunar
    case custom

    var id: String { rawValue }

    var pattern: String? {
        switch self {
        case .windowsFull: "EEEE, MMMM d, yyyy"
        case .monthDayYear: "MMMM d, yyyy"
        case .dayMonthYear: "EEEE, d MMMM, yyyy"
        case .yearMonthDay: "yyyy/M/d"
        case .yearMonthDayPadded: "yyyy/MM/dd"
        case .chinese, .chineseLunar: "yyyy年M月d日"
        case .chinesePadded, .chinesePaddedLunar: "yyyy年MM月dd日"
        case .custom: nil
        }
    }

    var includesLunar: Bool {
        self == .chineseLunar || self == .chinesePaddedLunar
    }

    static func migrated(from pattern: String?) -> DateTimeLongDateStyle {
        guard let pattern else { return .windowsFull }
        return allCases.first { $0.pattern == pattern && !$0.includesLunar } ?? .custom
    }
}

enum DateTimeFormatCatalog {
    static let shortDatePatterns = [
        "M/d/yyyy", "M/d/yy", "MM/dd/yyyy", "yyyy/M/d", "yyyy/MM/dd", "yyyy-MM-dd", "dd/MM/yyyy"
    ]
    static let shortTimePatterns = ["H:mm", "HH:mm", "h:mm a", "hh:mm a"]
    static let longTimePatterns = ["H:mm:ss", "HH:mm:ss", "h:mm:ss a", "hh:mm:ss a"]

    static let exampleDate: Date = {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2017
        components.month = 4
        components.day = 5
        components.hour = 14
        components.minute = 40
        components.second = 7
        return components.date!
    }()

    static func validated(_ pattern: String?, allowed: [String], fallback: String) -> String {
        guard let pattern, allowed.contains(pattern) else { return fallback }
        return pattern
    }
}

enum DateTimeFormatter {
    private struct Key: Hashable {
        let pattern: String
        let calendar: Calendar.Identifier
        let timeZone: TimeZone
        let amSymbol: String
        let pmSymbol: String
    }

    // The lock protects both the cache and all use of its mutable formatters.
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var formatters: [Key: Foundation.DateFormatter] = [:]

        func string(from date: Date, key: Key) -> String {
            lock.lock()
            defer { lock.unlock() }
            let formatter: Foundation.DateFormatter
            if let cached = formatters[key] {
                formatter = cached
            } else {
                formatter = Foundation.DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar(identifier: key.calendar)
                formatter.timeZone = key.timeZone
                formatter.amSymbol = key.amSymbol
                formatter.pmSymbol = key.pmSymbol
                formatter.dateFormat = key.pattern
                if formatters.count >= 64 { formatters.removeAll(keepingCapacity: true) }
                formatters[key] = formatter
            }
            return formatter.string(from: date)
        }
    }

    private static let cache = Cache()

    static func string(
        from date: Date,
        pattern: String,
        configuration: DateTimeFormatConfiguration,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        cache.string(from: date, key: Key(
            pattern: pattern,
            calendar: configuration.calendarKind.identifier,
            timeZone: TimeZone(identifier: timeZone.identifier) ?? timeZone,
            amSymbol: configuration.amSymbol,
            pmSymbol: configuration.pmSymbol
        ))
    }

    static func longDateString(
        from date: Date,
        configuration: DateTimeFormatConfiguration,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        let dateText = string(
            from: date,
            pattern: configuration.longDatePattern,
            configuration: configuration,
            timeZone: timeZone
        )
        guard configuration.longDateIncludesLunar else { return dateText }
        let lunar = ClockCalendarLunarCalendar.lunarDate(for: date, timeZone: timeZone)
        return "\(dateText)  \(lunar.fullLabel)"
    }
}

struct AdditionalClockConfiguration: Codable, Equatable, Identifiable {
    let slot: Int
    var isEnabled: Bool
    var timeZoneIdentifier: String
    var displayName: String

    var id: Int { slot }

    static let defaults = [
        AdditionalClockConfiguration(slot: 1, isEnabled: false, timeZoneIdentifier: "America/Chicago", displayName: ""),
        AdditionalClockConfiguration(slot: 2, isEnabled: false, timeZoneIdentifier: "Europe/London", displayName: "")
    ]
}

enum AdditionalClockPresentation {
    enum RelativeDay: Equatable {
        case yesterday
        case tomorrow

        var localizedLabel: String {
            switch self {
            case .yesterday: NSLocalizedString("Yesterday", comment: "Additional clock relative day")
            case .tomorrow: NSLocalizedString("Tomorrow", comment: "Additional clock relative day")
            }
        }
    }

    static func timeZoneLabel(identifier: String, date: Date = Date()) -> String {
        guard let timeZone = TimeZone(identifier: identifier) else { return identifier }
        let seconds = timeZone.secondsFromGMT(for: date)
        let sign = seconds < 0 ? "-" : "+"
        let absoluteSeconds = abs(seconds)
        let hours = absoluteSeconds / 3_600
        let minutes = (absoluteSeconds % 3_600) / 60
        let name = timeZone.localizedName(for: .generic, locale: .autoupdatingCurrent) ?? identifier
        return String(format: "(UTC%@%02d:%02d) %@", sign, hours, minutes, name)
    }

    static func relativeDay(
        for date: Date,
        targetTimeZone: TimeZone,
        localTimeZone: TimeZone = .autoupdatingCurrent
    ) -> RelativeDay? {
        let localDay = dayIndex(for: date, timeZone: localTimeZone)
        let targetDay = dayIndex(for: date, timeZone: targetTimeZone)
        switch targetDay - localDay {
        case -1: return .yesterday
        case 0: return nil
        case 1: return .tomorrow
        default: return nil
        }
    }

    private static func dayIndex(for date: Date, timeZone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let normalized = utcCalendar.date(from: components) ?? date
        return Int(normalized.timeIntervalSince1970 / 86_400)
    }
}
