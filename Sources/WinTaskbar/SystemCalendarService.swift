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
    var calendarID: String
    var isRecurring: Bool

    init(event: SystemCalendarEvent) {
        identity = event.identity
        title = event.title
        startDate = event.startDate
        endDate = event.endDate
        isAllDay = event.isAllDay
        location = event.location ?? ""
        notes = event.notes ?? ""
        calendarID = event.calendarID
        isRecurring = event.isRecurring
    }

    init(
        title: String = "",
        startDate: Date,
        endDate: Date,
        isAllDay: Bool = false,
        calendarID: String
    ) {
        identity = nil
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        location = ""
        notes = ""
        self.calendarID = calendarID
        isRecurring = false
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
