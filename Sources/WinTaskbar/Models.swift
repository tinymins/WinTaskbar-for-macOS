import AppKit
import Carbon
import Foundation

@MainActor
private enum AppIconCache {
    private static let images: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 256
        return cache
    }()

    static func icon(for url: URL) -> NSImage {
        let key = url as NSURL
        if let cached = images.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        images.setObject(image, forKey: key)
        return image
    }
}

enum TaskbarPosition: String, CaseIterable, Identifiable {
    case bottom = "Bottom"
    case top = "Top"
    case left = "Left"
    case right = "Right"

    var id: String { rawValue }
    var isHorizontal: Bool { self == .bottom || self == .top }
}

enum DisplayMode: String, CaseIterable, Identifiable {
    case all = "All displays"
    case primary = "Primary only"

    var id: String { rawValue }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case automatic = "Automatic"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }
}

enum HighlightStyle: String, CaseIterable, Identifiable {
    case windows = "Windows"
    case mac = "Mac"

    var id: String { rawValue }
}

enum MenuButtonPlacement: String, CaseIterable, Identifiable {
    case standard = "Standard"
    case beforeTray = "Before tray"
    case oppositeEnd = "Opposite end"

    var id: String { rawValue }
}

enum Translucency: String, CaseIterable, Identifiable {
    case off = "Off"
    case subtle = "Subtle"
    case strong = "Strong"

    var id: String { rawValue }
}

enum ActiveIndicatorStyle: String, CaseIterable, Identifiable {
    case underline = "Underline"
    case background = "Background"
    case border = "Border"

    var id: String { rawValue }
}

enum MenuHeightMode: String, CaseIterable, Identifiable {
    case standard = "Standard"
    case full = "Full"

    var id: String { rawValue }
}

enum SearchFieldPosition: String, CaseIterable, Identifiable {
    case top = "Top"
    case bottom = "Bottom"

    var id: String { rawValue }
}

enum MenuActionsSide: String, CaseIterable, Identifiable {
    case left = "Left"
    case right = "Right"

    var id: String { rawValue }
}

struct AppFolder: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var bundleIDs: [String]
    var isExpanded: Bool

    init(id: String = UUID().uuidString, name: String, bundleIDs: [String] = [], isExpanded: Bool = true) {
        self.id = id
        self.name = name
        self.bundleIDs = bundleIDs
        self.isExpanded = isExpanded
    }
}

struct PinnedShortcut: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var target: String

    init(id: String = UUID().uuidString, name: String, target: String) {
        self.id = id
        self.name = name
        self.target = target
    }

    var url: URL? {
        if let url = URL(string: target), url.scheme != nil { return url }
        return URL(fileURLWithPath: target)
    }
}

struct HotkeyShortcut: Codable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32
    var keyLabel: String

    var displayValue: String {
        var value = ""
        if modifiers & UInt32(controlKey) != 0 { value += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { value += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { value += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { value += "⌘" }
        return value + keyLabel
    }
}

enum WindowsKeyMapping: String, Codable, CaseIterable, Identifiable {
    case option = "Option"
    case command = "Command"

    var id: String { rawValue }

    var carbonModifier: UInt32 {
        switch self {
        case .option: UInt32(optionKey)
        case .command: UInt32(cmdKey)
        }
    }

    var eventModifier: NSEvent.ModifierFlags {
        switch self {
        case .option: .option
        case .command: .command
        }
    }
}

struct ShortcutApplicationTarget: Codable, Hashable {
    var name: String
    var bundleIdentifier: String?
    var path: String

    init?(url: URL) {
        guard url.pathExtension.lowercased() == "app" else { return nil }
        name = url.deletingPathExtension().lastPathComponent
        bundleIdentifier = Bundle(url: url)?.bundleIdentifier
        path = url.path
    }

    init(name: String, bundleIdentifier: String?, path: String) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.path = path
    }

    var resolvedURL: URL? {
        if let bundleIdentifier,
           let installedURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return installedURL
        }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

enum GlobalShortcutAction: String, Codable, CaseIterable, Identifiable {
    case toggleStartMenu
    case showDesktop
    case openFileManager
    case openSystemSettings
    case openSearch
    case openApplication
    case lockScreen
    case toggleQuickSettings
    case toggleCalendar
    case toggleInputSources
    case launchPinned

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggleStartMenu: "Toggle Start Menu"
        case .showDesktop: "Show Desktop"
        case .openFileManager: "Open File Manager"
        case .openSystemSettings: "Open System Settings"
        case .openSearch: "Open Search"
        case .openApplication: "Open Application"
        case .lockScreen: "Lock Screen"
        case .toggleQuickSettings: "Toggle Quick Settings"
        case .toggleCalendar: "Toggle Calendar"
        case .toggleInputSources: "Toggle Input Sources"
        case .launchPinned: "Launch Pinned App"
        }
    }

    var supportsApplicationTarget: Bool {
        self == .openFileManager || self == .openSearch || self == .openApplication
    }

    var defaultApplicationName: String? {
        switch self {
        case .openFileManager: "Finder"
        case .openSearch: "Spotlight"
        default: nil
        }
    }
}

struct GlobalShortcutConfiguration: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var windowsShortcutLabel: String
    var isEnabled: Bool
    var shortcut: HotkeyShortcut
    var usesWindowsKey: Bool
    var action: GlobalShortcutAction
    var pinnedIndex: Int?
    var applicationTarget: ShortcutApplicationTarget?

    func resolvedShortcut(mapping: WindowsKeyMapping) -> HotkeyShortcut {
        guard usesWindowsKey else { return shortcut }
        var resolved = shortcut
        resolved.modifiers |= mapping.carbonModifier
        return resolved
    }

    func displayValue(mapping: WindowsKeyMapping) -> String {
        resolvedShortcut(mapping: mapping).displayValue
    }
}

enum GlobalShortcutCatalog {
    static let startMenuID = "start-menu"
    static let showDesktopID = "show-desktop"
    static let fileManagerID = "file-manager"
    static let quickSettingsID = "quick-settings"
    static let calendarID = "calendar"
    static let inputSourcesID = "input-sources"
    static let systemSettingsID = "system-settings"
    static let searchID = "search"
    static let runID = "run"
    static let lockScreenID = "lock-screen"

    static func defaults(legacyShortcuts: [HotkeyShortcut]) -> [GlobalShortcutConfiguration] {
        let legacy = legacyShortcuts.count == 11 ? legacyShortcuts : defaultLegacyShortcuts
        var configurations = [
            configuration(
                id: startMenuID,
                title: "Start Menu (alternate)",
                windowsLabel: "Win",
                enabled: true,
                shortcut: legacy[0],
                action: .toggleStartMenu
            ),
            configuration(
                id: showDesktopID,
                title: "Show Desktop",
                windowsLabel: "Win+D",
                enabled: true,
                shortcut: legacy[1],
                action: .showDesktop
            ),
            configuration(
                id: fileManagerID,
                title: "File Explorer",
                windowsLabel: "Win+E",
                enabled: true,
                shortcut: HotkeyShortcut(keyCode: 14, modifiers: 0, keyLabel: "E"),
                usesWindowsKey: true,
                action: .openFileManager
            ),
            configuration(
                id: quickSettingsID,
                title: "Quick Settings",
                windowsLabel: "Win+A",
                enabled: false,
                shortcut: HotkeyShortcut(keyCode: 0, modifiers: 0, keyLabel: "A"),
                usesWindowsKey: true,
                action: .toggleQuickSettings
            ),
            configuration(
                id: calendarID,
                title: "Notifications and Calendar",
                windowsLabel: "Win+N",
                enabled: false,
                shortcut: HotkeyShortcut(keyCode: 45, modifiers: 0, keyLabel: "N"),
                usesWindowsKey: true,
                action: .toggleCalendar
            ),
            configuration(
                id: inputSourcesID,
                title: "Input Sources",
                windowsLabel: "Win+Space",
                enabled: false,
                shortcut: HotkeyShortcut(keyCode: 49, modifiers: 0, keyLabel: "Space"),
                usesWindowsKey: true,
                action: .toggleInputSources
            ),
            configuration(
                id: systemSettingsID,
                title: "Settings",
                windowsLabel: "Win+I",
                enabled: false,
                shortcut: HotkeyShortcut(keyCode: 34, modifiers: 0, keyLabel: "I"),
                usesWindowsKey: true,
                action: .openSystemSettings
            ),
            configuration(
                id: searchID,
                title: "Search",
                windowsLabel: "Win+S",
                enabled: false,
                shortcut: HotkeyShortcut(keyCode: 1, modifiers: 0, keyLabel: "S"),
                usesWindowsKey: true,
                action: .openSearch
            ),
            configuration(
                id: runID,
                title: "Run",
                windowsLabel: "Win+R",
                enabled: false,
                shortcut: HotkeyShortcut(keyCode: 15, modifiers: 0, keyLabel: "R"),
                usesWindowsKey: true,
                action: .openApplication
            ),
            configuration(
                id: lockScreenID,
                title: "Lock Screen",
                windowsLabel: "Win+L",
                enabled: false,
                shortcut: HotkeyShortcut(keyCode: 37, modifiers: 0, keyLabel: "L"),
                usesWindowsKey: true,
                action: .lockScreen
            )
        ]
        for index in 0..<9 {
            configurations.append(configuration(
                id: "pinned-\(index + 1)",
                title: "Pinned App \(index + 1)",
                windowsLabel: "Win+\(index + 1)",
                enabled: true,
                shortcut: legacy[index + 2],
                action: .launchPinned,
                pinnedIndex: index
            ))
        }
        return configurations
    }

    static func merged(
        stored: [GlobalShortcutConfiguration],
        legacyShortcuts: [HotkeyShortcut]
    ) -> [GlobalShortcutConfiguration] {
        let storedByID = Dictionary(stored.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return defaults(legacyShortcuts: legacyShortcuts).map { storedByID[$0.id] ?? $0 }
    }

    static func defaultConfiguration(
        id: String,
        legacyShortcuts: [HotkeyShortcut]
    ) -> GlobalShortcutConfiguration? {
        defaults(legacyShortcuts: legacyShortcuts).first { $0.id == id }
    }

    static let defaultLegacyShortcuts: [HotkeyShortcut] = {
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
    }()

    private static func configuration(
        id: String,
        title: String,
        windowsLabel: String,
        enabled: Bool,
        shortcut: HotkeyShortcut,
        usesWindowsKey: Bool = false,
        action: GlobalShortcutAction,
        pinnedIndex: Int? = nil
    ) -> GlobalShortcutConfiguration {
        GlobalShortcutConfiguration(
            id: id,
            title: title,
            windowsShortcutLabel: windowsLabel,
            isEnabled: enabled,
            shortcut: shortcut,
            usesWindowsKey: usesWindowsKey,
            action: action,
            pinnedIndex: pinnedIndex,
            applicationTarget: nil
        )
    }
}

struct DiscoveredApp: Identifiable, Hashable {
    let name: String
    let bundleIdentifier: String?
    let url: URL
    let category: String?
    var isRunning: Bool
    var isActive: Bool
    var processIdentifier: pid_t?

    init(
        name: String,
        bundleIdentifier: String?,
        url: URL,
        category: String? = nil,
        isRunning: Bool,
        isActive: Bool = false,
        processIdentifier: pid_t? = nil
    ) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.url = url
        self.category = category
        self.isRunning = isRunning
        self.isActive = isActive
        self.processIdentifier = processIdentifier
    }

    var id: String { bundleIdentifier ?? url.path }

    @MainActor
    var icon: NSImage {
        AppIconCache.icon(for: url)
    }
}

struct TaskbarItem: Identifiable, Hashable {
    let bundleIdentifier: String
    let name: String
    let url: URL
    let isPinned: Bool
    let isRunning: Bool
    let isActive: Bool
    let processIdentifier: pid_t?
    let badge: String?

    var id: String { bundleIdentifier }

    @MainActor
    var icon: NSImage { AppIconCache.icon(for: url) }
}

struct WindowInfo: Identifiable, Hashable {
    let windowID: CGWindowID
    let title: String
    let ownerPID: pid_t
    let frame: CGRect
    let isMinimized: Bool

    var id: CGWindowID { windowID }
}

struct RecentDocument: Identifiable, Hashable {
    let url: URL
    let label: String

    var id: URL { url }
}
