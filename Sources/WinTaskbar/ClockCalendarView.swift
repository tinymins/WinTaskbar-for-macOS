import AppKit
import SwiftUI

enum ClockCalendarMetrics {
    static let width: CGFloat = 336
    static let expandedHeight: CGFloat = 690
    static let collapsedHeight: CGFloat = 181
    static let headerHeight: CGFloat = 128
    static let calendarHeight: CGFloat = 508
    static let calendarGridBottomSpacing: CGFloat = 8
    static let agendaTopSpacing: CGFloat = 4
    static let agendaHeight: CGFloat = 178 - calendarGridBottomSpacing
    static let focusHeight: CGFloat = 52
}

struct ClockCalendarDay: Equatable, Identifiable {
    let date: Date
    let dateKey: ClockCalendarDateKey
    let day: Int
    let isInDisplayedMonth: Bool
    let lunarDate: ClockCalendarLunarDate
    let annotation: ClockCalendarAnnotation

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

    static func days(
        startingAt gridStart: Date,
        displayedMonth: Date,
        calendar: Calendar,
        count: Int = 42
    ) -> [ClockCalendarDay] {
        return (0..<count).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: gridStart) else { return nil }
            let lunarDate = ClockCalendarLunarCalendar.lunarDate(for: date, timeZone: calendar.timeZone)
            return ClockCalendarDay(
                date: date,
                dateKey: ClockCalendarDateKey(date: date, calendar: calendar),
                day: calendar.component(.day, from: date),
                isInDisplayedMonth: calendar.isDate(date, equalTo: displayedMonth, toGranularity: .month),
                lunarDate: lunarDate,
                annotation: ClockCalendarAnnotationStore.annotation(
                    for: date,
                    lunarDate: lunarDate,
                    calendar: calendar
                )
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
    @Published private(set) var renderedStartDate: Date
    @Published private(set) var renderedDays: [ClockCalendarDay]
    @Published private(set) var gridOffset: CGFloat
    @Published var isExpanded = true
    @Published private(set) var focusRemainingSeconds = 0
    @Published private(set) var isFocusing = false
    @Published var focusMinutes = 30
    @Published var isEditingCalendarEvent = false

    private var focusEndDate: Date?
    private var focusTimer: Timer?
    private var scrollSettlingTask: Task<Void, Never>?
    private var wheelScrollTask: Task<Void, Never>?
    private var wheelTargetDistance: CGFloat = 0

    init(now: Date = Date()) {
        let calendar = Self.calendar
        let month = calendar.dateInterval(of: .month, for: now)?.start ?? now
        displayedMonth = month
        selectedDate = now
        let startDate = ClockCalendarGrid.startDate(displayedMonth: month, calendar: calendar) ?? month
        visibleStartDate = startDate
        let renderedStartDate = calendar.date(byAdding: .day, value: -7, to: startDate) ?? startDate
        self.renderedStartDate = renderedStartDate
        renderedDays = ClockCalendarGrid.days(
            startingAt: renderedStartDate,
            displayedMonth: month,
            calendar: calendar,
            count: 56
        )
        gridOffset = -42
    }

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .autoupdatingCurrent
        calendar.timeZone = .autoupdatingCurrent
        calendar.firstWeekday = Calendar.autoupdatingCurrent.firstWeekday
        return calendar
    }

    var weekdaySymbols: [String] {
        ClockCalendarGrid.weekdaySymbols(calendar: Self.calendar)
    }

    var eventQueryInterval: DateInterval {
        let endDate = Self.calendar.date(byAdding: .day, value: 56, to: renderedStartDate)
            ?? renderedStartDate.addingTimeInterval(56 * 86_400)
        return DateInterval(start: renderedStartDate, end: endDate)
    }

    func moveMonth(by offset: Int) {
        guard let month = Self.calendar.date(byAdding: .month, value: offset, to: displayedMonth) else { return }
        showMonth(month)
    }

    func resetToToday(now: Date = Date()) {
        cancelWheelScrolling()
        cancelCalendarScrollSettling()
        isEditingCalendarEvent = false
        let calendar = Self.calendar
        let month = calendar.dateInterval(of: .month, for: now)?.start ?? now
        displayedMonth = month
        selectedDate = now
        visibleStartDate = ClockCalendarGrid.startDate(displayedMonth: month, calendar: calendar) ?? month
        resetRenderedWindow()
    }

    func scrollWeeks(by offset: Int) {
        guard offset != 0,
              let startDate = shiftedStartDate(by: offset) else { return }
        cancelWheelScrolling()
        cancelCalendarScrollSettling()
        updateVisibleStartDate(startDate)
        resetRenderedWindow()
    }

    func scrollCalendar(by deltaY: CGFloat) {
        guard deltaY != 0 else { return }
        cancelWheelScrolling()
        cancelCalendarScrollSettling()
        applyScrollDelta(deltaY)
    }

    func scrollCalendarByWheel(direction: Int) {
        guard direction != 0 else { return }
        cancelCalendarScrollSettling()
        wheelTargetDistance += CGFloat(direction > 0 ? 42 : -42)
        guard wheelScrollTask == nil else { return }
        wheelScrollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while abs(self.wheelTargetDistance) >= 0.5 {
                let remaining = self.wheelTargetDistance
                let magnitude = min(abs(remaining), min(24, max(4, abs(remaining) * 0.38)))
                let step = remaining > 0 ? magnitude : -magnitude
                self.applyScrollDelta(step)
                self.wheelTargetDistance -= step
                do {
                    try await Task.sleep(nanoseconds: 8_000_000)
                } catch {
                    return
                }
            }
            self.wheelTargetDistance = 0
            self.wheelScrollTask = nil
            self.scheduleCalendarScrollSettling()
        }
    }

    private func applyScrollDelta(_ deltaY: CGFloat) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            gridOffset += deltaY
            while gridOffset <= -84 {
                recycleRenderedWeek(direction: 1)
                gridOffset += 42
            }
            while gridOffset >= 0 {
                recycleRenderedWeek(direction: -1)
                gridOffset -= 42
            }
        }
    }

    func scheduleCalendarScrollSettling() {
        scrollSettlingTask?.cancel()
        scrollSettlingTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 80_000_000)
            } catch {
                return
            }
            await self?.settleCalendarScroll()
        }
    }

    func select(_ date: Date) {
        selectedDate = date
    }

    private func showMonth(_ month: Date) {
        cancelWheelScrolling()
        cancelCalendarScrollSettling()
        displayedMonth = month
        let startDate = ClockCalendarGrid.startDate(displayedMonth: month, calendar: Self.calendar) ?? month
        visibleStartDate = startDate
        resetRenderedWindow()
    }

    private func settleCalendarScroll() async {
        let displacement = gridOffset + 42
        let direction = displacement <= -21 ? 1 : (displacement >= 21 ? -1 : 0)
        let targetOffset = direction > 0 ? CGFloat(-84) : (direction < 0 ? CGFloat(0) : CGFloat(-42))
        withAnimation(.easeOut(duration: 0.10)) {
            gridOffset = targetOffset
        }
        guard direction != 0 else { return }

        do {
            try await Task.sleep(nanoseconds: 100_000_000)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            recycleRenderedWeek(direction: direction)
            gridOffset = -42
        }
    }

    private func shiftedStartDate(by weekOffset: Int) -> Date? {
        Self.calendar.date(byAdding: .day, value: weekOffset * 7, to: visibleStartDate)
    }

    private func updateVisibleStartDate(_ startDate: Date) {
        guard let referenceDate = Self.calendar.date(byAdding: .day, value: 7, to: startDate),
              let month = Self.calendar.dateInterval(of: .month, for: referenceDate)?.start else { return }
        visibleStartDate = startDate
        displayedMonth = month
    }

    private func recycleRenderedWeek(direction: Int) {
        guard let startDate = shiftedStartDate(by: direction),
              let renderedStartDate = Self.calendar.date(byAdding: .day, value: -7, to: startDate) else { return }
        updateVisibleStartDate(startDate)
        self.renderedStartDate = renderedStartDate
        updateRenderedDays()
    }

    private func resetRenderedWindow() {
        renderedStartDate = Self.calendar.date(byAdding: .day, value: -7, to: visibleStartDate) ?? visibleStartDate
        updateRenderedDays()
        gridOffset = -42
    }

    private func updateRenderedDays() {
        renderedDays = ClockCalendarGrid.days(
            startingAt: renderedStartDate,
            displayedMonth: displayedMonth,
            calendar: Self.calendar,
            count: 56
        )
    }

    private func cancelCalendarScrollSettling() {
        scrollSettlingTask?.cancel()
        scrollSettlingTask = nil
    }

    private func cancelWheelScrolling() {
        wheelScrollTask?.cancel()
        wheelScrollTask = nil
        wheelTargetDistance = 0
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
    @ObservedObject var calendarService: SystemCalendarService
    @Environment(\.colorScheme) private var colorScheme
    @State private var eventDraft: SystemCalendarEventDraft?
    @State private var calendarErrorMessage: String?

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                clockHeader
                    .frame(height: ClockCalendarMetrics.headerHeight)

                if state.isExpanded {
                    sectionDivider
                    calendarBody
                        .frame(height: ClockCalendarMetrics.calendarHeight)
                }

                sectionDivider
                focusFooter
                    .frame(height: ClockCalendarMetrics.focusHeight)
            }
            .allowsHitTesting(eventDraft == nil)
            .accessibilityHidden(eventDraft != nil)

            if let eventDraft {
                CalendarEventEditorView(
                    initialDraft: eventDraft,
                    calendars: calendarService.writableCalendars,
                    onCancel: dismissEventEditor,
                    onSave: saveEvent,
                    onDelete: deleteEvent
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .frame(
            width: ClockCalendarMetrics.width,
            height: state.isExpanded ? ClockCalendarMetrics.expandedHeight : ClockCalendarMetrics.collapsedHeight
        )
        .background(panelFill)
        .foregroundStyle(primaryText)
        .clipped()
        .onChange(of: state.visibleStartDate) { _ in loadVisibleEvents() }
        .onChange(of: state.isEditingCalendarEvent) { isEditing in
            if !isEditing, eventDraft != nil { eventDraft = nil }
        }
        .onChange(of: calendarService.errorMessage) { message in
            if let message { calendarErrorMessage = message }
        }
        .alert("Calendar", isPresented: Binding(
            get: { calendarErrorMessage != nil },
            set: { if !$0 { calendarErrorMessage = nil; calendarService.clearError() } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(calendarErrorMessage ?? "")
        }
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

            ZStack(alignment: .top) {
                ClockCalendarDaysGrid(
                    days: state.renderedDays,
                    selectedDate: state.selectedDate,
                    eventsByDay: calendarService.eventsByDay,
                    columns: columns,
                    onSelect: state.select
                )
                    .offset(y: state.gridOffset)
            }
            .frame(height: 252, alignment: .top)
            .clipped()
            .padding(.bottom, ClockCalendarMetrics.calendarGridBottomSpacing)

            sectionDivider
            agendaSection
                .frame(height: ClockCalendarMetrics.agendaHeight)
        }
    }

    private var agendaSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.selectedDate, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                        .font(.system(size: 13, weight: .semibold))
                    Text(selectedDayLunarLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(secondaryText)
                }
                Spacer()
                if calendarService.isLoading {
                    ProgressView().controlSize(.small)
                }
                Button(action: presentNewEvent) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(ClockCalendarControlButtonStyle())
                .help("New event")
                .accessibilityLabel("New event")
                .disabled(calendarService.authorizationState == .restricted)
            }
            .frame(height: 48)

            agendaContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 16)
        .padding(.top, ClockCalendarMetrics.agendaTopSpacing)
    }

    @ViewBuilder
    private var agendaContent: some View {
        switch calendarService.authorizationState {
        case .fullAccess:
            let events = calendarService.events(on: state.selectedDate)
            if events.isEmpty {
                Text("No events")
                    .font(.system(size: 12))
                    .foregroundStyle(secondaryText)
                    .italic()
                    .padding(.top, 16)
            } else {
                VStack(spacing: 4) {
                    ForEach(Array(events.prefix(3))) { event in
                        agendaRow(event)
                    }
                    if events.count > 3 {
                        Text(moreEventsText(events.count - 3))
                            .font(.system(size: 10))
                            .foregroundStyle(secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        case .notDetermined, .writeOnly:
            VStack(alignment: .leading, spacing: 8) {
                Text("Show events from your Mac calendars.")
                    .font(.system(size: 11))
                    .foregroundStyle(secondaryText)
                Button {
                    Task { await requestCalendarAccess() }
                } label: {
                    HStack(spacing: 6) {
                        if calendarService.isRequestingAccess {
                            ProgressView().controlSize(.mini)
                        }
                        Text("Allow calendar access")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(calendarService.isRequestingAccess)
            }
            .padding(.top, 10)
        case .denied, .restricted:
            VStack(alignment: .leading, spacing: 8) {
                Text("Calendar access is turned off.")
                    .font(.system(size: 11))
                    .foregroundStyle(secondaryText)
                Button("Open System Settings", action: openCalendarPrivacySettings)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.top, 10)
        }
    }

    private func agendaRow(_ event: SystemCalendarEvent) -> some View {
        Button {
            guard event.isEditable else { return }
            presentEventEditor(SystemCalendarEventDraft(event: event))
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color(
                        red: event.calendarColor.red,
                        green: event.calendarColor.green,
                        blue: event.calendarColor.blue
                    ))
                    .frame(width: 3, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Text(eventTimeText(event))
                        .font(.system(size: 9))
                        .foregroundStyle(secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if event.isEditable {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(secondaryText)
                }
            }
            .contentShape(Rectangle())
            .frame(height: 31)
        }
        .buttonStyle(.plain)
        .disabled(!event.isEditable)
        .accessibilityLabel("\(event.title), \(eventTimeText(event))")
    }

    private var selectedDayLunarLabel: String {
        ClockCalendarLunarCalendar.lunarDate(
            for: state.selectedDate,
            timeZone: ClockCalendarState.calendar.timeZone
        ).fullLabel
    }

    private func eventTimeText(_ event: SystemCalendarEvent) -> String {
        if event.isAllDay {
            return "\(NSLocalizedString("All day", comment: "All-day calendar event")) · \(event.calendarTitle)"
        }
        let start = event.startDate.formatted(date: .omitted, time: .shortened)
        let end = event.endDate.formatted(date: .omitted, time: .shortened)
        return "\(start)–\(end) · \(event.calendarTitle)"
    }

    private func moreEventsText(_ count: Int) -> String {
        String.localizedStringWithFormat(
            NSLocalizedString("%ld more events", comment: "Additional events hidden from the compact agenda"),
            count
        )
    }

    private func loadVisibleEvents() {
        Task { await calendarService.loadEvents(in: state.eventQueryInterval) }
    }

    private func requestCalendarAccess() async {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.keyWindow?.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 100_000_000)
        guard await calendarService.requestFullAccess() else { return }
        await calendarService.loadEvents(in: state.eventQueryInterval, force: true)
    }

    private func presentNewEvent() {
        Task {
            if !calendarService.authorizationState.canRead {
                await requestCalendarAccess()
                guard calendarService.authorizationState.canRead else { return }
            }
            guard let draft = calendarService.newDraft(on: state.selectedDate) else { return }
            presentEventEditor(draft)
        }
    }

    private func presentEventEditor(_ draft: SystemCalendarEventDraft) {
        withAnimation(.easeOut(duration: 0.12)) {
            eventDraft = draft
            state.isEditingCalendarEvent = true
        }
    }

    private func dismissEventEditor() {
        withAnimation(.easeOut(duration: 0.10)) {
            eventDraft = nil
            state.isEditingCalendarEvent = false
        }
    }

    private func saveEvent(_ draft: SystemCalendarEventDraft, scope: SystemCalendarMutationScope) {
        Task {
            do {
                try await calendarService.save(draft, scope: scope)
                dismissEventEditor()
            } catch {
                calendarErrorMessage = error.localizedDescription
            }
        }
    }

    private func deleteEvent(_ draft: SystemCalendarEventDraft, scope: SystemCalendarMutationScope) {
        Task {
            do {
                try await calendarService.delete(draft, scope: scope)
                dismissEventEditor()
            } catch {
                calendarErrorMessage = error.localizedDescription
            }
        }
    }

    private func openCalendarPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") else {
            return
        }
        NSWorkspace.shared.open(url)
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
        Button { state.moveMonth(by: offset) } label: {
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

    private var sectionDivider: some View {
        Divider()
            .overlay(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.06))
            .padding(.horizontal, 16)
    }
}

private struct ClockCalendarDaysGrid: View {
    let days: [ClockCalendarDay]
    let selectedDate: Date
    let eventsByDay: [ClockCalendarDateKey: [SystemCalendarEvent]]
    let columns: [GridItem]
    let onSelect: (Date) -> Void

    var body: some View {
        LazyVGrid(columns: columns, spacing: 0) {
            ForEach(days) { day in
                ClockCalendarDayButton(
                    day: day,
                    selectedDate: selectedDate,
                    eventCount: eventsByDay[day.dateKey]?.count ?? 0,
                    onSelect: onSelect
                )
                    .frame(height: 42)
            }
        }
        .padding(.horizontal, 16)
    }
}

private struct ClockCalendarDayButton: View {
    let day: ClockCalendarDay
    let selectedDate: Date
    let eventCount: Int
    let onSelect: (Date) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    var body: some View {
        Button { onSelect(day.date) } label: {
            VStack(spacing: -1) {
                Text("\(day.day)")
                    .font(.system(size: 14))
                    .foregroundStyle(dayNumberColor)
                Text(day.annotation.secondaryLabel)
                    .font(.system(size: 9))
                    .foregroundStyle(secondaryLabelColor)
            }
                .frame(width: 40, height: 40)
                .background(background)
                .overlay(selectionBorder)
                .overlay(alignment: .bottom) {
                    if eventCount > 0 {
                        Circle()
                            .fill(isToday ? Color.white : Color.win11Accent)
                            .frame(width: 3, height: 3)
                            .padding(.bottom, 1)
                    }
                }
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(accessibilityLabel)
    }

    private var isToday: Bool {
        ClockCalendarState.calendar.isDateInToday(day.date)
    }

    private var isSelected: Bool {
        ClockCalendarState.calendar.isDate(day.date, inSameDayAs: selectedDate)
    }

    private var dayNumberColor: Color {
        if isToday { return .white }
        let color = day.annotation.isRestDay ? Color.calendarRestDay : primaryTextColor
        if !day.isInDisplayedMonth {
            return color.opacity(0.36)
        }
        return color
    }

    private var secondaryLabelColor: Color {
        if isToday { return .white.opacity(0.92) }
        let color: Color
        switch day.annotation.secondaryLabelKind {
        case .festival:
            color = .calendarFestival
        case .solarTerm:
            color = .calendarSolarTerm
        case .lunar:
            color = day.annotation.isRestDay ? .calendarRestDay : primaryTextColor.opacity(0.78)
        }
        return day.isInDisplayedMonth ? color : color.opacity(0.36)
    }

    private var primaryTextColor: Color {
        colorScheme == .dark ? .white.opacity(0.92) : .black.opacity(0.88)
    }

    private var accessibilityLabel: String {
        var components = [
            day.date.formatted(date: .complete, time: .omitted),
            day.lunarDate.fullLabel
        ]
        if day.annotation.secondaryLabelKind != .lunar {
            components.append(day.annotation.secondaryLabel)
        }
        if let workState = day.annotation.workState {
            switch workState {
            case let .holiday(name): components.append("\(name) holiday")
            case let .makeupWorkday(name): components.append("\(name) makeup workday")
            }
        }
        if eventCount > 0 { components.append("\(eventCount) events") }
        return components.joined(separator: ", ")
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
    static let calendarRestDay = Color(red: 1.0, green: 0.39, blue: 0.33)
    static let calendarFestival = Color(red: 1.0, green: 0.43, blue: 0.28)
    static let calendarSolarTerm = Color(red: 0.20, green: 0.58, blue: 1.0)
}
