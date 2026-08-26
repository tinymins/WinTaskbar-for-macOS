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
    @Published var launchAtLogin: Bool { didSet { defaults.set(launchAtLogin, forKey: "wintaskbar.launchAtLogin") } }
    @Published var windowPreviewsEnabled: Bool { didSet { defaults.set(windowPreviewsEnabled, forKey: "wintaskbar.feature.windowPreviews") } }
    @Published var showDesktopEnabled: Bool { didSet { defaults.set(showDesktopEnabled, forKey: "wintaskbar.feature.showDesktop") } }
    @Published var globalHotkeysEnabled: Bool { didSet { defaults.set(globalHotkeysEnabled, forKey: "wintaskbar.feature.globalHotkeys") } }
    @Published var hotkeyShortcuts: [HotkeyShortcut] { didSet { Self.store(hotkeyShortcuts, key: "wintaskbar.hotkeyShortcuts", defaults: defaults) } }
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
        launchAtLogin = defaults.object(forKey: "wintaskbar.launchAtLogin") as? Bool ?? false
        windowPreviewsEnabled = defaults.object(forKey: "wintaskbar.feature.windowPreviews") as? Bool ?? true
        showDesktopEnabled = defaults.object(forKey: "wintaskbar.feature.showDesktop") as? Bool ?? true
        globalHotkeysEnabled = defaults.object(forKey: "wintaskbar.feature.globalHotkeys") as? Bool ?? true
        hotkeyShortcuts = Self.load([HotkeyShortcut].self, key: "wintaskbar.hotkeyShortcuts", defaults: defaults)
            ?? Self.defaultHotkeyShortcuts
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
        launchAtLogin = false
        windowPreviewsEnabled = true
        showDesktopEnabled = true
        globalHotkeysEnabled = true
        hotkeyShortcuts = Self.defaultHotkeyShortcuts
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

    func reorderPinned(_ bundleID: String, before destination: String) {
        guard bundleID != destination,
              let sourceIndex = pinnedBundleIDs.firstIndex(of: bundleID),
              let destinationIndex = pinnedBundleIDs.firstIndex(of: destination) else { return }
        let value = pinnedBundleIDs.remove(at: sourceIndex)
        let adjusted = sourceIndex < destinationIndex ? destinationIndex - 1 : destinationIndex
        pinnedBundleIDs.insert(value, at: adjusted)
    }

    private static func store<T: Encodable>(_ value: T, key: String, defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String, defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static var defaultHotkeyShortcuts: [HotkeyShortcut] {
        let modifiers = UInt32(cmdKey | optionKey)
        return [
            HotkeyShortcut(keyCode: 49, modifiers: modifiers, keyLabel: "Space"),
            HotkeyShortcut(keyCode: 2, modifiers: modifiers, keyLabel: "D"),
            HotkeyShortcut(keyCode: 18, modifiers: modifiers, keyLabel: "1"),
            HotkeyShortcut(keyCode: 19, modifiers: modifiers, keyLabel: "2"),
            HotkeyShortcut(keyCode: 20, modifiers: modifiers, keyLabel: "3"),
            HotkeyShortcut(keyCode: 21, modifiers: modifiers, keyLabel: "4"),
            HotkeyShortcut(keyCode: 23, modifiers: modifiers, keyLabel: "5"),
            HotkeyShortcut(keyCode: 22, modifiers: modifiers, keyLabel: "6"),
            HotkeyShortcut(keyCode: 26, modifiers: modifiers, keyLabel: "7"),
            HotkeyShortcut(keyCode: 28, modifiers: modifiers, keyLabel: "8"),
            HotkeyShortcut(keyCode: 25, modifiers: modifiers, keyLabel: "9")
        ]
    }
}
