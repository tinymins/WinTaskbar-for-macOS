import AppKit
import Carbon
import Foundation

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
        NSWorkspace.shared.icon(forFile: url.path)
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
    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
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
