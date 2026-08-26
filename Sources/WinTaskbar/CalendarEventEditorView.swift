import SwiftUI

struct CalendarEventEditorView: View {
    @State private var draft: SystemCalendarEventDraft
    @State private var mutationScope: SystemCalendarMutationScope = .thisEvent
    @State private var activeFlyout: EventEditorFlyout?
    @Environment(\.colorScheme) private var colorScheme

    let calendars: [SystemCalendarDescriptor]
    let onCancel: () -> Void
    let onSave: (SystemCalendarEventDraft, SystemCalendarMutationScope) -> Void
    let onDelete: (SystemCalendarEventDraft, SystemCalendarMutationScope) -> Void

    init(
        initialDraft: SystemCalendarEventDraft,
        calendars: [SystemCalendarDescriptor],
        onCancel: @escaping () -> Void,
        onSave: @escaping (SystemCalendarEventDraft, SystemCalendarMutationScope) -> Void,
        onDelete: @escaping (SystemCalendarEventDraft, SystemCalendarMutationScope) -> Void
    ) {
        _draft = State(initialValue: initialDraft)
        self.calendars = calendars
        self.onCancel = onCancel
        self.onSave = onSave
        self.onDelete = onDelete
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                editorHeader
                Rectangle()
                    .fill(separatorColor)
                    .frame(height: 1)
                ScrollView {
                    editorForm
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                }
                .scrollIndicators(.hidden)
            }

            if let activeFlyout {
                flyout(activeFlyout)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(editorBackground)
        .onExitCommand(perform: dismissTopmostLayer)
    }

    private var editorHeader: some View {
        HStack(spacing: 10) {
            Button(action: onCancel) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(WindowsSubtleButtonStyle())
            .accessibilityLabel("Back")

            Text(draft.identity == nil ? "New event" : "Edit event")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Button("Save") { onSave(draft, mutationScope) }
                .buttonStyle(WindowsAccentButtonStyle())
                .disabled(!canSave)
        }
        .padding(.horizontal, 14)
        .frame(height: 54)
    }

    private var editorForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            WindowsFormField("Title") {
                WindowsTextInput(placeholder: "Event title", text: $draft.title)
            }

            WindowsFormField("Location") {
                WindowsTextInput(placeholder: "Add location", text: $draft.location, systemImage: "mappin")
            }

            WindowsToggleSwitch(title: "All day", isOn: $draft.isAllDay)
                .onChange(of: draft.isAllDay) { setAllDay($0) }

            WindowsFormField("Starts") {
                WindowsComboBox(
                    value: formattedDate(draft.startDate),
                    systemImage: "calendar",
                    action: { show(.start) }
                )
            }

            WindowsFormField("Ends") {
                WindowsComboBox(
                    value: formattedDate(displayedEndDate),
                    systemImage: "calendar",
                    action: { show(.end) }
                )
            }

            WindowsFormField("Time zone") {
                WindowsComboBox(
                    value: timeZoneTitle(draft.timeZoneIdentifier),
                    systemImage: "globe",
                    action: { show(.timeZone) }
                )
            }

            WindowsFormField("Repeat") {
                WindowsComboBox(
                    value: draft.recurrenceOption.title,
                    systemImage: "repeat",
                    action: { show(.recurrence) }
                )
            }

            WindowsFormField("Reminder") {
                WindowsComboBox(
                    value: draft.alertOption.title,
                    systemImage: "bell",
                    action: { show(.alert) }
                )
            }

            WindowsFormField("Calendar") {
                WindowsComboBox(
                    value: selectedCalendar?.title ?? "Calendar",
                    leadingColor: selectedCalendar.map(color),
                    action: { show(.calendar) }
                )
            }

            if draft.identity != nil, draft.isRecurring {
                WindowsFormField("Apply to") {
                    WindowsComboBox(
                        value: mutationScopeTitle,
                        systemImage: "square.stack.3d.up",
                        action: { show(.scope) }
                    )
                }
            }

            WindowsFormField("Notes") {
                WindowsMultilineInput(placeholder: "Add notes", text: $draft.notes)
            }

            WindowsFormField("URL") {
                WindowsTextInput(placeholder: "Add URL", text: $draft.urlString, systemImage: "link")
                if !isURLValid {
                    Text("Enter a valid web address.")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(red: 0.94, green: 0.35, blue: 0.32))
                }
            }

            if draft.identity != nil {
                Button {
                    show(.delete)
                } label: {
                    Label("Delete event", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(WindowsDangerButtonStyle())
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func flyout(_ flyout: EventEditorFlyout) -> some View {
        ZStack {
            Color.black.opacity(colorScheme == .dark ? 0.46 : 0.22)
                .contentShape(Rectangle())
                .onTapGesture { dismissFlyout() }

            switch flyout {
            case .start:
                WindowsDateTimeFlyout(
                    title: "Starts",
                    date: startDateBinding,
                    isAllDay: draft.isAllDay,
                    timeZoneIdentifier: draft.timeZoneIdentifier,
                    minimumDate: nil,
                    onDone: dismissFlyout
                )
            case .end:
                WindowsDateTimeFlyout(
                    title: "Ends",
                    date: endDateBinding,
                    isAllDay: draft.isAllDay,
                    timeZoneIdentifier: draft.timeZoneIdentifier,
                    minimumDate: draft.isAllDay ? draft.startDate : draft.startDate.addingTimeInterval(60),
                    onDone: dismissFlyout
                )
            case .calendar:
                selectionFlyout(title: "Calendar", choices: calendarChoices, selectedID: draft.calendarID)
            case .timeZone:
                selectionFlyout(
                    title: "Time zone",
                    choices: timeZoneChoices,
                    selectedID: draft.timeZoneIdentifier,
                    allowsSearch: true
                )
            case .recurrence:
                selectionFlyout(
                    title: "Repeat",
                    choices: recurrenceChoices,
                    selectedID: draft.recurrenceOption.rawValue
                )
            case .alert:
                selectionFlyout(
                    title: "Reminder",
                    choices: alertChoices,
                    selectedID: draft.alertOption.rawValue
                )
            case .scope:
                selectionFlyout(
                    title: "Apply to",
                    choices: scopeChoices,
                    selectedID: mutationScope.rawValue
                )
            case .delete:
                WindowsConfirmationFlyout(
                    title: "Delete event?",
                    message: draft.isRecurring && mutationScope == .futureEvents
                        ? "This event and all future occurrences will be deleted."
                        : "This event will be deleted from your calendar.",
                    confirmTitle: "Delete",
                    onCancel: dismissFlyout,
                    onConfirm: { onDelete(draft, mutationScope) }
                )
            }
        }
    }

    private func selectionFlyout(
        title: LocalizedStringKey,
        choices: [WindowsChoice],
        selectedID: String,
        allowsSearch: Bool = false
    ) -> some View {
        WindowsSelectionFlyout(
            title: title,
            choices: choices,
            selectedID: selectedID,
            allowsSearch: allowsSearch,
            onCancel: dismissFlyout,
            onSelect: applyChoice
        )
    }

    private func applyChoice(_ choice: WindowsChoice) {
        guard let activeFlyout else { return }
        switch activeFlyout {
        case .calendar:
            draft.calendarID = choice.id
        case .timeZone:
            draft.timeZoneIdentifier = choice.id
        case .recurrence:
            if let option = SystemCalendarRecurrenceOption(rawValue: choice.id) {
                draft.recurrenceOption = option
            }
        case .alert:
            if let option = SystemCalendarAlertOption(rawValue: choice.id) {
                draft.alertOption = option
            }
        case .scope:
            if let scope = SystemCalendarMutationScope(rawValue: choice.id) {
                mutationScope = scope
            }
        case .start, .end, .delete:
            break
        }
        dismissFlyout()
    }

    private var startDateBinding: Binding<Date> {
        Binding(
            get: { draft.startDate },
            set: { newValue in setStartDate(newValue) }
        )
    }

    private var endDateBinding: Binding<Date> {
        Binding(
            get: { displayedEndDate },
            set: { newValue in
                let calendar = eventCalendar
                if draft.isAllDay {
                    let selectedDay = calendar.startOfDay(for: newValue)
                    let startDay = calendar.startOfDay(for: draft.startDate)
                    let day = selectedDay >= startDay ? selectedDay : startDay
                    draft.endDate = calendar.date(byAdding: .day, value: 1, to: day)
                        ?? day.addingTimeInterval(86_400)
                } else {
                    let minimumEnd = draft.startDate.addingTimeInterval(60)
                    draft.endDate = newValue >= minimumEnd ? newValue : minimumEnd
                }
            }
        )
    }

    private var displayedEndDate: Date {
        guard draft.isAllDay else { return draft.endDate }
        return eventCalendar.date(byAdding: .day, value: -1, to: draft.endDate) ?? draft.endDate
    }

    private func setStartDate(_ newValue: Date) {
        let calendar = eventCalendar
        let duration = max(draft.endDate.timeIntervalSince(draft.startDate), draft.isAllDay ? 86_400 : 3_600)
        if draft.isAllDay {
            draft.startDate = calendar.startOfDay(for: newValue)
            let days = max(1, Int((duration / 86_400).rounded()))
            draft.endDate = calendar.date(byAdding: .day, value: days, to: draft.startDate)
                ?? draft.startDate.addingTimeInterval(TimeInterval(days) * 86_400)
        } else {
            draft.startDate = newValue
            draft.endDate = newValue.addingTimeInterval(duration)
        }
    }

    private func setAllDay(_ isAllDay: Bool) {
        let calendar = eventCalendar
        if isAllDay {
            draft.startDate = calendar.startOfDay(for: draft.startDate)
            draft.endDate = calendar.date(byAdding: .day, value: 1, to: draft.startDate)
                ?? draft.startDate.addingTimeInterval(86_400)
        } else {
            let start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: draft.startDate)
                ?? draft.startDate
            draft.startDate = start
            draft.endDate = start.addingTimeInterval(3_600)
        }
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = eventCalendar
        formatter.timeZone = eventCalendar.timeZone
        formatter.dateStyle = .short
        formatter.timeStyle = draft.isAllDay ? .none : .short
        return formatter.string(from: date)
    }

    private var eventCalendar: Calendar {
        var calendar = ClockCalendarState.calendar
        calendar.timeZone = TimeZone(identifier: draft.timeZoneIdentifier) ?? .autoupdatingCurrent
        return calendar
    }

    private var selectedCalendar: SystemCalendarDescriptor? {
        calendars.first { $0.id == draft.calendarID }
    }

    private var mutationScopeTitle: String {
        switch mutationScope {
        case .thisEvent: NSLocalizedString("This event", comment: "Recurring event scope")
        case .futureEvents: NSLocalizedString("This and future events", comment: "Recurring event scope")
        }
    }

    private var calendarChoices: [WindowsChoice] {
        calendars.map {
            WindowsChoice(id: $0.id, title: $0.title, color: color($0))
        }
    }

    private var recurrenceChoices: [WindowsChoice] {
        SystemCalendarRecurrenceOption.allCases.compactMap { option in
            guard option != .custom || draft.originalRecurrenceOption == .custom else { return nil }
            return WindowsChoice(id: option.rawValue, title: option.title)
        }
    }

    private var alertChoices: [WindowsChoice] {
        SystemCalendarAlertOption.allCases.compactMap { option in
            guard option != .custom || draft.originalAlertOption == .custom else { return nil }
            return WindowsChoice(id: option.rawValue, title: option.title)
        }
    }

    private var scopeChoices: [WindowsChoice] {
        [
            WindowsChoice(id: SystemCalendarMutationScope.thisEvent.rawValue, title: mutationScopeTitle(for: .thisEvent)),
            WindowsChoice(id: SystemCalendarMutationScope.futureEvents.rawValue, title: mutationScopeTitle(for: .futureEvents))
        ]
    }

    private var timeZoneChoices: [WindowsChoice] {
        let selectedIdentifier = draft.timeZoneIdentifier
        let identifiers = TimeZone.knownTimeZoneIdentifiers.filter { $0 != selectedIdentifier }.sorted {
            timeZoneTitle($0).localizedStandardCompare(timeZoneTitle($1)) == .orderedAscending
        }
        return ([selectedIdentifier] + identifiers).map { WindowsChoice(id: $0, title: timeZoneTitle($0)) }
    }

    private func timeZoneTitle(_ identifier: String) -> String {
        guard let timeZone = TimeZone(identifier: identifier) else { return identifier }
        let seconds = timeZone.secondsFromGMT(for: draft.startDate)
        let sign = seconds >= 0 ? "+" : "−"
        let absoluteMinutes = abs(seconds) / 60
        let offset = String(format: "UTC%@%02d:%02d", sign, absoluteMinutes / 60, absoluteMinutes % 60)
        let city = identifier.split(separator: "/").last.map(String.init)?.replacingOccurrences(of: "_", with: " ")
            ?? identifier
        return "(\(offset)) \(city)"
    }

    private func mutationScopeTitle(for scope: SystemCalendarMutationScope) -> String {
        switch scope {
        case .thisEvent: NSLocalizedString("This event", comment: "Recurring event scope")
        case .futureEvents: NSLocalizedString("This and future events", comment: "Recurring event scope")
        }
    }

    private func color(_ calendar: SystemCalendarDescriptor) -> Color {
        Color(red: calendar.color.red, green: calendar.color.green, blue: calendar.color.blue)
    }

    private var isURLValid: Bool {
        let value = draft.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || SystemCalendarService.normalizedEventURL(value) != nil
    }

    private var canSave: Bool {
        !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.endDate > draft.startDate
            && calendars.contains(where: { $0.id == draft.calendarID })
            && isURLValid
    }

    private func show(_ flyout: EventEditorFlyout) {
        withAnimation(.easeOut(duration: 0.10)) { activeFlyout = flyout }
    }

    private func dismissFlyout() {
        withAnimation(.easeOut(duration: 0.08)) { activeFlyout = nil }
    }

    private func dismissTopmostLayer() {
        if activeFlyout != nil { dismissFlyout() } else { onCancel() }
    }

    private var editorBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.105, green: 0.105, blue: 0.105)
            : Color(red: 0.953, green: 0.953, blue: 0.953)
    }

    private var separatorColor: Color {
        (colorScheme == .dark ? Color.white : Color.black).opacity(0.12)
    }
}

private enum EventEditorFlyout: Equatable {
    case start
    case end
    case calendar
    case timeZone
    case recurrence
    case alert
    case scope
    case delete
}

private struct WindowsChoice: Identifiable {
    let id: String
    let title: String
    var color: Color?
}

private struct WindowsFormField<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: () -> Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

private struct WindowsTextInput: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String
    var systemImage: String?
    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isFocused)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(controlFill)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isFocused ? windowsAccent : borderColor)
                .frame(height: isFocused ? 2 : 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(borderColor, lineWidth: 0.5)
        }
    }

    private var controlFill: Color {
        colorScheme == .dark ? Color(red: 0.16, green: 0.16, blue: 0.16) : .white
    }

    private var borderColor: Color {
        (colorScheme == .dark ? Color.white : Color.black).opacity(0.16)
    }
}

private struct WindowsMultilineInput: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String
    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .lineLimit(3...5)
            .focused($isFocused)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
        .frame(height: 68)
        .background(colorScheme == .dark ? Color(red: 0.16, green: 0.16, blue: 0.16) : .white)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isFocused ? windowsAccent : borderColor)
                .frame(height: isFocused ? 2 : 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(borderColor, lineWidth: 0.5)
        }
    }

    private var borderColor: Color {
        (colorScheme == .dark ? Color.white : Color.black).opacity(0.16)
    }
}

private struct WindowsComboBox: View {
    let value: String
    var systemImage: String?
    var leadingColor: Color?
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let leadingColor {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(leadingColor)
                        .frame(width: 12, height: 12)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 13)
                }
                Text(value)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke((colorScheme == .dark ? Color.white : Color.black).opacity(0.16), lineWidth: 0.5)
        }
    }

    private var controlFill: Color {
        colorScheme == .dark ? Color(red: 0.16, green: 0.16, blue: 0.16) : .white
    }
}

private struct WindowsToggleSwitch: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(isOn ? windowsAccent : offFill)
                        .frame(width: 40, height: 20)
                    Circle()
                        .fill(isOn ? Color.white : knobFill)
                        .frame(width: 14, height: 14)
                        .padding(3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOn ? "On" : "Off")
    }

    private var offFill: Color {
        (colorScheme == .dark ? Color.white : Color.black).opacity(0.18)
    }

    private var knobFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.86) : Color.black.opacity(0.62)
    }
}

private struct WindowsSelectionFlyout: View {
    let title: LocalizedStringKey
    let choices: [WindowsChoice]
    let selectedID: String
    let allowsSearch: Bool
    let onCancel: () -> Void
    let onSelect: (WindowsChoice) -> Void
    @State private var query = ""
    @Environment(\.colorScheme) private var colorScheme

    private var filteredChoices: [WindowsChoice] {
        guard !query.isEmpty else { return choices }
        return choices.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(WindowsSubtleButtonStyle())
            }
            .padding(.horizontal, 14)
            .frame(height: 50)

            if allowsSearch {
                WindowsTextInput(placeholder: "Search", text: $query, systemImage: "magnifyingglass")
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }

            Rectangle().fill(separatorColor).frame(height: 1)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filteredChoices) { choice in
                        Button { onSelect(choice) } label: {
                            HStack(spacing: 9) {
                                if let color = choice.color {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(color)
                                        .frame(width: 12, height: 12)
                                }
                                Text(choice.title)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                Spacer()
                                if choice.id == selectedID {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(windowsAccent)
                                }
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(WindowsListRowButtonStyle(selected: choice.id == selectedID))
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: 304, height: allowsSearch ? 500 : min(390, CGFloat(choices.count * 36 + 58)))
        .background(flyoutFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(separatorColor, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }

    private var flyoutFill: Color {
        colorScheme == .dark ? Color(red: 0.125, green: 0.125, blue: 0.125) : Color(red: 0.98, green: 0.98, blue: 0.98)
    }

    private var separatorColor: Color {
        (colorScheme == .dark ? Color.white : Color.black).opacity(0.14)
    }
}

private struct WindowsDateTimeFlyout: View {
    let title: LocalizedStringKey
    @Binding var date: Date
    let isAllDay: Bool
    let timeZoneIdentifier: String
    let minimumDate: Date?
    let onDone: () -> Void
    @State private var displayedMonth: Date
    @Environment(\.colorScheme) private var colorScheme

    init(
        title: LocalizedStringKey,
        date: Binding<Date>,
        isAllDay: Bool,
        timeZoneIdentifier: String,
        minimumDate: Date?,
        onDone: @escaping () -> Void
    ) {
        self.title = title
        _date = date
        self.isAllDay = isAllDay
        self.timeZoneIdentifier = timeZoneIdentifier
        self.minimumDate = minimumDate
        self.onDone = onDone
        var calendar = ClockCalendarState.calendar
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .autoupdatingCurrent
        _displayedMonth = State(initialValue: calendar.dateInterval(of: .month, for: date.wrappedValue)?.start ?? date.wrappedValue)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Done", action: onDone)
                    .buttonStyle(WindowsAccentButtonStyle())
            }
            .padding(.horizontal, 14)
            .frame(height: 50)

            Rectangle().fill(separatorColor).frame(height: 1)

            HStack {
                Text(displayedMonth, format: .dateTime.month(.wide).year())
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { moveMonth(-1) } label: {
                    Image(systemName: "chevron.left").frame(width: 26, height: 26)
                }
                .buttonStyle(WindowsSubtleButtonStyle())
                Button { moveMonth(1) } label: {
                    Image(systemName: "chevron.right").frame(width: 26, height: 26)
                }
                .buttonStyle(WindowsSubtleButtonStyle())
            }
            .padding(.horizontal, 12)
            .frame(height: 46)

            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(Array(ClockCalendarGrid.weekdaySymbols(calendar: calendar).enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 24)
                }
                ForEach(days) { day in
                    Button { select(day.date) } label: {
                        Text("\(day.day)")
                            .font(.system(size: 11, weight: isSelected(day.date) ? .semibold : .regular))
                            .frame(width: 30, height: 30)
                            .background(isSelected(day.date) ? windowsAccent : Color.clear)
                            .foregroundStyle(isSelected(day.date) ? Color.white : Color.primary)
                            .clipShape(Circle())
                            .opacity(day.isInDisplayedMonth ? 1 : 0.36)
                    }
                    .buttonStyle(.plain)
                    .disabled(isBeforeMinimum(day.date))
                    .opacity(isBeforeMinimum(day.date) ? 0.28 : 1)
                }
            }
            .padding(.horizontal, 10)

            if !isAllDay {
                Rectangle().fill(separatorColor).frame(height: 1).padding(.top, 8)
                HStack(spacing: 8) {
                    Button { adjustTime(-15) } label: {
                        Image(systemName: "minus").frame(width: 30, height: 30)
                    }
                    .buttonStyle(WindowsSubtleButtonStyle())
                    Text(formattedTime)
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity)
                    Button { adjustTime(15) } label: {
                        Image(systemName: "plus").frame(width: 30, height: 30)
                    }
                    .buttonStyle(WindowsSubtleButtonStyle())
                }
                .padding(12)
            }
        }
        .frame(width: 304)
        .background(flyoutFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(separatorColor, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }

    private var calendar: Calendar {
        var calendar = ClockCalendarState.calendar
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .autoupdatingCurrent
        return calendar
    }

    private var days: [ClockCalendarDay] {
        ClockCalendarGrid.days(displayedMonth: displayedMonth, calendar: calendar)
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
    }

    private func moveMonth(_ offset: Int) {
        guard let month = calendar.date(byAdding: .month, value: offset, to: displayedMonth) else { return }
        displayedMonth = month
    }

    private func select(_ day: Date) {
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        let selected = calendar.date(
            bySettingHour: isAllDay ? 0 : components.hour ?? 0,
            minute: isAllDay ? 0 : components.minute ?? 0,
            second: isAllDay ? 0 : components.second ?? 0,
            of: day
        ) ?? day
        if let minimumDate, selected < calendar.startOfDay(for: minimumDate) { return }
        date = selected
        displayedMonth = calendar.dateInterval(of: .month, for: selected)?.start ?? displayedMonth
    }

    private func adjustTime(_ minutes: Int) {
        guard let adjusted = calendar.date(byAdding: .minute, value: minutes, to: date) else { return }
        if let minimumDate, adjusted < minimumDate {
            date = minimumDate
        } else {
            date = adjusted
        }
    }

    private func isSelected(_ day: Date) -> Bool {
        calendar.isDate(day, inSameDayAs: date)
    }

    private func isBeforeMinimum(_ day: Date) -> Bool {
        guard let minimumDate else { return false }
        return calendar.startOfDay(for: day) < calendar.startOfDay(for: minimumDate)
    }

    private var formattedTime: String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private var flyoutFill: Color {
        colorScheme == .dark ? Color(red: 0.125, green: 0.125, blue: 0.125) : Color(red: 0.98, green: 0.98, blue: 0.98)
    }

    private var separatorColor: Color {
        (colorScheme == .dark ? Color.white : Color.black).opacity(0.14)
    }
}

private struct WindowsConfirmationFlyout: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let confirmTitle: LocalizedStringKey
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 16, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(WindowsSubtleButtonStyle())
                Button(confirmTitle, action: onConfirm)
                    .buttonStyle(WindowsDangerButtonStyle())
            }
        }
        .padding(18)
        .frame(width: 292)
        .background(colorScheme == .dark ? Color(red: 0.125, green: 0.125, blue: 0.125) : .white)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke((colorScheme == .dark ? Color.white : Color.black).opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }
}

private struct WindowsSubtleButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill((colorScheme == .dark ? Color.white : Color.black).opacity(configuration.isPressed ? 0.16 : 0.08))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke((colorScheme == .dark ? Color.white : Color.black).opacity(0.12), lineWidth: 0.5)
            }
    }
}

private struct WindowsAccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 14)
            .frame(minHeight: 30)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(windowsAccent.opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.36))
            )
    }
}

private struct WindowsDangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(red: 0.77, green: 0.16, blue: 0.14).opacity(configuration.isPressed ? 0.78 : 1))
            )
    }
}

private struct WindowsListRowButtonStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill((colorScheme == .dark ? Color.white : Color.black).opacity(
                        configuration.isPressed ? 0.14 : (selected ? 0.09 : 0)
                    ))
            )
    }
}

private let windowsAccent = Color(red: 0.0, green: 0.47, blue: 0.83)
