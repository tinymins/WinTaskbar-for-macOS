import Foundation

struct ClockCalendarDateKey: Hashable, Sendable {
    let year: Int
    let month: Int
    let day: Int

    init(date: Date, calendar: Calendar) {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        year = components.year ?? 0
        month = components.month ?? 0
        day = components.day ?? 0
    }

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }
}

enum ClockCalendarWorkState: Equatable, Sendable {
    case holiday(name: String)
    case makeupWorkday(name: String)
}

enum ClockCalendarSecondaryLabelKind: Equatable, Sendable {
    case lunar
    case festival
    case solarTerm
}

struct ClockCalendarAnnotation: Equatable, Sendable {
    let secondaryLabel: String
    let secondaryLabelKind: ClockCalendarSecondaryLabelKind
    let workState: ClockCalendarWorkState?
    let isWeekend: Bool

    var isRestDay: Bool {
        switch workState {
        case .holiday:
            true
        case .makeupWorkday:
            false
        case nil:
            isWeekend
        }
    }
}

enum ClockCalendarAnnotationStore {
    static func annotation(
        for date: Date,
        lunarDate: ClockCalendarLunarDate,
        calendar: Calendar
    ) -> ClockCalendarAnnotation {
        let key = ClockCalendarDateKey(date: date, calendar: calendar)
        let workState = chinaWorkStates[key]
        let festival = lunarFestival(for: date, lunarDate: lunarDate, calendar: calendar)
            ?? gregorianFestivals[key.month]?[key.day]
        let solarTerm = ChineseSolarTerms.name(year: key.year, month: key.month, day: key.day)
        let weekday = calendar.component(.weekday, from: date)

        if let festival {
            return ClockCalendarAnnotation(
                secondaryLabel: festival,
                secondaryLabelKind: .festival,
                workState: workState,
                isWeekend: weekday == 1 || weekday == 7
            )
        }
        if let solarTerm {
            return ClockCalendarAnnotation(
                secondaryLabel: solarTerm,
                secondaryLabelKind: .solarTerm,
                workState: workState,
                isWeekend: weekday == 1 || weekday == 7
            )
        }
        return ClockCalendarAnnotation(
            secondaryLabel: lunarDate.compactLabel,
            secondaryLabelKind: .lunar,
            workState: workState,
            isWeekend: weekday == 1 || weekday == 7
        )
    }

    private static func lunarFestival(
        for date: Date,
        lunarDate: ClockCalendarLunarDate,
        calendar: Calendar
    ) -> String? {
        if lunarDate.month == 12,
           let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) {
            let tomorrowLunar = ClockCalendarLunarCalendar.lunarDate(for: tomorrow, timeZone: calendar.timeZone)
            if tomorrowLunar.month == 1, tomorrowLunar.day == 1 {
                return "除夕"
            }
        }

        guard !lunarDate.isLeapMonth else { return nil }

        return lunarFestivals[lunarDate.month]?[lunarDate.day]
    }

    private static let lunarFestivals: [Int: [Int: String]] = [
        1: [1: "春节", 15: "元宵节"],
        2: [2: "龙抬头"],
        5: [5: "端午节"],
        7: [7: "七夕节", 15: "中元节"],
        8: [15: "中秋节"],
        9: [9: "重阳节"],
        12: [8: "腊八节", 23: "小年"]
    ]

    private static let gregorianFestivals: [Int: [Int: String]] = [
        1: [1: "元旦"],
        2: [14: "情人节"],
        3: [8: "妇女节", 12: "植树节"],
        4: [1: "愚人节"],
        5: [1: "劳动节", 4: "青年节"],
        6: [1: "儿童节"],
        7: [1: "建党节"],
        8: [1: "建军节"],
        9: [10: "教师节"],
        10: [1: "国庆节"],
        12: [24: "平安夜", 25: "圣诞节"]
    ]

    // State Council 2026 holiday notice, 国办发明电〔2025〕7号:
    // https://www.gov.cn/zhengce/zhengceku/202511/content_7047091.htm
    private static let chinaWorkStates: [ClockCalendarDateKey: ClockCalendarWorkState] = {
        var states: [ClockCalendarDateKey: ClockCalendarWorkState] = [:]

        func addHoliday(_ name: String, month: Int, days: ClosedRange<Int>) {
            for day in days {
                states[ClockCalendarDateKey(year: 2026, month: month, day: day)] = .holiday(name: name)
            }
        }

        func addHoliday(_ name: String, dates: [(Int, Int)]) {
            for (month, day) in dates {
                states[ClockCalendarDateKey(year: 2026, month: month, day: day)] = .holiday(name: name)
            }
        }

        func addWorkday(_ name: String, month: Int, day: Int) {
            states[ClockCalendarDateKey(year: 2026, month: month, day: day)] = .makeupWorkday(name: name)
        }

        addHoliday("元旦", month: 1, days: 1...3)
        addWorkday("元旦", month: 1, day: 4)

        addHoliday("春节", month: 2, days: 15...23)
        addWorkday("春节", month: 2, day: 14)
        addWorkday("春节", month: 2, day: 28)

        addHoliday("清明节", month: 4, days: 4...6)

        addHoliday("劳动节", month: 5, days: 1...5)
        addWorkday("劳动节", month: 5, day: 9)

        addHoliday("端午节", month: 6, days: 19...21)
        addHoliday("中秋节", month: 9, days: 25...27)

        addHoliday("国庆节", dates: [(10, 1), (10, 2), (10, 3), (10, 4), (10, 5), (10, 6), (10, 7)])
        addWorkday("国庆节", month: 9, day: 20)
        addWorkday("国庆节", month: 10, day: 10)

        return states
    }()
}

private enum ChineseSolarTerms {
    private static let names = [
        "小寒", "大寒", "立春", "雨水", "惊蛰", "春分", "清明", "谷雨",
        "立夏", "小满", "芒种", "夏至", "小暑", "大暑", "立秋", "处暑",
        "白露", "秋分", "寒露", "霜降", "立冬", "小雪", "大雪", "冬至"
    ]

    private static let minuteOffsets = [
        0, 21_208, 42_467, 63_836, 85_337, 107_014, 128_867, 150_921,
        173_149, 195_551, 218_072, 240_693, 263_343, 285_989, 308_563, 331_033,
        353_350, 375_494, 397_447, 419_210, 440_795, 462_224, 483_532, 504_758
    ]

    private static let referenceDate: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar.date(from: DateComponents(
            year: 1900,
            month: 1,
            day: 6,
            hour: 2,
            minute: 5
        )) ?? Date(timeIntervalSince1970: -2_208_988_500)
    }()

    private static let chinaCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .autoupdatingCurrent
        return calendar
    }()

    // The compact solar model is within minutes of the precise instant. These
    // terms occur close enough to midnight that the small error changes the day.
    // Keys encode year * 100 + the zero-based solar-term index.
    private static let boundaryDayCorrections: [Int: Int] = [
        201_404: 1,
        201_612: 1,
        204_512: 1,
        204_704: 1,
        205_105: -1,
        208_201: 1,
        209_708: 1
    ]

    private static let dates: [ClockCalendarDateKey: String] = {
        var result: [ClockCalendarDateKey: String] = [:]
        for year in 1971...2099 {
            for index in names.indices {
                var date = calculatedDate(year: year, termIndex: index)
                let correctionKey = year * 100 + index
                if let correction = boundaryDayCorrections[correctionKey] {
                    date = date.addingTimeInterval(TimeInterval(correction * 86_400))
                }
                result[ClockCalendarDateKey(date: date, calendar: chinaCalendar)] = names[index]
            }
        }
        return result
    }()

    static func name(year: Int, month: Int, day: Int) -> String? {
        dates[ClockCalendarDateKey(year: year, month: month, day: day)]
    }

    private static func calculatedDate(year: Int, termIndex: Int) -> Date {
        let approximateSeconds = 31_556_925.9747 * Double(year - 1900)
            + Double(minuteOffsets[termIndex] * 60)
        let approximateDate = referenceDate.addingTimeInterval(approximateSeconds)
        var julianDay = approximateDate.timeIntervalSince1970 / 86_400 + 2_440_587.5
        let targetLongitude = normalizedDegrees(285 + Double(termIndex * 15))

        for _ in 0..<8 {
            let difference = angularDifference(
                solarApparentLongitude(julianDay: julianDay),
                targetLongitude
            )
            julianDay -= difference / 0.985_647_36
        }
        return Date(timeIntervalSince1970: (julianDay - 2_440_587.5) * 86_400)
    }

    private static func solarApparentLongitude(julianDay: Double) -> Double {
        let centuries = (julianDay - 2_451_545.0) / 36_525
        let meanLongitude = normalizedDegrees(
            280.46646 + 36_000.76983 * centuries + 0.0003032 * centuries * centuries
        )
        let meanAnomaly = degreesToRadians(
            357.52911 + 35_999.05029 * centuries
                - 0.0001537 * centuries * centuries
                + 0.00000048 * centuries * centuries * centuries
        )
        let equationOfCenter = (
            1.914602 - 0.004817 * centuries - 0.000014 * centuries * centuries
        ) * sin(meanAnomaly)
            + (0.019993 - 0.000101 * centuries) * sin(2 * meanAnomaly)
            + 0.000289 * sin(3 * meanAnomaly)
        let omega = degreesToRadians(125.04 - 1_934.136 * centuries)
        return normalizedDegrees(meanLongitude + equationOfCenter - 0.00569 - 0.00478 * sin(omega))
    }

    private static func angularDifference(_ lhs: Double, _ rhs: Double) -> Double {
        var difference = normalizedDegrees(lhs - rhs)
        if difference > 180 { difference -= 360 }
        return difference
    }

    private static func normalizedDegrees(_ degrees: Double) -> Double {
        let remainder = degrees.truncatingRemainder(dividingBy: 360)
        return remainder >= 0 ? remainder : remainder + 360
    }

    private static func degreesToRadians(_ degrees: Double) -> Double {
        degrees * .pi / 180
    }
}
