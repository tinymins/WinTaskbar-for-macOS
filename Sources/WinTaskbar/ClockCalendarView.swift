import AppKit
import SwiftUI

enum ClockCalendarMetrics {
    static let width: CGFloat = 336
    static let expandedHeight: CGFloat = 532
    static let collapsedHeight: CGFloat = 181
    static let headerHeight: CGFloat = 128
    static let calendarHeight: CGFloat = 350
    static let focusHeight: CGFloat = 52
}

struct ClockCalendarDay: Equatable, Identifiable {
    let date: Date
    let day: Int
    let isInDisplayedMonth: Bool

    var id: Date { date }
}

struct ClockCalendarLunarDate: Equatable {
    let month: Int
    let day: Int
    let isLeapMonth: Bool

    var compactLabel: String {
        guard day == 1 else { return Self.dayNames[day - 1] }
        return "\(isLeapMonth ? "闰" : "")\(Self.monthNames[month - 1])月"
    }

    var fullLabel: String {
        "农历\(isLeapMonth ? "闰" : "")\(Self.monthNames[month - 1])月\(Self.dayNames[day - 1])"
    }

    private static let monthNames = ["正", "二", "三", "四", "五", "六", "七", "八", "九", "十", "冬", "腊"]
    private static let dayNames = [
        "初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
        "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
        "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十"
    ]
}

enum ClockCalendarLunarCalendar {
    static func lunarDate(for date: Date, timeZone: TimeZone = .autoupdatingCurrent) -> ClockCalendarLunarDate {
        var calendar = Calendar(identifier: .chinese)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.month, .day], from: date)
        return ClockCalendarLunarDate(
            month: components.month ?? 1,
            day: components.day ?? 1,
            isLeapMonth: components.isLeapMonth ?? false
        )
    }
}

enum ClockCalendarGrid {
    static func days(displayedMonth: Date, calendar: Calendar) -> [ClockCalendarDay] {
        guard let gridStart = startDate(displayedMonth: displayedMonth, calendar: calendar) else { return [] }
        return days(startingAt: gridStart, displayedMonth: displayedMonth, calendar: calendar)
    }

    static func startDate(displayedMonth: Date, calendar: Calendar) -> Date? {
        guard let monthInterval = calendar.dateInterval(of: .month, for: displayedMonth) else { return nil }
        let startOfMonth = monthInterval.start
        let weekday = calendar.component(.weekday, from: startOfMonth)
        let leadingDays = (weekday - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -leadingDays, to: startOfMonth)
    }

    static func days(startingAt gridStart: Date, displayedMonth: Date, calendar: Calendar) -> [ClockCalendarDay] {
        return (0..<42).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: gridStart) else { return nil }
            return ClockCalendarDay(
                date: date,
                day: calendar.component(.day, from: date),
                isInDisplayedMonth: calendar.isDate(date, equalTo: displayedMonth, toGranularity: .month)
            )
        }
    }

    static func weekdaySymbols(calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let startIndex = max(0, min(symbols.count - 1, calendar.firstWeekday - 1))
        return Array(symbols[startIndex...] + symbols[..<startIndex])
    }
}

@MainActor
final class ClockCalendarState: ObservableObject {
    @Published var displayedMonth: Date
    @Published var selectedDate: Date
    @Published private(set) var visibleStartDate: Date
    @Published private(set) var gridRevision = 0
    @Published private(set) var scrollDirection = 1
    @Published var isExpanded = true
    @Published private(set) var focusRemainingSeconds = 0
    @Published private(set) var isFocusing = false
    @Published var focusMinutes = 30

    private var focusEndDate: Date?
    private var focusTimer: Timer?

    init(now: Date = Date()) {
        let calendar = Self.calendar
        let month = calendar.dateInterval(of: .month, for: now)?.start ?? now
        displayedMonth = month
        selectedDate = now
        visibleStartDate = ClockCalendarGrid.startDate(displayedMonth: month, calendar: calendar) ?? month
    }

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .autoupdatingCurrent
        calendar.timeZone = .autoupdatingCurrent
        calendar.firstWeekday = Calendar.autoupdatingCurrent.firstWeekday
        return calendar
    }

    var days: [ClockCalendarDay] {
        ClockCalendarGrid.days(
            startingAt: visibleStartDate,
            displayedMonth: displayedMonth,
            calendar: Self.calendar
        )
    }

    var weekdaySymbols: [String] {
        ClockCalendarGrid.weekdaySymbols(calendar: Self.calendar)
    }

    func moveMonth(by offset: Int) {
        guard let month = Self.calendar.date(byAdding: .month, value: offset, to: displayedMonth) else { return }
        showMonth(month, direction: offset)
    }

    func scrollWeeks(by offset: Int) {
        guard offset != 0,
              let startDate = Self.calendar.date(byAdding: .day, value: offset * 7, to: visibleStartDate),
              let referenceDate = Self.calendar.date(byAdding: .day, value: 7, to: startDate),
              let month = Self.calendar.dateInterval(of: .month, for: referenceDate)?.start else { return }
        visibleStartDate = startDate
        displayedMonth = month
        scrollDirection = offset
        gridRevision &+= 1
    }

    func select(_ date: Date) {
        selectedDate = date
        if !Self.calendar.isDate(date, equalTo: displayedMonth, toGranularity: .month),
           let month = Self.calendar.dateInterval(of: .month, for: date)?.start {
            showMonth(month, direction: date < displayedMonth ? -1 : 1)
        }
    }

    private func showMonth(_ month: Date, direction: Int) {
        displayedMonth = month
        visibleStartDate = ClockCalendarGrid.startDate(displayedMonth: month, calendar: Self.calendar) ?? month
        scrollDirection = direction
        gridRevision &+= 1
    }

    func adjustFocusMinutes(by offset: Int) {
        guard !isFocusing else { return }
        focusMinutes = min(240, max(5, focusMinutes + offset))
    }

    func toggleFocus() {
        if isFocusing {
            stopFocus()
            return
        }

        isFocusing = true
        focusRemainingSeconds = focusMinutes * 60
        focusEndDate = Date().addingTimeInterval(TimeInterval(focusRemainingSeconds))
        focusTimer?.invalidate()
        focusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshFocus() }
        }
    }

    private func refreshFocus() {
        guard let focusEndDate else { return }
        focusRemainingSeconds = max(0, Int(ceil(focusEndDate.timeIntervalSinceNow)))
        if focusRemainingSeconds == 0 { stopFocus() }
    }

    private func stopFocus() {
        focusTimer?.invalidate()
        focusTimer = nil
        focusEndDate = nil
        focusRemainingSeconds = 0
        isFocusing = false
    }
}

struct ClockCalendarPanelView: View {
    @ObservedObject var state: ClockCalendarState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            clockHeader
                .frame(height: ClockCalendarMetrics.headerHeight)

            if state.isExpanded {
                Divider().overlay(dividerColor)
                calendarBody
                    .frame(height: ClockCalendarMetrics.calendarHeight)
            }

            Divider().overlay(dividerColor)
            focusFooter
                .frame(height: ClockCalendarMetrics.focusHeight)
        }
        .frame(
            width: ClockCalendarMetrics.width,
            height: state.isExpanded ? ClockCalendarMetrics.expandedHeight : ClockCalendarMetrics.collapsedHeight
        )
        .background(panelFill)
        .foregroundStyle(primaryText)
        .clipped()
    }

    private var clockHeader: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center) {
                    Text(context.date, format: .dateTime.hour().minute().second())
                        .font(.system(size: 28, weight: .semibold))
                        .monospacedDigit()
                        .accessibilityLabel(context.date.formatted(date: .omitted, time: .complete))
                    Spacer()
                    Button { state.isExpanded.toggle() } label: {
                        Image(systemName: state.isExpanded ? "chevron.down" : "chevron.up")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(ClockCalendarControlButtonStyle())
                    .help(state.isExpanded ? "Collapse calendar" : "Expand calendar")
                    .accessibilityLabel(state.isExpanded ? "Collapse calendar" : "Expand calendar")
                }

                Text(context.date, format: .dateTime.weekday(.wide).month(.wide).day())
                    .font(.system(size: 14))
                    .foregroundStyle(secondaryText)

                HStack(spacing: 12) {
                    Text(timeZoneName)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(context.date.formatted(date: .omitted, time: .shortened)) Today")
                        .monospacedDigit()
                }
                .font(.system(size: 14))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    private var calendarBody: some View {
        VStack(spacing: 0) {
            HStack {
                Text(monthTitle)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                HStack(spacing: 8) {
                    monthButton(systemName: "chevron.up", offset: -1, label: "Previous month")
                    monthButton(systemName: "chevron.down", offset: 1, label: "Next month")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 50)

            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(Array(state.weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 28)

            ZStack {
                ClockCalendarDaysGrid(days: state.days, state: state, columns: columns)
                    .id(state.gridRevision)
                    .transition(calendarGridTransition)
            }
            .frame(height: 252)
            .clipped()

            Spacer(minLength: 0)
        }
    }

    private var focusFooter: some View {
        HStack(spacing: 12) {
            focusAdjustmentButton(systemName: "minus", offset: -5, label: "Reduce focus duration")
            Text("\(state.focusMinutes) mins")
                .font(.system(size: 14, weight: .semibold))
                .frame(minWidth: 57)
            focusAdjustmentButton(systemName: "plus", offset: 5, label: "Increase focus duration")
            Spacer()
            Button { state.toggleFocus() } label: {
                HStack(spacing: 6) {
                    Image(systemName: state.isFocusing ? "stop.fill" : "play.fill")
                        .font(.system(size: 10))
                    Text(state.isFocusing ? focusRemainingText : "Focus")
                        .monospacedDigit()
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .frame(height: 28)
            }
            .buttonStyle(ClockCalendarFocusButtonStyle())
            .accessibilityLabel(state.isFocusing ? "Stop focus session" : "Start focus session")
        }
        .padding(.horizontal, 16)
    }

    private func monthButton(systemName: String, offset: Int, label: String) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { state.moveMonth(by: offset) }
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(ClockCalendarControlButtonStyle())
        .foregroundStyle(secondaryText)
        .help(label)
        .accessibilityLabel(label)
    }

    private func focusAdjustmentButton(systemName: String, offset: Int, label: String) -> some View {
        Button { state.adjustFocusMinutes(by: offset) } label: {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(ClockCalendarControlButtonStyle())
        .disabled(state.isFocusing)
        .help(label)
        .accessibilityLabel(label)
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
    }

    private var calendarGridTransition: AnyTransition {
        let distance = CGFloat(state.scrollDirection) * 42
        return .asymmetric(
            insertion: .modifier(
                active: ClockCalendarGridOffset(y: distance),
                identity: ClockCalendarGridOffset(y: 0)
            ),
            removal: .modifier(
                active: ClockCalendarGridOffset(y: -distance),
                identity: ClockCalendarGridOffset(y: 0)
            )
        )
    }

    private var monthTitle: String {
        state.displayedMonth.formatted(.dateTime.month(.wide).year())
    }

    private var timeZoneName: String {
        TimeZone.autoupdatingCurrent.localizedName(for: .generic, locale: .autoupdatingCurrent)
            ?? TimeZone.autoupdatingCurrent.identifier
    }

    private var focusRemainingText: String {
        let minutes = state.focusRemainingSeconds / 60
        let seconds = state.focusRemainingSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var panelFill: Color {
        colorScheme == .dark
            ? Color(red: 0.09, green: 0.09, blue: 0.09).opacity(0.84)
            : Color(red: 0.96, green: 0.96, blue: 0.96).opacity(0.86)
    }

    private var primaryText: Color { colorScheme == .dark ? .white.opacity(0.96) : .black.opacity(0.90) }
    private var secondaryText: Color { colorScheme == .dark ? .white.opacity(0.74) : .black.opacity(0.68) }
    private var dividerColor: Color { colorScheme == .dark ? .white.opacity(0.08) : .black.opacity(0.08) }
}

private struct ClockCalendarDaysGrid: View {
    let days: [ClockCalendarDay]
    @ObservedObject var state: ClockCalendarState
    let columns: [GridItem]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 0) {
            ForEach(days) { day in
                ClockCalendarDayButton(day: day, state: state)
                    .frame(height: 42)
            }
        }
        .padding(.horizontal, 16)
    }
}

private struct ClockCalendarGridOffset: ViewModifier {
    let y: CGFloat

    func body(content: Content) -> some View {
        content.offset(y: y)
    }
}

private struct ClockCalendarDayButton: View {
    let day: ClockCalendarDay
    @ObservedObject var state: ClockCalendarState
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    var body: some View {
        Button { state.select(day.date) } label: {
            VStack(spacing: -1) {
                Text("\(day.day)")
                    .font(.system(size: 14))
                Text(lunarDate.compactLabel)
                    .font(.system(size: 9))
                    .opacity(0.78)
            }
                .foregroundStyle(foregroundColor)
                .frame(width: 40, height: 40)
                .background(background)
                .overlay(selectionBorder)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(day.date.formatted(date: .complete, time: .omitted)), \(lunarDate.fullLabel)")
    }

    private var lunarDate: ClockCalendarLunarDate {
        ClockCalendarLunarCalendar.lunarDate(for: day.date)
    }

    private var isToday: Bool {
        ClockCalendarState.calendar.isDateInToday(day.date)
    }

    private var isSelected: Bool {
        ClockCalendarState.calendar.isDate(day.date, inSameDayAs: state.selectedDate)
    }

    private var foregroundColor: Color {
        if isToday { return .white }
        if !day.isInDisplayedMonth {
            return colorScheme == .dark ? .white.opacity(0.36) : .black.opacity(0.36)
        }
        return colorScheme == .dark ? .white.opacity(0.92) : .black.opacity(0.88)
    }

    @ViewBuilder
    private var background: some View {
        if isToday {
            Color.win11Accent
        } else if hovering {
            (colorScheme == .dark ? Color.white : Color.black).opacity(0.09)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private var selectionBorder: some View {
        if isSelected, !isToday {
            Circle().stroke(Color.win11Accent, lineWidth: 1.5).padding(2)
        }
    }
}

private struct ClockCalendarControlButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill((colorScheme == .dark ? Color.white : Color.black).opacity(configuration.isPressed ? 0.16 : 0.08))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke((colorScheme == .dark ? Color.white : Color.black).opacity(0.10), lineWidth: 0.5)
            }
    }
}

private struct ClockCalendarFocusButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill((colorScheme == .dark ? Color.white : Color.black).opacity(configuration.isPressed ? 0.18 : 0.10))
            )
    }
}

private extension Color {
    static let win11Accent = Color(red: 0.24, green: 0.74, blue: 0.98)
}
