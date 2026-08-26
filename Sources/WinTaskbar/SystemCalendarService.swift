import AppKit
import Combine
import EventKit
import Foundation

enum SystemCalendarAuthorizationState: Equatable {
    case notDetermined
    case denied
    case restricted
    case writeOnly
    case fullAccess

    var canRead: Bool { self == .fullAccess }
}

struct SystemCalendarColor: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    static let accent = SystemCalendarColor(red: 0.24, green: 0.74, blue: 0.98)
}

struct SystemCalendarDescriptor: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let color: SystemCalendarColor
    let isDefault: Bool
}

enum SystemCalendarRecurrenceOption: String, CaseIterable, Identifiable, Sendable {
    case never
    case daily
    case weekly
    case monthly
    case yearly
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .never: NSLocalizedString("Never", comment: "Calendar recurrence")
        case .daily: NSLocalizedString("Every day", comment: "Calendar recurrence")
        case .weekly: NSLocalizedString("Every week", comment: "Calendar recurrence")
        case .monthly: NSLocalizedString("Every month", comment: "Calendar recurrence")
        case .yearly: NSLocalizedString("Every year", comment: "Calendar recurrence")
        case .custom: NSLocalizedString("Custom", comment: "Calendar recurrence")
        }
    }

    var eventKitRule: EKRecurrenceRule? {
        let frequency: EKRecurrenceFrequency
        switch self {
        case .never, .custom: return nil
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly: frequency = .yearly
        }
        return EKRecurrenceRule(recurrenceWith: frequency, interval: 1, end: nil)
    }

    static func option(for rules: [EKRecurrenceRule]?) -> Self {
        guard let rules, rules.count == 1, let rule = rules.first else {
            return rules?.isEmpty == false ? .custom : .never
        }
        guard rule.interval == 1, rule.recurrenceEnd == nil else { return .custom }
        switch rule.frequency {
        case .daily: return .daily
        case .weekly: return .weekly
        case .monthly: return .monthly
        case .yearly: return .yearly
        @unknown default: return .custom
        }
    }
}

enum SystemCalendarAlertOption: String, CaseIterable, Identifiable, Sendable {
    case none
    case atStart
    case fiveMinutesBefore
    case fifteenMinutesBefore
    case thirtyMinutesBefore
    case oneHourBefore
    case oneDayBefore
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: NSLocalizedString("None", comment: "Calendar reminder")
        case .atStart: NSLocalizedString("At start time", comment: "Calendar reminder")
        case .fiveMinutesBefore: NSLocalizedString("5 minutes before", comment: "Calendar reminder")
        case .fifteenMinutesBefore: NSLocalizedString("15 minutes before", comment: "Calendar reminder")
        case .thirtyMinutesBefore: NSLocalizedString("30 minutes before", comment: "Calendar reminder")
        case .oneHourBefore: NSLocalizedString("1 hour before", comment: "Calendar reminder")
        case .oneDayBefore: NSLocalizedString("1 day before", comment: "Calendar reminder")
        case .custom: NSLocalizedString("Custom", comment: "Calendar reminder")
        }
    }

    var relativeOffset: TimeInterval? {
        switch self {
        case .none, .custom: nil
        case .atStart: 0
        case .fiveMinutesBefore: -5 * 60
        case .fifteenMinutesBefore: -15 * 60
        case .thirtyMinutesBefore: -30 * 60
        case .oneHourBefore: -60 * 60
        case .oneDayBefore: -24 * 60 * 60
        }
    }

    static func option(for alarms: [EKAlarm]?) -> Self {
        guard let alarms, alarms.count == 1, let alarm = alarms.first,
              alarm.absoluteDate == nil, alarm.structuredLocation == nil else {
            return alarms?.isEmpty == false ? .custom : .none
        }
        switch alarm.relativeOffset {
        case 0: return .atStart
        case -5 * 60: return .fiveMinutesBefore
        case -15 * 60: return .fifteenMinutesBefore
        case -30 * 60: return .thirtyMinutesBefore
        case -60 * 60: return .oneHourBefore
        case -24 * 60 * 60: return .oneDayBefore
        default: return .custom
        }
    }
}

struct SystemCalendarEventIdentity: Hashable, Sendable {
    let eventIdentifier: String
    let calendarItemIdentifier: String
    let occurrenceStartDate: Date
}

struct SystemCalendarEvent: Equatable, Identifiable, Sendable {
    let identity: SystemCalendarEventIdentity
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let location: String?
    let notes: String?
    let url: URL?
    let timeZoneIdentifier: String
    let recurrenceOption: SystemCalendarRecurrenceOption
    let alertOption: SystemCalendarAlertOption
    let calendarID: String
    let calendarTitle: String
    let calendarColor: SystemCalendarColor
    let isEditable: Bool
    let isRecurring: Bool

    var id: String {
        "\(identity.calendarItemIdentifier)-\(startDate.timeIntervalSinceReferenceDate)"
    }
}

struct SystemCalendarEventDraft: Equatable, Sendable {
    var identity: SystemCalendarEventIdentity?
    var title: String
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    var location: String
    var notes: String
    var urlString: String
    var timeZoneIdentifier: String
    var recurrenceOption: SystemCalendarRecurrenceOption
    var alertOption: SystemCalendarAlertOption
    var calendarID: String
    let originalRecurrenceOption: SystemCalendarRecurrenceOption
    let originalAlertOption: SystemCalendarAlertOption

    var isRecurring: Bool { recurrenceOption != .never }

    init(event: SystemCalendarEvent) {
        identity = event.identity
        title = event.title
        startDate = event.startDate
        endDate = event.endDate
        isAllDay = event.isAllDay
        location = event.location ?? ""
        notes = event.notes ?? ""
        urlString = event.url?.absoluteString ?? ""
        timeZoneIdentifier = event.timeZoneIdentifier
        recurrenceOption = event.recurrenceOption
        alertOption = event.alertOption
        calendarID = event.calendarID
        originalRecurrenceOption = event.recurrenceOption
        originalAlertOption = event.alertOption
    }

    init(
        title: String = "",
        startDate: Date,
        endDate: Date,
        isAllDay: Bool = false,
        calendarID: String,
        timeZoneIdentifier: String = TimeZone.autoupdatingCurrent.identifier
    ) {
        identity = nil
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        location = ""
        notes = ""
        urlString = ""
        self.timeZoneIdentifier = timeZoneIdentifier
        recurrenceOption = .never
        alertOption = .fifteenMinutesBefore
        self.calendarID = calendarID
        originalRecurrenceOption = .never
        originalAlertOption = .fifteenMinutesBefore
    }
}

enum SystemCalendarMutationScope: String, CaseIterable, Identifiable {
    case thisEvent
    case futureEvents

    var id: String { rawValue }

    var eventKitSpan: EKSpan {
        switch self {
        case .thisEvent: .thisEvent
        case .futureEvents: .futureEvents
        }
    }
}

enum SystemCalendarServiceError: LocalizedError {
    case accessRequired
    case eventUnavailable
    case invalidDates
    case missingTitle
    case noWritableCalendar
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .accessRequired:
            NSLocalizedString("Calendar access is required.", comment: "Calendar error")
        case .eventUnavailable:
            NSLocalizedString("This event is no longer available.", comment: "Calendar error")
        case .invalidDates:
            NSLocalizedString("The end time must be after the start time.", comment: "Calendar error")
        case .missingTitle:
            NSLocalizedString("Enter an event title.", comment: "Calendar error")
        case .noWritableCalendar:
            NSLocalizedString("No writable calendar is available.", comment: "Calendar error")
        case .invalidURL:
            NSLocalizedString("Enter a valid web address.", comment: "Calendar error")
        }
    }
}

enum SystemCalendarEventGrouping {
    static func group(
        _ events: [SystemCalendarEvent],
        in interval: DateInterval,
        calendar: Calendar
    ) -> [ClockCalendarDateKey: [SystemCalendarEvent]] {
        var grouped: [ClockCalendarDateKey: [SystemCalendarEvent]] = [:]
        for event in events {
            let normalizedEnd = max(event.endDate, event.startDate.addingTimeInterval(0.001))
            guard normalizedEnd > interval.start, event.startDate < interval.end else { continue }
            let firstDate = max(event.startDate, interval.start)
            let exclusiveEnd = min(normalizedEnd, interval.end)
            let finalDate = max(firstDate, exclusiveEnd.addingTimeInterval(-0.001))
            var day = calendar.startOfDay(for: firstDate)
            let finalDay = calendar.startOfDay(for: finalDate)

            while day <= finalDay {
                grouped[ClockCalendarDateKey(date: day, calendar: calendar), default: []].append(event)
                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = nextDay
            }
        }

        for key in grouped.keys {
            grouped[key]?.sort {
                if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
                if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
        return grouped
    }
}

@MainActor
final class SystemCalendarService: ObservableObject {
    @Published private(set) var authorizationState: SystemCalendarAuthorizationState
    @Published private(set) var eventsByDay: [ClockCalendarDateKey: [SystemCalendarEvent]] = [:]
    @Published private(set) var writableCalendars: [SystemCalendarDescriptor] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isRequestingAccess = false
    @Published private(set) var errorMessage: String?

    private let eventStore: EKEventStore
    private nonisolated(unsafe) var changeObserver: NSObjectProtocol?
    private var loadedInterval: DateInterval?
    private var requestedInterval: DateInterval?

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
        authorizationState = Self.currentAuthorizationState
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: eventStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.reloadCurrentRange()
            }
        }
        if authorizationState.canRead {
            reloadCalendars()
        }
    }

    deinit {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
    }

    static var currentAuthorizationState: SystemCalendarAuthorizationState {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            switch status {
            case .fullAccess: return .fullAccess
            case .writeOnly: return .writeOnly
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            case .authorized: return .fullAccess
            @unknown default: return .denied
            }
        }
        if status == .authorized { return .fullAccess }
        if status == .restricted { return .restricted }
        if status == .notDetermined { return .notDetermined }
        return .denied
    }

    func refreshAuthorizationState() {
        authorizationState = Self.currentAuthorizationState
        if authorizationState.canRead {
            reloadCalendars()
        } else {
            eventsByDay = [:]
            writableCalendars = []
            loadedInterval = nil
        }
    }

    @discardableResult
    func requestFullAccess() async -> Bool {
        guard !isRequestingAccess else { return false }
        isRequestingAccess = true
        errorMessage = nil
        defer { isRequestingAccess = false }

        do {
            let granted: Bool
            if #available(macOS 14.0, *) {
                granted = try await eventStore.requestFullAccessToEvents()
            } else {
                granted = try await eventStore.requestAccess(to: .event)
            }
            refreshAuthorizationState()
            if !granted, authorizationState == .notDetermined {
                errorMessage = SystemCalendarServiceError.accessRequired.errorDescription
            }
            if granted, let requestedInterval {
                await loadEvents(in: requestedInterval, force: true)
            }
            return granted
        } catch {
            errorMessage = error.localizedDescription
            refreshAuthorizationState()
            return false
        }
    }

    func loadEvents(in interval: DateInterval, force: Bool = false) async {
        requestedInterval = interval
        refreshAuthorizationState()
        guard authorizationState.canRead else { return }
        if !force,
           let loadedInterval,
           loadedInterval.start <= interval.start,
           loadedInterval.end >= interval.end {
            return
        }

        let calendar = ClockCalendarState.calendar
        let fetchStart = calendar.date(byAdding: .day, value: -28, to: interval.start) ?? interval.start
        let fetchEnd = calendar.date(byAdding: .day, value: 28, to: interval.end) ?? interval.end
        let fetchInterval = DateInterval(start: fetchStart, end: fetchEnd)
        isLoading = true
        defer { isLoading = false }

        let predicate = eventStore.predicateForEvents(
            withStart: fetchInterval.start,
            end: fetchInterval.end,
            calendars: nil
        )
        let events = eventStore.events(matching: predicate).map(Self.snapshot)
        eventsByDay = SystemCalendarEventGrouping.group(events, in: fetchInterval, calendar: calendar)
        loadedInterval = fetchInterval
        errorMessage = nil
    }

    func events(on date: Date, calendar: Calendar = ClockCalendarState.calendar) -> [SystemCalendarEvent] {
        eventsByDay[ClockCalendarDateKey(date: date, calendar: calendar)] ?? []
    }

    func eventCount(on date: Date, calendar: Calendar = ClockCalendarState.calendar) -> Int {
        events(on: date, calendar: calendar).count
    }

    func newDraft(on date: Date, calendar: Calendar = ClockCalendarState.calendar) -> SystemCalendarEventDraft? {
        guard let selectedCalendar = writableCalendars.first(where: \.isDefault) ?? writableCalendars.first else {
            errorMessage = SystemCalendarServiceError.noWritableCalendar.localizedDescription
            return nil
        }

        let startDate: Date
        if calendar.isDateInToday(date) {
            let nextHour = Date().addingTimeInterval(3_600)
            startDate = calendar.date(bySetting: .minute, value: 0, of: nextHour) ?? nextHour
        } else {
            startDate = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: date) ?? date
        }
        let endDate = calendar.date(byAdding: .hour, value: 1, to: startDate) ?? startDate.addingTimeInterval(3_600)
        return SystemCalendarEventDraft(
            startDate: startDate,
            endDate: endDate,
            calendarID: selectedCalendar.id
        )
    }

    func save(
        _ draft: SystemCalendarEventDraft,
        scope: SystemCalendarMutationScope = .thisEvent
    ) async throws {
        guard authorizationState.canRead else { throw SystemCalendarServiceError.accessRequired }
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SystemCalendarServiceError.missingTitle
        }
        guard draft.endDate > draft.startDate else { throw SystemCalendarServiceError.invalidDates }
        guard let calendar = eventStore.calendar(withIdentifier: draft.calendarID),
              calendar.allowsContentModifications else {
            throw SystemCalendarServiceError.noWritableCalendar
        }

        let event: EKEvent
        if let identity = draft.identity {
            guard let existingEvent = resolveEvent(identity) else {
                throw SystemCalendarServiceError.eventUnavailable
            }
            event = existingEvent
        } else {
            event = EKEvent(eventStore: eventStore)
        }

        event.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        event.startDate = draft.startDate
        event.endDate = draft.endDate
        event.isAllDay = draft.isAllDay
        event.location = draft.location.trimmingCharacters(in: .whitespacesAndNewlines)
        event.notes = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = draft.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedURL.isEmpty || Self.normalizedEventURL(trimmedURL) != nil else {
            throw SystemCalendarServiceError.invalidURL
        }
        event.url = trimmedURL.isEmpty ? nil : Self.normalizedEventURL(trimmedURL)
        event.timeZone = TimeZone(identifier: draft.timeZoneIdentifier) ?? .autoupdatingCurrent
        if draft.identity == nil || draft.recurrenceOption != draft.originalRecurrenceOption {
            event.recurrenceRules = draft.recurrenceOption.eventKitRule.map { [$0] }
        }
        if draft.identity == nil || draft.alertOption != draft.originalAlertOption {
            event.alarms = draft.alertOption.relativeOffset.map { [EKAlarm(relativeOffset: $0)] }
        }
        event.calendar = calendar
        try eventStore.save(event, span: scope.eventKitSpan, commit: true)
        await reloadCurrentRange()
    }

    func delete(
        _ draft: SystemCalendarEventDraft,
        scope: SystemCalendarMutationScope = .thisEvent
    ) async throws {
        guard authorizationState.canRead else { throw SystemCalendarServiceError.accessRequired }
        guard let identity = draft.identity,
              let event = resolveEvent(identity) else {
            throw SystemCalendarServiceError.eventUnavailable
        }
        guard event.calendar.allowsContentModifications else {
            throw SystemCalendarServiceError.noWritableCalendar
        }
        try eventStore.remove(event, span: scope.eventKitSpan, commit: true)
        await reloadCurrentRange()
    }

    func clearError() {
        errorMessage = nil
    }

    static func normalizedEventURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = URLComponents(string: trimmed)?.scheme == nil ? "https://\(trimmed)" : trimmed
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme, !scheme.isEmpty else { return nil }
        if ["http", "https"].contains(scheme.lowercased()), components.host?.isEmpty != false {
            return nil
        }
        return components.url
    }

    private func reloadCurrentRange() async {
        guard let requestedInterval else { return }
        loadedInterval = nil
        await loadEvents(in: requestedInterval, force: true)
    }

    private func reloadCalendars() {
        let defaultID = eventStore.defaultCalendarForNewEvents?.calendarIdentifier
        writableCalendars = eventStore.calendars(for: .event)
            .filter(\.allowsContentModifications)
            .map { calendar in
                SystemCalendarDescriptor(
                    id: calendar.calendarIdentifier,
                    title: calendar.title,
                    color: Self.color(calendar.cgColor),
                    isDefault: calendar.calendarIdentifier == defaultID
                )
            }
            .sorted {
                if $0.isDefault != $1.isDefault { return $0.isDefault }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
    }

    private func resolveEvent(_ identity: SystemCalendarEventIdentity) -> EKEvent? {
        if let event = eventStore.event(withIdentifier: identity.eventIdentifier),
           abs(event.startDate.timeIntervalSince(identity.occurrenceStartDate)) < 1 {
            return event
        }

        let start = identity.occurrenceStartDate.addingTimeInterval(-86_400)
        let end = identity.occurrenceStartDate.addingTimeInterval(86_400)
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        return eventStore.events(matching: predicate).first {
            $0.calendarItemIdentifier == identity.calendarItemIdentifier
                && abs($0.startDate.timeIntervalSince(identity.occurrenceStartDate)) < 1
        }
    }

    private static func snapshot(_ event: EKEvent) -> SystemCalendarEvent {
        SystemCalendarEvent(
            identity: SystemCalendarEventIdentity(
                eventIdentifier: event.eventIdentifier,
                calendarItemIdentifier: event.calendarItemIdentifier,
                occurrenceStartDate: event.startDate
            ),
            title: event.title?.isEmpty == false
                ? event.title
                : NSLocalizedString("Untitled event", comment: "Calendar event without a title"),
            startDate: event.startDate,
            endDate: event.endDate,
            isAllDay: event.isAllDay,
            location: event.location,
            notes: event.notes,
            url: event.url,
            timeZoneIdentifier: event.timeZone?.identifier ?? TimeZone.autoupdatingCurrent.identifier,
            recurrenceOption: SystemCalendarRecurrenceOption.option(for: event.recurrenceRules),
            alertOption: SystemCalendarAlertOption.option(for: event.alarms),
            calendarID: event.calendar.calendarIdentifier,
            calendarTitle: event.calendar.title,
            calendarColor: color(event.calendar.cgColor),
            isEditable: event.calendar.allowsContentModifications,
            isRecurring: event.hasRecurrenceRules
        )
    }

    private static func color(_ cgColor: CGColor?) -> SystemCalendarColor {
        guard let cgColor,
              let color = NSColor(cgColor: cgColor)?.usingColorSpace(.deviceRGB) else {
            return .accent
        }
        return SystemCalendarColor(
            red: Double(color.redComponent),
            green: Double(color.greenComponent),
            blue: Double(color.blueComponent)
        )
    }
}
