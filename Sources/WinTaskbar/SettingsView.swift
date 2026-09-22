import AppKit
import Carbon
import SwiftUI
import UniformTypeIdentifiers

enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General"
    case appearance = "Appearance"
    case startMenu = "Start Menu"
    case taskbar = "Taskbar & Tray"
    case dateTime = "Date & time"
    case inputAdaptation = "Input Adaptation"
    case hotkeys = "Hotkeys"
    case shortcutMappings = "Shortcut Mappings"
    case about = "About"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .startMenu: "square.grid.2x2"
        case .taskbar: "dock.rectangle"
        case .dateTime: "clock"
        case .inputAdaptation: "keyboard.badge.ellipsis"
        case .hotkeys: "keyboard"
        case .shortcutMappings: "command"
        case .about: "info.circle"
        }
    }
}

@MainActor
final class SettingsNavigationState: ObservableObject {
    @Published var selectedPage: SettingsPage = .general
    @Published var isWindowVisible = false
}

struct SettingsPreviewTimelineSchedule: TimelineSchedule {
    let isVisible: Bool
    let interval: TimeInterval

    func entries(from startDate: Date, mode: Mode) -> AnySequence<Date> {
        guard isVisible else { return AnySequence([]) }
        return AnySequence(PeriodicTimelineSchedule(from: startDate, by: interval).entries(from: startDate, mode: mode))
    }
}

struct SettingsView: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var navigation: SettingsNavigationState
    @ObservedObject private var dockToggle = DockToggleService.shared
    @ObservedObject private var loginItem = LoginItemService.shared
    @ObservedObject private var globalHotkeys = GlobalHotkeysService.shared
    @ObservedObject private var karabinerIntegration = KarabinerIntegrationService.shared
    @ObservedObject private var mouseScrollIntegration = KarabinerMouseScrollService.shared
    @State private var showsDateTimeFormat = false
    @State private var editingAdditionalClockIndex: Int?
    @State private var additionalClockDraft = AdditionalClockConfiguration.defaults[0]
    @State private var identifyingKeyboard: KarabinerKeyboardDevice?

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsPage.allCases, selection: $navigation.selectedPage) { page in
                Label(LocalizedStringKey(page.rawValue), systemImage: page.symbol)
                    .tag(page)
            }
            .listStyle(.sidebar)
            .frame(width: 190)

            Divider()

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    if navigation.selectedPage == .dateTime, showsDateTimeFormat {
                        SettingsBackButton {
                            withAnimation(.easeInOut(duration: 0.24)) {
                                showsDateTimeFormat = false
                            }
                        }
                    }
                    Image(systemName: navigation.selectedPage.symbol)
                        .foregroundStyle(.secondary)
                    if navigation.selectedPage == .dateTime, showsDateTimeFormat {
                        Text("Date & time > Format")
                            .font(.title2.weight(.semibold))
                    } else {
                        Text(LocalizedStringKey(navigation.selectedPage.rawValue))
                            .font(.title2.weight(.semibold))
                    }
                    Spacer()
                }
                .padding(.horizontal, 22)
                .frame(height: 58)
                Divider()
                selectedPageContent
            }
        }
        .onAppear {
            loginItem.refresh()
            karabinerIntegration.refresh()
            mouseScrollIntegration.refresh()
        }
        .onChange(of: navigation.selectedPage) { _ in showsDateTimeFormat = false }
        .sheet(isPresented: Binding(
            get: { editingAdditionalClockIndex != nil },
            set: { if !$0 { editingAdditionalClockIndex = nil } }
        )) {
            AdditionalClockEditor(
                configuration: $additionalClockDraft,
                onSave: saveAdditionalClock,
                onCancel: { editingAdditionalClockIndex = nil }
            )
        }
        .sheet(item: $identifyingKeyboard) { keyboard in
            KeyboardIdentificationView(
                device: keyboard,
                activeMapping: karabinerIntegration.isEnabled
                    ? karabinerIntegration.mapping(for: keyboard)
                    : nil,
                windowsKeyMapping: preferences.windowsKeyMapping,
                onSave: { assignments in
                    karabinerIntegration.saveKeyboardMapping(
                        for: keyboard,
                        assignments: assignments,
                        windowsKeyMapping: preferences.windowsKeyMapping
                    )
                    identifyingKeyboard = nil
                },
                onCancel: { identifyingKeyboard = nil }
            )
        }
    }

    @ViewBuilder
    private var selectedPageContent: some View {
        switch navigation.selectedPage {
        case .general: settingsPage(general)
        case .appearance: settingsPage(taskbarFeatureContent(appearance))
        case .startMenu: settingsPage(taskbarFeatureContent(startMenu))
        case .taskbar: settingsPage(taskbarFeatureContent(features))
        case .dateTime:
            if preferences.taskbarEnabled {
                dateTimePages
            } else {
                settingsPage(taskbarFeatureContent(dateTime))
            }
        case .inputAdaptation: settingsPage(inputAdaptationSettings)
        case .hotkeys: settingsPage(hotkeySettings)
        case .shortcutMappings: settingsPage(taskbarFeatureContent(shortcutMappings))
        case .about: settingsPage(about)
        }
    }

    private var dateTimePages: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                settingsPage(dateTime)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .offset(x: showsDateTimeFormat ? -geometry.size.width : 0)
                    .allowsHitTesting(!showsDateTimeFormat)
                settingsPage(dateTimeFormat)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .offset(x: showsDateTimeFormat ? 0 : geometry.size.width)
                    .allowsHitTesting(showsDateTimeFormat)
            }
            .clipped()
            .animation(.easeInOut(duration: 0.24), value: showsDateTimeFormat)
        }
    }

    private func settingsPage<Content: View>(_ content: Content) -> some View {
        ScrollView {
            content
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func taskbarFeatureContent<Content: View>(_ content: Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if !preferences.taskbarEnabled {
                featureDisabledNotice("Turn on Taskbar in General to change these settings.")
            }
            content
                .disabled(!preferences.taskbarEnabled)
                .opacity(preferences.taskbarEnabled ? 1 : 0.5)
        }
    }

    private func featureDisabledNotice(_ message: LocalizedStringKey) -> some View {
        Label(message, systemImage: "lock.fill")
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("Features") {
                Toggle("AllTab", isOn: $preferences.altTabSwitcherEnabled)
                Text("Windows-style window switching. Its modifier can be configured in Hotkeys.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                Toggle("Taskbar", isOn: $preferences.taskbarEnabled)
                Text("Windows-style taskbar, Start menu, system tray, and taskbar shortcuts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SettingsSection("Startup") {
                Toggle("Launch at login", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { enabled in
                        loginItem.setEnabled(enabled)
                        preferences.launchAtLogin = enabled
                    }
                ))
            }
        }
    }

    private var appearance: some View {
        SettingsSection("Visual style") {
            Picker("Theme", selection: $preferences.theme) {
                ForEach(AppTheme.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("Show running indicators", isOn: $preferences.showRunningIndicators)
            Picker("Active app indicator", selection: $preferences.activeIndicator) {
                ForEach(ActiveIndicatorStyle.allCases) { Text($0.rawValue).tag($0) }
            }
            .disabled(!preferences.showRunningIndicators)
            Picker("Highlight style", selection: $preferences.highlightStyle) {
                ForEach(HighlightStyle.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("Transparency", isOn: $preferences.transparencyEnabled)
            if preferences.transparencyEnabled {
                Slider(value: $preferences.panelOpacity, in: 0.25...1, step: 0.01) {
                    Text("Panel opacity")
                }
                Slider(value: $preferences.panelBlurRadius, in: 0...30, step: 1) {
                    Text("Blur")
                }
            }
            panelColor
        }
    }

    private var panelColor: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Panel color")
                Spacer()
                Button(preferences.panelTintHex.isEmpty ? "Automatic" : preferences.panelTintHex.uppercased()) {
                    preferences.panelTintHex = ""
                }
                .buttonStyle(.borderless)
                .disabled(preferences.panelTintHex.isEmpty)
            }
            PanelTintPicker(hex: $preferences.panelTintHex)
            HStack(spacing: 9) {
                tintSwatch(hex: "", isNone: true)
                ForEach(["#1F2937", "#334155", "#3B82F6", "#7C3AED", "#BE123C", "#15803D"], id: \.self) {
                    tintSwatch(hex: $0, isNone: false)
                }
            }
        }
        .padding(.top, 2)
    }

    private func tintSwatch(hex: String, isNone: Bool) -> some View {
        Button {
            preferences.panelTintHex = hex
        } label: {
            ZStack {
                Circle().fill(isNone ? Color.clear : Color(hex: hex) ?? .clear)
                if isNone {
                    Circle().stroke(Color.secondary, lineWidth: 1)
                    Rectangle().fill(Color.red).frame(width: 2, height: 20).rotationEffect(.degrees(45))
                }
                if preferences.panelTintHex.caseInsensitiveCompare(hex) == .orderedSame {
                    Circle().stroke(Color.accentColor, lineWidth: 2).padding(-3)
                }
            }
            .frame(width: 21, height: 21)
        }
        .buttonStyle(.plain)
        .help(isNone ? "Clear color" : hex)
    }

    private var startMenu: some View {
        SettingsSection("Behavior") {
            Picker("Windows style", selection: $preferences.menuWindowStyle) {
                ForEach(HighlightStyle.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Window height", selection: $preferences.menuHeightMode) {
                ForEach(MenuHeightMode.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Search field", selection: $preferences.searchFieldPosition) {
                ForEach(SearchFieldPosition.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Actions panel", selection: $preferences.menuActionsSide) {
                ForEach(MenuActionsSide.allCases) { Text($0.rawValue).tag($0) }
            }
        }
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsDisclosureSection(
                "Taskbar behaviors",
                subtitle: "Taskbar position, badging, automatically hide, and multiple displays"
            ) {
                Picker("Taskbar position", selection: $preferences.position) {
                    ForEach(TaskbarPosition.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Automatically hide the taskbar", isOn: $preferences.autoHideTaskbar)
                Toggle("Show badges on taskbar apps", isOn: $preferences.showBadgesOnTaskbarApps)
                Toggle("Show flashing on taskbar apps", isOn: $preferences.showFlashingOnTaskbarApps)
                Picker("Show taskbar on", selection: $preferences.displayMode) {
                    ForEach(DisplayMode.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Window Previews", isOn: $preferences.windowPreviewsEnabled)
                Toggle(
                    "Disable minimize animation during remote sessions",
                    isOn: $preferences.disableMinimizeAnimationDuringRemoteSession
                )
                Text("Detects active macOS Screen Sharing and Remote Management connections.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Show Desktop", isOn: $preferences.showDesktopEnabled)
                Toggle("Show app labels under icons", isOn: $preferences.showAppLabels)
                Toggle("Show Finder in running apps", isOn: $preferences.showFinder)
                Toggle("Show apps with no open windows", isOn: $preferences.showWindowlessApps)
                Text("Pinned apps are always shown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SettingsSection("Taskbar layout") {
                Slider(
                    value: $preferences.barHeight,
                    in: 40...72,
                    step: 1,
                    label: { Text("Height") },
                    minimumValueLabel: { Text("40").foregroundStyle(.secondary) },
                    maximumValueLabel: { Text("72").foregroundStyle(.secondary) }
                )
                Slider(
                    value: $preferences.iconScale,
                    in: 0.6...1.2,
                    label: { Text("Icon size") },
                    minimumValueLabel: { Image(systemName: "smallcircle.filled.circle") },
                    maximumValueLabel: { Image(systemName: "largecircle.fill.circle") }
                )
                Slider(
                    value: $preferences.iconPadding,
                    in: 0...0.2,
                    label: { Text("Icon padding") },
                    minimumValueLabel: { Image(systemName: "square.fill") },
                    maximumValueLabel: { Image(systemName: "square.dashed") }
                )
                Picker("Menu button", selection: $preferences.menuButtonPlacement) {
                    ForEach(MenuButtonPlacement.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Start button label", selection: $preferences.startButtonLabel) {
                    ForEach(["", "Start", "Menu"], id: \.self) { value in
                        Text(value.isEmpty ? "None" : value).tag(value)
                    }
                }
            }
            SettingsSection("Taskbar menu") {
                Toggle("Recent items", isOn: $preferences.showRecentInMenu)
                Toggle("Shortcuts", isOn: $preferences.showShortcutsInMenu)
            }
            SettingsSection("System Tray") {
                Toggle("Show third-party tray icons", isOn: $preferences.externalStatusItemsEnabled)
                Toggle("Battery", isOn: $preferences.trayBatteryEnabled)
                Toggle("Input source", isOn: $preferences.trayInputSourceEnabled)
                Toggle("Volume", isOn: $preferences.trayVolumeEnabled)
                Toggle("Wi-Fi", isOn: $preferences.trayWifiEnabled)
            }
        }
    }

    private var dateTime: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("Date & time") {
                TimelineView(SettingsPreviewTimelineSchedule(
                    isVisible: navigation.isWindowVisible,
                    interval: preferences.trayClockShowsSeconds ? 1 : 30
                )) { context in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(DateTimeFormatter.string(
                            from: context.date,
                            pattern: preferences.trayClockShowsSeconds
                                ? preferences.dateTimeLongTimePattern
                                : preferences.dateTimeShortTimePattern,
                            configuration: preferences.dateTimeFormatConfiguration
                        ))
                        .font(.system(size: 28, weight: .semibold))
                        .monospacedDigit()
                        Text(DateTimeFormatter.longDateString(
                            from: context.date,
                            configuration: preferences.dateTimeFormatConfiguration
                        ))
                        .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Time zone", value: AdditionalClockPresentation.timeZoneLabel(
                    identifier: TimeZone.autoupdatingCurrent.identifier
                ))
                LabeledContent("Region", value: currentRegionName)
                Button("Open macOS Date & Time Settings") { openSystemDateTimeSettings() }
            }

            SettingsSection("System tray clock") {
                Toggle("Show time and date in the system tray", isOn: $preferences.trayClockEnabled)
                Toggle(
                    "Show seconds in system tray clock (uses more power)",
                    isOn: $preferences.trayClockShowsSeconds
                )
                .disabled(!preferences.trayClockEnabled)
                ForEach(Array(preferences.additionalClocks.enumerated()), id: \.element.id) { index, clock in
                    Divider()
                    additionalClockRow(clock, index: index)
                }
            }

            Button {
                withAnimation(.easeInOut(duration: 0.24)) {
                    showsDateTimeFormat = true
                }
            } label: {
                HStack {
                    Label("Change the date and time format", systemImage: "globe")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(14)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var dateTimeFormat: some View {
        SettingsSection("Format") {
            Picker("Calendar", selection: $preferences.dateTimeCalendarKind) {
                ForEach(DateTimeCalendarKind.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            Picker("First day of week", selection: $preferences.dateTimeFirstDayOfWeek) {
                ForEach(DateTimeFirstDayOfWeek.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            Picker("Short date", selection: $preferences.dateTimeShortDatePattern) {
                ForEach(DateTimeFormatCatalog.shortDatePatterns, id: \.self) { pattern in
                    Text(formatExample(pattern)).tag(pattern)
                }
            }
            Picker("Long date", selection: $preferences.dateTimeLongDateStyle) {
                ForEach(DateTimeLongDateStyle.allCases) { style in
                    Text(longDateExample(style)).tag(style)
                }
            }
            if preferences.dateTimeLongDateStyle == .custom {
                LabeledContent("Custom format") {
                    TextField("yyyy年M月d日", text: $preferences.dateTimeCustomLongDatePattern)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
                Toggle("Include lunar date", isOn: $preferences.dateTimeCustomLongDateIncludesLunar)
                Text("Use Unicode date format symbols, for example yyyy.MM.dd.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Picker("Short time", selection: $preferences.dateTimeShortTimePattern) {
                ForEach(DateTimeFormatCatalog.shortTimePatterns, id: \.self) { pattern in
                    Text(formatExample(pattern)).tag(pattern)
                }
            }
            Picker("Long time", selection: $preferences.dateTimeLongTimePattern) {
                ForEach(DateTimeFormatCatalog.longTimePatterns, id: \.self) { pattern in
                    Text(formatExample(pattern)).tag(pattern)
                }
            }
            LabeledContent("AM / PM symbol") {
                HStack(spacing: 8) {
                    TextField("AM", text: $preferences.dateTimeAMSymbol)
                    TextField("PM", text: $preferences.dateTimePMSymbol)
                }
                .textFieldStyle(.roundedBorder)
                .frame(width: 190)
            }
            Text("The dates and times above are provided as format examples.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func additionalClockRow(_ clock: AdditionalClockConfiguration, index: Int) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(
                    format: NSLocalizedString("Additional clock %ld", comment: "Additional clock settings slot"),
                    clock.slot
                ))
                Text(additionalClockDetail(clock))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Change") { editAdditionalClock(index: index) }
            if clock.isEnabled {
                Menu {
                    Button("Remove", role: .destructive) { removeAdditionalClock(index: index) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)
            }
        }
    }

    private func additionalClockDetail(_ clock: AdditionalClockConfiguration) -> String {
        guard clock.isEnabled else { return NSLocalizedString("Not set", comment: "Additional clock is disabled") }
        return "\(AdditionalClockPresentation.timeZoneLabel(identifier: clock.timeZoneIdentifier)) (\(clock.displayName))"
    }

    private func editAdditionalClock(index: Int) {
        guard preferences.additionalClocks.indices.contains(index) else { return }
        additionalClockDraft = preferences.additionalClocks[index]
        editingAdditionalClockIndex = index
    }

    private func saveAdditionalClock() {
        guard let index = editingAdditionalClockIndex,
              preferences.additionalClocks.indices.contains(index) else { return }
        additionalClockDraft.displayName = additionalClockDraft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        additionalClockDraft.isEnabled = true
        preferences.additionalClocks[index] = additionalClockDraft
        editingAdditionalClockIndex = nil
    }

    private func removeAdditionalClock(index: Int) {
        guard preferences.additionalClocks.indices.contains(index) else { return }
        let slot = preferences.additionalClocks[index].slot
        preferences.additionalClocks[index] = AdditionalClockConfiguration(
            slot: slot,
            isEnabled: false,
            timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier,
            displayName: ""
        )
    }

    private func formatExample(_ pattern: String) -> String {
        DateTimeFormatter.string(
            from: DateTimeFormatCatalog.exampleDate,
            pattern: pattern,
            configuration: preferences.dateTimeFormatConfiguration,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
    }

    private func longDateExample(_ style: DateTimeLongDateStyle) -> String {
        guard style != .custom else {
            return NSLocalizedString("Custom", comment: "Custom date format option")
        }
        let current = preferences.dateTimeFormatConfiguration
        let exampleConfiguration = DateTimeFormatConfiguration(
            calendarKind: current.calendarKind,
            firstDayOfWeek: current.firstDayOfWeek,
            shortDatePattern: current.shortDatePattern,
            longDatePattern: style.pattern!,
            longDateIncludesLunar: style.includesLunar,
            shortTimePattern: current.shortTimePattern,
            longTimePattern: current.longTimePattern,
            amSymbol: current.amSymbol,
            pmSymbol: current.pmSymbol
        )
        return DateTimeFormatter.longDateString(
            from: DateTimeFormatCatalog.exampleDate,
            configuration: exampleConfiguration,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
    }

    private var currentRegionName: String {
        let locale = Locale.autoupdatingCurrent
        guard let regionCode = locale.region?.identifier else { return "Automatic" }
        return locale.localizedString(forRegionCode: regionCode) ?? regionCode
    }

    private func openSystemDateTimeSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Date-Time-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    private var inputAdaptationSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("Windows keyboard mode") {
                HStack(spacing: 8) {
                    Image(systemName: karabinerIntegration.isEnabled
                        ? "checkmark.circle.fill"
                        : (karabinerIntegration.isAvailable ? "circle" : "exclamationmark.triangle.fill"))
                        .foregroundStyle(karabinerIntegration.isEnabled
                            ? Color.green
                            : (karabinerIntegration.isAvailable ? Color.secondary : Color.orange))
                    Text(karabinerStatusText)
                        .font(.callout.weight(.medium))
                    Spacer()
                    if let version = karabinerIntegration.version {
                        Text(version)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                    GridRow {
                        Text("Windows key").foregroundStyle(.secondary)
                        Text("macOS logical key").foregroundStyle(.secondary)
                    }
                    ForEach(KeyboardModifierRole.allCases) { role in
                        GridRow {
                            Text(role.title)
                            Text(role.localOutput(
                                for: .left,
                                windowsKeyMapping: preferences.windowsKeyMapping
                            ).displayLogicalModifier)
                        }
                    }
                }
                .font(.caption)

                Text("The four logical modifier keys stay consistent in every local app. Terminal and iTerm keep native Command shortcuts and shell Control shortcuts; Ctrl+Shift+T/N/W/C/V/F are also available as Windows Terminal-style aliases.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                HStack {
                    Text("Keyboards")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Button("Refresh keyboards") { karabinerIntegration.refresh() }
                        .controlSize(.small)
                }

                if karabinerIntegration.keyboards.isEmpty {
                    Text("No physical keyboards found.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 10) {
                        ForEach(karabinerIntegration.keyboards) { keyboard in
                            keyboardMappingCard(keyboard)
                        }
                    }
                }

                if !karabinerIntegration.isEnabled, karabinerIntegration.conflictCount > 0 {
                    Text("WinTaskbar will replace \(karabinerIntegration.conflictCount) conflicting Karabiner mappings. The complete current configuration is backed up first.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let error = karabinerIntegration.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                HStack {
                    if karabinerIntegration.isEnabled {
                        Button("Disable and restore previous configuration") {
                            karabinerIntegration.disable(preferences: preferences)
                        }
                    } else {
                        Button("Enable Windows keyboard mode") {
                            karabinerIntegration.enable(preferences: preferences)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!karabinerIntegration.isAvailable)
                    }
                    Button("Refresh") { karabinerIntegration.refresh() }
                    if !karabinerIntegration.isAvailable,
                       let url = URL(string: "https://karabiner-elements.pqrs.org") {
                        Link("Get Karabiner-Elements", destination: url)
                    }
                }
            }

            SettingsSection("Mouse scrolling") {
                Toggle(
                    "Trackpad natural, mouse standard",
                    isOn: Binding(
                        get: { mouseScrollIntegration.isEnabled },
                        set: { mouseScrollIntegration.setEnabled($0) }
                    )
                )
                .disabled(
                    !mouseScrollIntegration.isAvailable
                        || (mouseScrollIntegration.mice.isEmpty && !mouseScrollIntegration.isEnabled)
                )

                Text("Keeps macOS Natural scrolling on for trackpads and reverses only the vertical wheel on connected external mice through Karabiner-Elements.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if mouseScrollIntegration.mice.isEmpty {
                    Text("No external mouse found.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(
                        String(
                            format: NSLocalizedString(
                                "%lld of %lld connected mice configured",
                                comment: "Karabiner mouse scroll configuration status"
                            ),
                            Int64(mouseScrollIntegration.configuredMouseCount),
                            Int64(mouseScrollIntegration.mice.count)
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if let error = mouseScrollIntegration.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                Button("Refresh mice") { mouseScrollIntegration.refresh() }
                    .controlSize(.small)
            }
        }
    }

    private var hotkeySettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !preferences.taskbarEnabled {
                featureDisabledNotice("Turn on Taskbar in General to configure Taskbar shortcuts.")
            }
            SettingsSection("Global shortcuts") {
                Toggle("Enable global shortcuts", isOn: $preferences.globalHotkeysEnabled)
                Text("Enabled mappings override matching macOS and application shortcuts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!preferences.taskbarEnabled)
            .opacity(preferences.taskbarEnabled ? 1 : 0.5)

            if !preferences.altTabSwitcherEnabled {
                featureDisabledNotice("Turn on AllTab in General to configure window switching.")
            }
            SettingsSection("AllTab window switcher") {
                Picker("AllTab modifier", selection: $preferences.altTabModifier) {
                    ForEach(AltTabModifier.allCases) { modifier in
                        Text(modifier.title).tag(modifier)
                    }
                }
                .disabled(karabinerIntegration.isEnabled)
                if let issue = globalHotkeys.altTabIssue,
                   preferences.altTabSwitcherEnabled {
                    Text(issue)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text("\(preferences.altTabModifier.shortcutLabel) cycles through open windows. Add Shift to move backward, then release the modifier to activate the selected window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if preferences.altTabModifier == .command {
                    Text("Command+Tab is normally reserved by macOS. WinTaskbar will report a conflict here if the system does not release it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!preferences.altTabSwitcherEnabled)
            .opacity(preferences.altTabSwitcherEnabled ? 1 : 0.5)

        }
    }

    private func keyboardMappingCard(_ keyboard: KarabinerKeyboardDevice) -> some View {
        let mapping = karabinerIntegration.mapping(for: keyboard)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(keyboard.name)
                        .font(.callout.weight(.medium))
                    Text(keyboard.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(mapping == nil ? "Not identified" : "Mapped")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(mapping == nil ? Color.orange : Color.green)
                Button(mapping == nil ? "Identify" : "Identify again") {
                    identifyingKeyboard = keyboard
                }
                .controlSize(.small)
                .disabled(!karabinerIntegration.isAvailable)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                GridRow {
                    Text("")
                    ForEach(KeyboardModifierRole.allCases) { role in
                        Text(role.title).foregroundStyle(.secondary)
                    }
                }
                ForEach(KeyboardModifierSide.allCases) { side in
                    GridRow {
                        Text(side.title).foregroundStyle(.secondary)
                        ForEach(KeyboardModifierRole.allCases) { role in
                            Text(mapping?.assignment(side: side, role: role)?.physicalKey.displayKeyboardKey ?? "—")
                                .monospaced()
                        }
                    }
                }
            }
            .font(.caption2)
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private var shortcutMappings: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("Windows key") {
                Picker("macOS logical key", selection: windowsKeyMappingBinding) {
                    ForEach(WindowsKeyMapping.selectableCases) { mapping in
                        Text(mapping.rawValue).tag(mapping)
                    }
                }
                .disabled(!preferences.globalHotkeysEnabled)
                Toggle("Press Windows key alone to open Start", isOn: $preferences.windowsKeyOpensStart)
                    .disabled(!preferences.globalHotkeysEnabled)
                if let issue = globalHotkeys.windowsKeyIssue,
                   preferences.globalHotkeysEnabled,
                   preferences.windowsKeyOpensStart {
                    Text(issue)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text("Default Windows shortcuts follow this setting. Shortcuts you record yourself keep their exact modifiers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsSection("Built-in Windows shortcuts") {
                ForEach(Array(preferences.globalShortcutConfigurations.enumerated()), id: \.element.id) { index, configuration in
                    GlobalShortcutRow(
                        configuration: configurationBinding(id: configuration.id),
                        windowsKeyMapping: preferences.windowsKeyMapping,
                        globalEnabled: preferences.globalHotkeysEnabled,
                        registrationIssue: globalHotkeys.registrationIssues[configuration.id],
                        onChooseApplication: {
                            chooseApplication(for: configurationBinding(id: configuration.id).applicationTarget)
                        },
                        onResetTrigger: { resetTrigger(for: configuration.id) }
                    )
                    if index < preferences.globalShortcutConfigurations.count - 1 {
                        Divider()
                    }
                }
            }

            SettingsSection("Custom bindings") {
                if preferences.customShortcutConfigurations.isEmpty {
                    Text("Add a binding to assign any key combination to an action.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(preferences.customShortcutConfigurations.enumerated()), id: \.element.id) { index, configuration in
                    CustomShortcutRow(
                        configuration: customConfigurationBinding(id: configuration.id),
                        globalEnabled: preferences.globalHotkeysEnabled,
                        registrationIssue: globalHotkeys.registrationIssues[configuration.id],
                        onChooseApplication: {
                            chooseApplication(for: customConfigurationBinding(id: configuration.id).applicationTarget)
                        },
                        onDelete: { removeCustomConfiguration(id: configuration.id) }
                    )
                    if index < preferences.customShortcutConfigurations.count - 1 {
                        Divider()
                    }
                }
                Button {
                    preferences.customShortcutConfigurations.append(.makeNew())
                } label: {
                    Label("Add Custom Binding", systemImage: "plus")
                }
            }
        }
    }

    private var karabinerStatusText: LocalizedStringKey {
        if karabinerIntegration.isEnabled { return "Enabled through Karabiner-Elements" }
        if karabinerIntegration.isAvailable { return "Ready to configure Karabiner-Elements" }
        return "Karabiner-Elements is required"
    }

    private var windowsKeyMappingBinding: Binding<WindowsKeyMapping> {
        Binding(
            get: { preferences.windowsKeyMapping },
            set: { mapping in
                guard karabinerIntegration.updateWindowsKeyMapping(mapping) else { return }
                preferences.windowsKeyMapping = mapping
            }
        )
    }

    private var about: some View {
        SettingsSection("Application") {
            LabeledContent("Version", value: AppMetadata.version)
            Button("Check for Updates") {
                if let url = URL(string: "https://github.com/tinymins/WinTaskbar-for-macOS/releases") {
                    NSWorkspace.shared.open(url)
                }
            }
            HStack {
                Button(dockToggle.isDockHidden ? "Restore system Dock" : "Hide system Dock") {
                    dockToggle.isDockHidden ? dockToggle.restoreDock() : dockToggle.hideDock()
                }
                .disabled(!preferences.taskbarEnabled)
                Button("Exit", role: .destructive) {
                    confirmExit()
                }
            }
            if !preferences.taskbarEnabled {
                Text("Turn on Taskbar in General to change the system Dock.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func confirmExit() {
        let alert = NSAlert()
        alert.messageText = "Exit WinTaskbar?"
        alert.informativeText = "WinTaskbar will exit and restore the system Dock."
        alert.alertStyle = .warning

        let exitButton = alert.addButton(withTitle: "Exit")
        exitButton.hasDestructiveAction = true
        let cancelButton = alert.addButton(withTitle: "Cancel")
        cancelButton.keyEquivalent = "\u{1b}"

        alert.window.level = .modalPanel
        if let screen = NSApp.keyWindow?.screen ?? NSScreen.main {
            let alertSize = alert.window.frame.size
            alert.window.setFrameOrigin(NSPoint(
                x: screen.visibleFrame.midX - alertSize.width / 2,
                y: screen.visibleFrame.midY - alertSize.height / 2
            ))
        }

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
    }

    private func configurationBinding(id: String) -> Binding<GlobalShortcutConfiguration> {
        Binding(
            get: {
                preferences.globalShortcutConfigurations.first { $0.id == id }
                    ?? GlobalShortcutCatalog.defaults(
                        legacyShortcuts: GlobalShortcutCatalog.defaultLegacyShortcuts
                    )[0]
            },
            set: { updated in
                guard let index = preferences.globalShortcutConfigurations.firstIndex(where: { $0.id == id }) else { return }
                preferences.globalShortcutConfigurations[index] = updated
            }
        )
    }

    private func customConfigurationBinding(id: String) -> Binding<CustomShortcutConfiguration> {
        Binding(
            get: {
                preferences.customShortcutConfigurations.first { $0.id == id }
                    ?? .makeNew()
            },
            set: { updated in
                guard let index = preferences.customShortcutConfigurations.firstIndex(where: { $0.id == id }) else { return }
                preferences.customShortcutConfigurations[index] = updated
            }
        )
    }

    private func chooseApplication(for target: Binding<ShortcutApplicationTarget?>) {
        let panel = NSOpenPanel()
        panel.title = "Choose Application"
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK,
              let url = panel.url,
              let applicationTarget = ShortcutApplicationTarget(url: url) else { return }
        target.wrappedValue = applicationTarget
    }

    private func removeCustomConfiguration(id: String) {
        preferences.customShortcutConfigurations.removeAll { $0.id == id }
    }

    private func resetTrigger(for id: String) {
        guard let index = preferences.globalShortcutConfigurations.firstIndex(where: { $0.id == id }),
              let defaultConfiguration = GlobalShortcutCatalog.defaultConfiguration(
                id: id,
                legacyShortcuts: GlobalShortcutCatalog.defaultLegacyShortcuts
              ) else { return }
        preferences.globalShortcutConfigurations[index].shortcut = defaultConfiguration.shortcut
        preferences.globalShortcutConfigurations[index].usesWindowsKey = defaultConfiguration.usesWindowsKey
    }
}

private struct KeyboardIdentificationStep: Identifiable {
    let side: KeyboardModifierSide
    let role: KeyboardModifierRole

    var id: String { "\(side.rawValue).\(role.rawValue)" }

    static let all = KeyboardModifierSide.allCases.flatMap { side in
        KeyboardModifierRole.allCases.map { role in
            KeyboardIdentificationStep(side: side, role: role)
        }
    }
}

private struct KeyboardIdentificationView: View {
    let device: KarabinerKeyboardDevice
    let activeMapping: KeyboardMappingProfile?
    let windowsKeyMapping: WindowsKeyMapping
    let onSave: ([KeyboardModifierAssignment]) -> Void
    let onCancel: () -> Void

    @State private var stepIndex = 0
    @State private var assignments: [KeyboardModifierAssignment] = []
    @State private var captureError: String?
    @State private var isReviewing = false
    @State private var activeKeys: Set<String> = []
    @State private var captureOwner = UUID()

    private var step: KeyboardIdentificationStep {
        KeyboardIdentificationStep.all[min(stepIndex, KeyboardIdentificationStep.all.count - 1)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "keyboard.badge.ellipsis")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Identify keyboard")
                        .font(.title2.weight(.semibold))
                    Text(device.name)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if isReviewing {
                Text("Review the detected layout before applying it.")
                    .font(.callout)
                mappingGrid
            } else {
                ProgressView(
                    value: Double(stepIndex + 1),
                    total: Double(KeyboardIdentificationStep.all.count)
                )
                Text(
                    String(
                        format: NSLocalizedString(
                            "Press the key you want to use as %@ %@.",
                            comment: "Keyboard identification prompt"
                        ),
                        step.side.title,
                        step.role.title
                    )
                )
                .font(.title3.weight(.medium))
                Text("Use this keyboard and press only one modifier key. Release it before continuing.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if step.role == .function {
                    Text("This keyboard may not have an Fn key. You can skip this step.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let captureError {
                    Text(captureError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                mappingGrid
            }

            Spacer()

            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button("Back", action: moveBack)
                    .disabled(stepIndex == 0 && !isReviewing)
                if isReviewing {
                    Button("Apply Mapping") { onSave(orderedAssignments) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Skip", action: skipStep)
                }
            }
        }
        .padding(22)
        .frame(width: 560, height: 430)
        .onAppear(perform: startMonitoring)
        .onDisappear(perform: stopMonitoring)
    }

    private var mappingGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
            GridRow {
                Text("")
                ForEach(KeyboardModifierRole.allCases) { role in
                    Text(role.title).foregroundStyle(.secondary)
                }
            }
            ForEach(KeyboardModifierSide.allCases) { side in
                GridRow {
                    Text(side.title).foregroundStyle(.secondary)
                    ForEach(KeyboardModifierRole.allCases) { role in
                        Text(assignment(side: side, role: role)?.physicalKey.displayKeyboardKey ?? "—")
                            .monospaced()
                    }
                }
            }
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private var orderedAssignments: [KeyboardModifierAssignment] {
        KeyboardIdentificationStep.all.compactMap { step in
            assignment(side: step.side, role: step.role)
        }
    }

    private func assignment(
        side: KeyboardModifierSide,
        role: KeyboardModifierRole
    ) -> KeyboardModifierAssignment? {
        assignments.first { $0.side == side && $0.role == role }
    }

    private func startMonitoring() {
        let installed = GlobalHotkeysService.shared.beginKeyboardIdentification(owner: captureOwner) { keyCode, flags in
            handle(keyCode: keyCode, flags: flags)
        }
        if !installed {
            captureError = NSLocalizedString(
                "Keyboard input could not be intercepted. Allow Input Monitoring for WinTaskbar, then try again.",
                comment: "Keyboard identification input monitoring error"
            )
        }
    }

    private func stopMonitoring() {
        GlobalHotkeysService.shared.endKeyboardIdentification(owner: captureOwner)
    }

    private func handle(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        guard !isReviewing,
              let logicalKey = Self.karabinerKey(for: keyCode) else { return }
        if !Self.isPressed(logicalKey, flags: flags) {
            activeKeys.remove(logicalKey)
            return
        }
        guard activeKeys.insert(logicalKey).inserted else { return }

        let physicalKey = activeMapping?.physicalKey(
            forLogicalKey: logicalKey,
            windowsKeyMapping: windowsKeyMapping
        ) ?? logicalKey
        if let detectedSide = Self.side(of: physicalKey),
           detectedSide != step.side {
            captureError = String(
                format: NSLocalizedString(
                    "That is a %@ key. Press a key on the %@ side.",
                    comment: "Keyboard identification side mismatch"
                ),
                detectedSide.title.lowercased(),
                step.side.title.lowercased()
            )
            return
        }
        if assignments.contains(where: { $0.physicalKey == physicalKey && $0.id != step.id }) {
            captureError = NSLocalizedString(
                "That key is already assigned. Press a different key or go back.",
                comment: "Keyboard identification duplicate"
            )
            return
        }

        assignments.removeAll { $0.id == step.id }
        assignments.append(KeyboardModifierAssignment(
            side: step.side,
            role: step.role,
            physicalKey: physicalKey
        ))
        captureError = nil
        advance()
    }

    private func skipStep() {
        assignments.removeAll { $0.id == step.id }
        captureError = nil
        advance()
    }

    private func advance() {
        if stepIndex + 1 == KeyboardIdentificationStep.all.count {
            isReviewing = true
        } else {
            stepIndex += 1
        }
    }

    private func moveBack() {
        captureError = nil
        if isReviewing {
            isReviewing = false
            stepIndex = KeyboardIdentificationStep.all.count - 1
        } else if stepIndex > 0 {
            stepIndex -= 1
        }
    }

    private static func karabinerKey(for keyCode: UInt16) -> String? {
        switch keyCode {
        case 54: "right_command"
        case 55: "left_command"
        case 58: "left_option"
        case 59: "left_control"
        case 61: "right_option"
        case 62: "right_control"
        case 63: "fn"
        default: nil
        }
    }

    private static func isPressed(_ key: String, flags: NSEvent.ModifierFlags) -> Bool {
        switch key {
        case "left_command", "right_command": flags.contains(.command)
        case "left_option", "right_option": flags.contains(.option)
        case "left_control", "right_control": flags.contains(.control)
        case "fn": flags.contains(.function)
        default: false
        }
    }

    private static func side(of key: String) -> KeyboardModifierSide? {
        if key.hasPrefix("left_") { return .left }
        if key.hasPrefix("right_") { return .right }
        return nil
    }
}

private extension String {
    var displayLogicalModifier: String {
        switch self {
        case "fn": NSLocalizedString("Fn / Globe", comment: "Keyboard logical modifier")
        case "left_control", "right_control": NSLocalizedString("Control", comment: "Keyboard logical modifier")
        case "left_option", "right_option": NSLocalizedString("Option", comment: "Keyboard logical modifier")
        case "left_command", "right_command": NSLocalizedString("Command", comment: "Keyboard logical modifier")
        default: self
        }
    }

    var displayKeyboardKey: String {
        switch self {
        case "fn": NSLocalizedString("Fn / Globe", comment: "Keyboard key")
        case "left_control": NSLocalizedString("Left Control", comment: "Keyboard key")
        case "right_control": NSLocalizedString("Right Control", comment: "Keyboard key")
        case "left_option": NSLocalizedString("Left Option", comment: "Keyboard key")
        case "right_option": NSLocalizedString("Right Option", comment: "Keyboard key")
        case "left_command": NSLocalizedString("Left Command", comment: "Keyboard key")
        case "right_command": NSLocalizedString("Right Command", comment: "Keyboard key")
        default: self
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).padding(.horizontal, 10)
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

private struct SettingsDisclosureSection<Content: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    @ViewBuilder let content: Content
    @State private var isExpanded = true

    init(
        _ title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 0 : 180))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .padding(14)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                VStack(alignment: .leading, spacing: 10) { content }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct AdditionalClockEditor: View {
    @Binding var configuration: AdditionalClockConfiguration
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(String(
                format: NSLocalizedString("Additional clock %ld", comment: "Additional clock editor slot"),
                configuration.slot
            ))
                .font(.title2.weight(.semibold))
            Text("Additional clock can display the time in other time zones. You can view it by clicking or hovering over the taskbar clock.")
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Time zone")
                Picker("Time zone", selection: $configuration.timeZoneIdentifier) {
                    ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { identifier in
                        Text(AdditionalClockPresentation.timeZoneLabel(identifier: identifier)).tag(identifier)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)

                Text("Display name")
                TextField("Display name", text: $configuration.displayName)
                    .textFieldStyle(.roundedBorder)
            }

            Divider()

            HStack {
                Button("Change") { onSave() }
                    .buttonStyle(.borderedProminent)
                    .disabled(configuration.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") { onCancel() }
                Spacer()
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

private struct GlobalShortcutRow: View {
    @Binding var configuration: GlobalShortcutConfiguration
    let windowsKeyMapping: WindowsKeyMapping
    let globalEnabled: Bool
    let registrationIssue: String?
    let onChooseApplication: () -> Void
    let onResetTrigger: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Toggle("", isOn: $configuration.isEnabled)
                    .labelsHidden()
                VStack(alignment: .leading, spacing: 2) {
                    Text(configuration.title)
                    Text(configuration.windowsShortcutLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                GlobalHotkeyRecorder(
                    displayValue: configuration.displayValue(mapping: windowsKeyMapping),
                    resetTitle: "Restore default shortcut",
                    canReset: !GlobalShortcutCatalog.usesDefaultTrigger(configuration),
                    onCapture: { shortcut in
                        configuration.shortcut = shortcut
                        configuration.usesWindowsKey = false
                    },
                    onResetTrigger: onResetTrigger
                )
            }

            if configuration.action.supportsApplicationTarget || visibleIssue != nil {
                HStack(spacing: 8) {
                    if configuration.action.supportsApplicationTarget {
                        Text("Application")
                            .foregroundStyle(.secondary)
                        Button(applicationTargetTitle, action: onChooseApplication)
                            .contextMenu {
                                if configuration.applicationTarget != nil {
                                    Button(configuration.action.defaultApplicationName == nil ? "Clear Application" : "Use Default") {
                                        configuration.applicationTarget = nil
                                    }
                                }
                            }
                    }
                    Spacer()
                    if let visibleIssue {
                        Label(visibleIssue, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.leading, 30)
            }
        }
        .opacity(globalEnabled ? 1 : 0.65)
    }

    private var visibleIssue: String? {
        guard globalEnabled, configuration.isEnabled else { return nil }
        return registrationIssue
    }

    private var applicationTargetTitle: String {
        configuration.applicationTarget?.name
            ?? configuration.action.defaultApplicationName
            ?? "Choose Application…"
    }
}

private struct CustomShortcutRow: View {
    @Binding var configuration: CustomShortcutConfiguration
    let globalEnabled: Bool
    let registrationIssue: String?
    let onChooseApplication: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Toggle("", isOn: $configuration.isEnabled)
                    .labelsHidden()
                Text("Custom binding")
                Spacer()
                GlobalHotkeyRecorder(
                    displayValue: configuration.shortcut?.displayValue ?? "Set shortcut",
                    resetTitle: "Clear shortcut",
                    canReset: configuration.shortcut != nil,
                    onCapture: { configuration.shortcut = $0 },
                    onResetTrigger: { configuration.shortcut = nil }
                )
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete custom binding")
            }

            HStack(spacing: 8) {
                Picker("Action", selection: actionBinding) {
                    ForEach(GlobalShortcutAction.allCases) { action in
                        Text(action.title).tag(action)
                    }
                }
                .frame(maxWidth: 330)

                if configuration.action.supportsApplicationTarget {
                    Button("Extra: \(applicationTargetTitle)", action: onChooseApplication)
                        .contextMenu {
                            if configuration.applicationTarget != nil {
                                Button(configuration.action.defaultApplicationName == nil ? "Clear Application" : "Use Default") {
                                    configuration.applicationTarget = nil
                                }
                            }
                        }
                }
                if configuration.action == .launchPinned {
                    Picker("Extra", selection: pinnedIndexBinding) {
                        ForEach(0..<9, id: \.self) { index in
                            Text("Pinned app #\(index + 1)").tag(index)
                        }
                    }
                    .frame(width: 180)
                }
                Spacer()
            }
            .padding(.leading, 30)

            if let visibleIssue {
                Label(visibleIssue, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, 30)
            }
        }
        .opacity(globalEnabled ? 1 : 0.65)
    }

    private var actionBinding: Binding<GlobalShortcutAction> {
        Binding(
            get: { configuration.action },
            set: { action in
                configuration.action = action
                if !action.supportsApplicationTarget {
                    configuration.applicationTarget = nil
                }
                if action == .launchPinned, configuration.pinnedIndex == nil {
                    configuration.pinnedIndex = 0
                } else if action != .launchPinned {
                    configuration.pinnedIndex = nil
                }
            }
        )
    }

    private var pinnedIndexBinding: Binding<Int> {
        Binding(
            get: { configuration.pinnedIndex ?? 0 },
            set: { configuration.pinnedIndex = $0 }
        )
    }

    private var visibleIssue: String? {
        guard globalEnabled, configuration.isEnabled else { return nil }
        if configuration.shortcut == nil { return "Set a shortcut" }
        return registrationIssue
    }

    private var applicationTargetTitle: String {
        configuration.applicationTarget?.name
            ?? configuration.action.defaultApplicationName
            ?? "Choose Application…"
    }
}

private struct GlobalHotkeyRecorder: View {
    let displayValue: String
    let resetTitle: String
    let canReset: Bool
    let onCapture: (HotkeyShortcut) -> Void
    let onResetTrigger: () -> Void
    @ObservedObject private var globalHotkeys = GlobalHotkeysService.shared
    @State private var captureOwner = UUID()
    @State private var isRecording = false

    var body: some View {
        HStack(spacing: 5) {
            Button(isRecording ? "Type shortcut" : displayValue, action: beginRecording)
                .font(.system(.body, design: .monospaced))
                .contextMenu {
                    Button(resetTitle, action: onResetTrigger)
                        .disabled(!canReset)
                }
            Button(action: onResetTrigger) {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .disabled(!canReset || isRecording)
            .help(resetTitle)
        }
        .onDisappear {
            if isRecording {
                globalHotkeys.cancelShortcutCapture(owner: captureOwner)
            }
        }
    }

    private func beginRecording() {
        isRecording = true
        globalHotkeys.beginShortcutCapture(owner: captureOwner) { captured in
            if let captured { onCapture(captured) }
            isRecording = false
        }
    }
}

private struct PanelTintPicker: View {
    @Binding var hex: String

    private var components: HSB {
        HSB(hex: hex) ?? HSB(hue: 0.58, saturation: 0.55, brightness: 0.65)
    }

    var body: some View {
        VStack(spacing: 7) {
            GradientSlider(value: binding(\.hue), gradient: Self.hueGradient)
            GradientSlider(
                value: binding(\.saturation),
                gradient: Gradient(colors: [.white, color(hue: components.hue, saturation: 1, brightness: components.brightness)])
            )
            GradientSlider(
                value: binding(\.brightness),
                gradient: Gradient(colors: [.black, color(hue: components.hue, saturation: components.saturation, brightness: 1)])
            )
        }
    }

    private func binding(_ keyPath: WritableKeyPath<HSB, Double>) -> Binding<Double> {
        Binding(
            get: { components[keyPath: keyPath] },
            set: { value in
                var updated = components
                updated[keyPath: keyPath] = value
                hex = updated.hex
            }
        )
    }

    private func color(hue: Double, saturation: Double, brightness: Double) -> Color {
        Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    private static let hueGradient = Gradient(colors: stride(from: 0.0, through: 1.0, by: 0.1).map {
        Color(hue: $0, saturation: 1, brightness: 1)
    })
}

private struct SettingsBackButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(isHovering ? Color.primary.opacity(0.1) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Back")
    }
}

private struct GradientSlider: View {
    @Binding var value: Double
    let gradient: Gradient

    var body: some View {
        GeometryReader { geometry in
            let knob: CGFloat = 12
            ZStack(alignment: .leading) {
                LinearGradient(gradient: gradient, startPoint: .leading, endPoint: .trailing)
                    .frame(height: 7)
                    .clipShape(Capsule())
                Circle()
                    .fill(.white)
                    .overlay(Circle().stroke(.black.opacity(0.35), lineWidth: 1))
                    .shadow(radius: 1)
                    .frame(width: knob, height: knob)
                    .offset(x: max(0, min(geometry.size.width - knob, value * (geometry.size.width - knob))))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                value = max(0, min(1, drag.location.x / max(1, geometry.size.width)))
            })
        }
        .frame(height: 14)
    }
}

private struct HSB {
    var hue: Double
    var saturation: Double
    var brightness: Double

    init(hue: Double, saturation: Double, brightness: Double) {
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
    }

    init?(hex: String) {
        guard let color = NSColor(hex: hex)?.usingColorSpace(.deviceRGB) else { return nil }
        hue = color.hueComponent
        saturation = color.saturationComponent
        brightness = color.brightnessComponent
    }

    var hex: String {
        let color = NSColor(calibratedHue: hue, saturation: saturation, brightness: brightness, alpha: 1)
        return String(
            format: "#%02X%02X%02X",
            Int(color.redComponent * 255),
            Int(color.greenComponent * 255),
            Int(color.blueComponent * 255)
        )
    }
}

extension NSColor {
    convenience init?(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6, let rgb = Int(value, radix: 16) else { return nil }
        self.init(
            calibratedRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Color {
    init?(hex: String) {
        guard let color = NSColor(hex: hex) else { return nil }
        self.init(nsColor: color)
    }
}
