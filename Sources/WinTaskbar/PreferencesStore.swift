import Combine
import Carbon
import Foundation

@MainActor
final class PreferencesStore: ObservableObject {
    static let shared = PreferencesStore()

    private let defaults: UserDefaults

    @Published var position: TaskbarPosition { didSet { defaults.set(position.rawValue, forKey: "wintaskbar.position") } }
    @Published var displayMode: DisplayMode { didSet { defaults.set(displayMode.rawValue, forKey: "wintaskbar.displayMode") } }
    @Published var barHeight: Double { didSet { defaults.set(barHeight, forKey: "wintaskbar.barHeight") } }
    @Published var iconScale: Double { didSet { defaults.set(iconScale, forKey: "wintaskbar.iconScale") } }
    @Published var iconPadding: Double { didSet { defaults.set(iconPadding, forKey: "wintaskbar.iconPadding") } }
    @Published var theme: AppTheme { didSet { defaults.set(theme.rawValue, forKey: "wintaskbar.theme") } }
    @Published var highlightStyle: HighlightStyle { didSet { defaults.set(highlightStyle.rawValue, forKey: "wintaskbar.highlightStyle") } }
    @Published var showRunningIndicators: Bool { didSet { defaults.set(showRunningIndicators, forKey: "wintaskbar.showRunningIndicators") } }
    @Published var showAppLabels: Bool { didSet { defaults.set(showAppLabels, forKey: "wintaskbar.showAppLabels") } }
    @Published var showFinder: Bool { didSet { defaults.set(showFinder, forKey: "wintaskbar.showFinderInRunningApps") } }
    @Published var transparencyEnabled: Bool { didSet { defaults.set(transparencyEnabled, forKey: "wintaskbar.transparencyEnabled") } }
    @Published var panelOpacity: Double { didSet { defaults.set(panelOpacity, forKey: "wintaskbar.panelOpacity") } }
    @Published var panelBlurRadius: Double { didSet { defaults.set(panelBlurRadius, forKey: "wintaskbar.panelBlurRadius") } }
    @Published var startButtonLabel: String { didSet { defaults.set(startButtonLabel, forKey: "wintaskbar.startButtonLabel") } }
    @Published var menuButtonPlacement: MenuButtonPlacement { didSet { defaults.set(menuButtonPlacement.rawValue, forKey: "wintaskbar.menuButtonPlacement") } }
    @Published var startButtonAtEnd: Bool { didSet { defaults.set(startButtonAtEnd, forKey: "wintaskbar.startButtonAtEnd") } }
    @Published var translucency: Translucency { didSet { defaults.set(translucency.rawValue, forKey: "wintaskbar.translucency") } }
    @Published var panelTintHex: String { didSet { defaults.set(panelTintHex, forKey: "wintaskbar.panelTintHex") } }
    @Published var activeIndicator: ActiveIndicatorStyle { didSet { defaults.set(activeIndicator.rawValue, forKey: "wintaskbar.activeIndicator") } }
    @Published var menuWindowStyle: HighlightStyle { didSet { defaults.set(menuWindowStyle.rawValue, forKey: "wintaskbar.menuWindowStyle") } }
    @Published var menuHeightMode: MenuHeightMode { didSet { defaults.set(menuHeightMode.rawValue, forKey: "wintaskbar.menuHeightMode") } }
    @Published var searchFieldPosition: SearchFieldPosition { didSet { defaults.set(searchFieldPosition.rawValue, forKey: "wintaskbar.searchFieldPosition") } }
    @Published var menuActionsSide: MenuActionsSide { didSet { defaults.set(menuActionsSide.rawValue, forKey: "wintaskbar.menuActionsSide") } }
    @Published var trayBatteryEnabled: Bool { didSet { defaults.set(trayBatteryEnabled, forKey: "wintaskbar.feature.trayBattery") } }
    @Published var trayVolumeEnabled: Bool { didSet { defaults.set(trayVolumeEnabled, forKey: "wintaskbar.feature.trayVolume") } }
    @Published var trayWifiEnabled: Bool { didSet { defaults.set(trayWifiEnabled, forKey: "wintaskbar.feature.trayWifi") } }
    @Published var trayInputSourceEnabled: Bool { didSet { defaults.set(trayInputSourceEnabled, forKey: "wintaskbar.feature.trayInputSource") } }
    @Published var trayClockEnabled: Bool { didSet { defaults.set(trayClockEnabled, forKey: "wintaskbar.feature.trayClock") } }
    @Published var trayClockShowsSeconds: Bool { didSet { defaults.set(trayClockShowsSeconds, forKey: "wintaskbar.feature.trayClockShowsSeconds") } }
    @Published var dateTimeCalendarKind: DateTimeCalendarKind { didSet { defaults.set(dateTimeCalendarKind.rawValue, forKey: "wintaskbar.dateTime.calendar") } }
    @Published var dateTimeFirstDayOfWeek: DateTimeFirstDayOfWeek { didSet { defaults.set(dateTimeFirstDayOfWeek.rawValue, forKey: "wintaskbar.dateTime.firstDayOfWeek") } }
    @Published var dateTimeShortDatePattern: String { didSet { defaults.set(dateTimeShortDatePattern, forKey: "wintaskbar.dateTime.shortDatePattern") } }
    @Published var dateTimeLongDateStyle: DateTimeLongDateStyle { didSet { defaults.set(dateTimeLongDateStyle.rawValue, forKey: "wintaskbar.dateTime.longDateStyle") } }
    @Published var dateTimeCustomLongDatePattern: String { didSet { defaults.set(dateTimeCustomLongDatePattern, forKey: "wintaskbar.dateTime.customLongDatePattern") } }
    @Published var dateTimeCustomLongDateIncludesLunar: Bool { didSet { defaults.set(dateTimeCustomLongDateIncludesLunar, forKey: "wintaskbar.dateTime.customLongDateIncludesLunar") } }
    @Published var dateTimeShortTimePattern: String { didSet { defaults.set(dateTimeShortTimePattern, forKey: "wintaskbar.dateTime.shortTimePattern") } }
    @Published var dateTimeLongTimePattern: String { didSet { defaults.set(dateTimeLongTimePattern, forKey: "wintaskbar.dateTime.longTimePattern") } }
    @Published var dateTimeAMSymbol: String { didSet { defaults.set(dateTimeAMSymbol, forKey: "wintaskbar.dateTime.amSymbol") } }
    @Published var dateTimePMSymbol: String { didSet { defaults.set(dateTimePMSymbol, forKey: "wintaskbar.dateTime.pmSymbol") } }
    @Published var additionalClocks: [AdditionalClockConfiguration] {
        didSet { Self.store(additionalClocks, key: "wintaskbar.dateTime.additionalClocks", defaults: defaults) }
    }
    @Published var launchAtLogin: Bool { didSet { defaults.set(launchAtLogin, forKey: "wintaskbar.launchAtLogin") } }
    @Published var windowPreviewsEnabled: Bool { didSet { defaults.set(windowPreviewsEnabled, forKey: "wintaskbar.feature.windowPreviews") } }
    @Published var showDesktopEnabled: Bool { didSet { defaults.set(showDesktopEnabled, forKey: "wintaskbar.feature.showDesktop") } }
    @Published var globalHotkeysEnabled: Bool { didSet { defaults.set(globalHotkeysEnabled, forKey: "wintaskbar.feature.globalHotkeys") } }
    @Published var windowsKeyMapping: WindowsKeyMapping { didSet { defaults.set(windowsKeyMapping.rawValue, forKey: "wintaskbar.windowsKeyMapping") } }
    @Published var windowsKeyOpensStart: Bool { didSet { defaults.set(windowsKeyOpensStart, forKey: "wintaskbar.windowsKeyOpensStart") } }
    @Published var globalShortcutConfigurations: [GlobalShortcutConfiguration] {
        didSet { Self.store(globalShortcutConfigurations, key: "wintaskbar.globalShortcutConfigurations", defaults: defaults) }
    }
    @Published var customShortcutConfigurations: [CustomShortcutConfiguration] {
        didSet { Self.store(customShortcutConfigurations, key: "wintaskbar.customShortcutConfigurations", defaults: defaults) }
    }
    @Published var showRecentInMenu: Bool { didSet { defaults.set(showRecentInMenu, forKey: "wintaskbar.showRecentInMenu") } }
    @Published var showShortcutsInMenu: Bool { didSet { defaults.set(showShortcutsInMenu, forKey: "wintaskbar.showShortcutsInMenu") } }
    @Published var groupStartMenuByCategory: Bool { didSet { defaults.set(groupStartMenuByCategory, forKey: "wintaskbar.groupStartMenuByCategory") } }
    @Published var pinnedBundleIDs: [String] { didSet { defaults.set(pinnedBundleIDs, forKey: "wintaskbar.pinnedBundleIDs") } }
    @Published var menuShortcutPaths: [String] { didSet { defaults.set(menuShortcutPaths, forKey: "wintaskbar.menuShortcutPaths") } }
    @Published var appFolders: [AppFolder] { didSet { Self.store(appFolders, key: "wintaskbar.appFolders", defaults: defaults) } }
    @Published var pinnedShortcuts: [String: [PinnedShortcut]] { didSet { Self.store(pinnedShortcuts, key: "wintaskbar.pinnedShortcuts", defaults: defaults) } }
    @Published var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: "wintaskbar.hasCompletedOnboarding") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        position = TaskbarPosition(rawValue: defaults.string(forKey: "wintaskbar.position") ?? "") ?? .bottom
        displayMode = DisplayMode(rawValue: defaults.string(forKey: "wintaskbar.displayMode") ?? "") ?? .all
        let storedBarHeight = defaults.object(forKey: "wintaskbar.barHeight") as? Double
        let storedIconScale = defaults.object(forKey: "wintaskbar.iconScale") as? Double
        let storedIconPadding = defaults.object(forKey: "wintaskbar.iconPadding") as? Double
        let usesPointBasedRecoveryGeometry = storedIconScale.map { $0 > 1.2 } ?? false
        barHeight = usesPointBasedRecoveryGeometry && storedBarHeight == 52 ? 48 : storedBarHeight ?? 48
        iconScale = usesPointBasedRecoveryGeometry
            ? min(max((storedIconScale ?? 36) / 36, 0.6), 1.2)
            : storedIconScale ?? 1
        iconPadding = usesPointBasedRecoveryGeometry
            ? min(max((storedIconPadding ?? 5) * 0.012, 0), 0.2)
            : storedIconPadding ?? 0.06
        theme = AppTheme(rawValue: defaults.string(forKey: "wintaskbar.theme") ?? "") ?? .automatic
        highlightStyle = HighlightStyle(rawValue: defaults.string(forKey: "wintaskbar.highlightStyle") ?? "") ?? .mac
        showRunningIndicators = defaults.object(forKey: "wintaskbar.showRunningIndicators") as? Bool ?? true
        showAppLabels = defaults.object(forKey: "wintaskbar.showAppLabels") as? Bool ?? false
        showFinder = defaults.object(forKey: "wintaskbar.showFinderInRunningApps") as? Bool ?? true
        transparencyEnabled = defaults.object(forKey: "wintaskbar.transparencyEnabled") as? Bool ?? true
        panelOpacity = defaults.object(forKey: "wintaskbar.panelOpacity") as? Double ?? 1
        panelBlurRadius = defaults.object(forKey: "wintaskbar.panelBlurRadius") as? Double ?? 20
        startButtonLabel = defaults.string(forKey: "wintaskbar.startButtonLabel") ?? ""
        menuButtonPlacement = MenuButtonPlacement(rawValue: defaults.string(forKey: "wintaskbar.menuButtonPlacement") ?? "") ?? .standard
        startButtonAtEnd = defaults.object(forKey: "wintaskbar.startButtonAtEnd") as? Bool ?? false
        translucency = Translucency(rawValue: defaults.string(forKey: "wintaskbar.translucency") ?? "") ?? .subtle
        panelTintHex = defaults.string(forKey: "wintaskbar.panelTintHex") ?? ""
        activeIndicator = ActiveIndicatorStyle(rawValue: defaults.string(forKey: "wintaskbar.activeIndicator") ?? "") ?? .underline
        menuWindowStyle = HighlightStyle(rawValue: defaults.string(forKey: "wintaskbar.menuWindowStyle") ?? "") ?? .windows
        menuHeightMode = MenuHeightMode(rawValue: defaults.string(forKey: "wintaskbar.menuHeightMode") ?? "") ?? .standard
        searchFieldPosition = SearchFieldPosition(rawValue: defaults.string(forKey: "wintaskbar.searchFieldPosition") ?? "") ?? .bottom
        menuActionsSide = MenuActionsSide(rawValue: defaults.string(forKey: "wintaskbar.menuActionsSide") ?? "") ?? .right
        trayBatteryEnabled = defaults.object(forKey: "wintaskbar.feature.trayBattery") as? Bool ?? true
        trayVolumeEnabled = defaults.object(forKey: "wintaskbar.feature.trayVolume") as? Bool ?? true
        trayWifiEnabled = defaults.object(forKey: "wintaskbar.feature.trayWifi") as? Bool ?? true
        trayInputSourceEnabled = defaults.object(forKey: "wintaskbar.feature.trayInputSource") as? Bool ?? true
        trayClockEnabled = defaults.object(forKey: "wintaskbar.feature.trayClock") as? Bool ?? true
        trayClockShowsSeconds = defaults.object(forKey: "wintaskbar.feature.trayClockShowsSeconds") as? Bool ?? true
        dateTimeCalendarKind = DateTimeCalendarKind(
            rawValue: defaults.string(forKey: "wintaskbar.dateTime.calendar") ?? ""
        ) ?? .gregorian
        dateTimeFirstDayOfWeek = DateTimeFirstDayOfWeek(
            rawValue: defaults.string(forKey: "wintaskbar.dateTime.firstDayOfWeek") ?? ""
        ) ?? .sunday
        dateTimeShortDatePattern = DateTimeFormatCatalog.validated(
            defaults.string(forKey: "wintaskbar.dateTime.shortDatePattern"),
            allowed: DateTimeFormatCatalog.shortDatePatterns,
            fallback: "M/d/yyyy"
        )
        let legacyLongDatePattern = defaults.string(forKey: "wintaskbar.dateTime.longDatePattern")
        let storedLongDateStyle = DateTimeLongDateStyle(
            rawValue: defaults.string(forKey: "wintaskbar.dateTime.longDateStyle") ?? ""
        ) ?? DateTimeLongDateStyle.migrated(from: legacyLongDatePattern)
        dateTimeLongDateStyle = storedLongDateStyle
        dateTimeCustomLongDatePattern = defaults.string(forKey: "wintaskbar.dateTime.customLongDatePattern")
            ?? (storedLongDateStyle == .custom ? legacyLongDatePattern : nil)
            ?? "yyyy年M月d日"
        dateTimeCustomLongDateIncludesLunar = defaults.object(
            forKey: "wintaskbar.dateTime.customLongDateIncludesLunar"
        ) as? Bool ?? false
        dateTimeShortTimePattern = DateTimeFormatCatalog.validated(
            defaults.string(forKey: "wintaskbar.dateTime.shortTimePattern"),
            allowed: DateTimeFormatCatalog.shortTimePatterns,
            fallback: "HH:mm"
        )
        dateTimeLongTimePattern = DateTimeFormatCatalog.validated(
            defaults.string(forKey: "wintaskbar.dateTime.longTimePattern"),
            allowed: DateTimeFormatCatalog.longTimePatterns,
            fallback: "HH:mm:ss"
        )
        dateTimeAMSymbol = defaults.string(forKey: "wintaskbar.dateTime.amSymbol") ?? "AM"
        dateTimePMSymbol = defaults.string(forKey: "wintaskbar.dateTime.pmSymbol") ?? "PM"
        let storedAdditionalClocks = Self.load(
            [AdditionalClockConfiguration].self,
            key: "wintaskbar.dateTime.additionalClocks",
            defaults: defaults
        )
        additionalClocks = storedAdditionalClocks.flatMap { clocks in
            clocks.count == 2 ? clocks : nil
        } ?? AdditionalClockConfiguration.defaults
        launchAtLogin = defaults.object(forKey: "wintaskbar.launchAtLogin") as? Bool ?? false
        windowPreviewsEnabled = defaults.object(forKey: "wintaskbar.feature.windowPreviews") as? Bool ?? true
        showDesktopEnabled = defaults.object(forKey: "wintaskbar.feature.showDesktop") as? Bool ?? true
        globalHotkeysEnabled = defaults.object(forKey: "wintaskbar.feature.globalHotkeys") as? Bool ?? true
        windowsKeyMapping = WindowsKeyMapping(rawValue: defaults.string(forKey: "wintaskbar.windowsKeyMapping") ?? "") ?? .option
        windowsKeyOpensStart = defaults.object(forKey: "wintaskbar.windowsKeyOpensStart") as? Bool ?? true
        let legacyShortcuts = Self.load([HotkeyShortcut].self, key: "wintaskbar.hotkeyShortcuts", defaults: defaults)
            ?? GlobalShortcutCatalog.defaultLegacyShortcuts
        if let stored = Self.load(
            [GlobalShortcutConfiguration].self,
            key: "wintaskbar.globalShortcutConfigurations",
            defaults: defaults
        ) {
            globalShortcutConfigurations = GlobalShortcutCatalog.merged(
                stored: stored,
                legacyShortcuts: legacyShortcuts
            )
        } else {
            globalShortcutConfigurations = GlobalShortcutCatalog.defaults(legacyShortcuts: legacyShortcuts)
        }
        customShortcutConfigurations = Self.load(
            [CustomShortcutConfiguration].self,
            key: "wintaskbar.customShortcutConfigurations",
            defaults: defaults
        ) ?? []
        showRecentInMenu = defaults.object(forKey: "wintaskbar.showRecentInMenu") as? Bool ?? true
        showShortcutsInMenu = defaults.object(forKey: "wintaskbar.showShortcutsInMenu") as? Bool ?? true
        groupStartMenuByCategory = defaults.object(forKey: "wintaskbar.groupStartMenuByCategory") as? Bool ?? false
        pinnedBundleIDs = defaults.stringArray(forKey: "wintaskbar.pinnedBundleIDs")
            ?? ["com.apple.finder"]
        menuShortcutPaths = defaults.stringArray(forKey: "wintaskbar.menuShortcutPaths") ?? []
        appFolders = Self.load([AppFolder].self, key: "wintaskbar.appFolders", defaults: defaults) ?? []
        pinnedShortcuts = Self.load([String: [PinnedShortcut]].self, key: "wintaskbar.pinnedShortcuts", defaults: defaults) ?? [:]
        hasCompletedOnboarding = defaults.bool(forKey: "wintaskbar.hasCompletedOnboarding")

        if usesPointBasedRecoveryGeometry {
            defaults.set(barHeight, forKey: "wintaskbar.barHeight")
            defaults.set(iconScale, forKey: "wintaskbar.iconScale")
            defaults.set(iconPadding, forKey: "wintaskbar.iconPadding")
        }
    }

    var colorScheme: String? {
        switch theme {
        case .automatic: nil
        case .light: "light"
        case .dark: "dark"
        }
    }

    var dateTimeFormatConfiguration: DateTimeFormatConfiguration {
        let customPattern = dateTimeCustomLongDatePattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let usesCustomLongDate = dateTimeLongDateStyle == .custom
        return DateTimeFormatConfiguration(
            calendarKind: dateTimeCalendarKind,
            firstDayOfWeek: dateTimeFirstDayOfWeek,
            shortDatePattern: dateTimeShortDatePattern,
            longDatePattern: usesCustomLongDate
                ? (customPattern.isEmpty ? "yyyy年M月d日" : customPattern)
                : dateTimeLongDateStyle.pattern!,
            longDateIncludesLunar: usesCustomLongDate
                ? dateTimeCustomLongDateIncludesLunar
                : dateTimeLongDateStyle.includesLunar,
            shortTimePattern: dateTimeShortTimePattern,
            longTimePattern: dateTimeLongTimePattern,
            amSymbol: dateTimeAMSymbol,
            pmSymbol: dateTimePMSymbol
        )
    }

    func reset() {
        position = .bottom
        displayMode = .all
        barHeight = 48
        iconScale = 1
        iconPadding = 0.06
        theme = .automatic
        highlightStyle = .mac
        showRunningIndicators = true
        showAppLabels = false
        showFinder = true
        transparencyEnabled = true
        panelOpacity = 1
        panelBlurRadius = 20
        startButtonLabel = ""
        menuButtonPlacement = .standard
        startButtonAtEnd = false
        translucency = .subtle
        panelTintHex = ""
        activeIndicator = .underline
        menuWindowStyle = .windows
        menuHeightMode = .standard
        searchFieldPosition = .bottom
        menuActionsSide = .right
        trayBatteryEnabled = true
        trayVolumeEnabled = true
        trayWifiEnabled = true
        trayInputSourceEnabled = true
        trayClockEnabled = true
        trayClockShowsSeconds = true
        dateTimeCalendarKind = .gregorian
        dateTimeFirstDayOfWeek = .sunday
        dateTimeShortDatePattern = "M/d/yyyy"
        dateTimeLongDateStyle = .windowsFull
        dateTimeCustomLongDatePattern = "yyyy年M月d日"
        dateTimeCustomLongDateIncludesLunar = false
        dateTimeShortTimePattern = "HH:mm"
        dateTimeLongTimePattern = "HH:mm:ss"
        dateTimeAMSymbol = "AM"
        dateTimePMSymbol = "PM"
        additionalClocks = AdditionalClockConfiguration.defaults
        launchAtLogin = false
        windowPreviewsEnabled = true
        showDesktopEnabled = true
        globalHotkeysEnabled = true
        windowsKeyMapping = .option
        windowsKeyOpensStart = true
        globalShortcutConfigurations = GlobalShortcutCatalog.defaults(
            legacyShortcuts: GlobalShortcutCatalog.defaultLegacyShortcuts
        )
        customShortcutConfigurations = []
        showRecentInMenu = true
        showShortcutsInMenu = true
        groupStartMenuByCategory = false
        pinnedBundleIDs = ["com.apple.finder"]
        menuShortcutPaths = []
        appFolders = []
        pinnedShortcuts = [:]
        hasCompletedOnboarding = false
    }

    func pin(_ bundleID: String) {
        guard !pinnedBundleIDs.contains(bundleID) else { return }
        pinnedBundleIDs.append(bundleID)
    }

    func unpin(_ bundleID: String) {
        pinnedBundleIDs.removeAll { $0 == bundleID }
    }

    func reorderPinned(_ bundleID: String, relativeTo destination: String, after: Bool) {
        guard bundleID != destination,
              let sourceIndex = pinnedBundleIDs.firstIndex(of: bundleID),
              let destinationIndex = pinnedBundleIDs.firstIndex(of: destination) else { return }
        let value = pinnedBundleIDs.remove(at: sourceIndex)
        let adjusted = sourceIndex < destinationIndex ? destinationIndex - 1 : destinationIndex
        pinnedBundleIDs.insert(value, at: after ? adjusted + 1 : adjusted)
    }

    func alignPinnedOrder(to taskbarBundleIDs: [String]) {
        let pinned = Set(pinnedBundleIDs)
        let ordered = taskbarBundleIDs.filter { pinned.contains($0) }
        let missing = pinnedBundleIDs.filter { !ordered.contains($0) }
        let result = ordered + missing
        if result != pinnedBundleIDs { pinnedBundleIDs = result }
    }

    private static func store<T: Encodable>(_ value: T, key: String, defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String, defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

}
