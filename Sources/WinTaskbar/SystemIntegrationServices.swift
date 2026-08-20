import AppKit
import ApplicationServices
import Combine
import Foundation
import ScreenCaptureKit
import ServiceManagement

enum PowerAction: String, CaseIterable, Identifiable {
    case sleep = "Sleep"
    case restart = "Restart"
    case shutDown = "Shut Down"
    case lockScreen = "Lock Screen"
    case logOut = "Log Out"

    var id: String { rawValue }
}

@MainActor
final class PowerService {
    func perform(_ action: PowerAction) {
        let script: String
        switch action {
        case .sleep: script = "tell application \"System Events\" to sleep"
        case .restart: script = "tell application \"System Events\" to restart"
        case .shutDown: script = "tell application \"System Events\" to shut down"
        case .lockScreen: script = "tell application \"System Events\" to keystroke \"q\" using {control down, command down}"
        case .logOut: script = "tell application \"System Events\" to log out"
        }
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }
}

@MainActor
final class ShowDesktopService {
    private let ownBundleID: String
    private var minimizedWindows: [AXUIElement] = []
    private(set) var isDesktopShown = false

    init(ownBundleID: String = Bundle.main.bundleIdentifier ?? "io.github.tinymins.WinTaskbar") {
        self.ownBundleID = ownBundleID
    }

    func toggle() {
        if isDesktopShown { restore() } else { showDesktop() }
    }

    private func showDesktop() {
        minimizedWindows.removeAll()
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.bundleIdentifier != ownBundleID {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            for window in windows(of: element) where !isMinimized(window) {
                if AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, true as CFBoolean) == .success {
                    minimizedWindows.append(window)
                }
            }
        }
        isDesktopShown = true
    }

    private func restore() {
        minimizedWindows.forEach {
            AXUIElementSetAttributeValue($0, kAXMinimizedAttribute as CFString, false as CFBoolean)
        }
        minimizedWindows.removeAll()
        isDesktopShown = false
    }

    private func windows(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func isMinimized(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &value) == .success else { return false }
        return value as? Bool ?? false
    }
}

@MainActor
final class DockToggleService: ObservableObject {
    static let shared = DockToggleService()
    @Published private(set) var isDockHidden: Bool
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isDockHidden = defaults.bool(forKey: "wintaskbar.dockHidden")
    }

    func hideDock() {
        run("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", "true"])
        run("/usr/bin/defaults", ["write", "com.apple.dock", "autohide-delay", "-float", "1000"])
        run("/usr/bin/defaults", ["write", "com.apple.dock", "autohide-time-modifier", "-float", "0"])
        restartDock()
        isDockHidden = true
        defaults.set(true, forKey: "wintaskbar.dockHidden")
    }

    func restoreDock() {
        run("/usr/bin/defaults", ["delete", "com.apple.dock", "autohide-delay"])
        run("/usr/bin/defaults", ["delete", "com.apple.dock", "autohide-time-modifier"])
        run("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", "false"])
        restartDock()
        isDockHidden = false
        defaults.set(false, forKey: "wintaskbar.dockHidden")
    }

    func syncDock(orientation: String) {
        run("/usr/bin/defaults", ["write", "com.apple.dock", "orientation", "-string", orientation])
        restartDock()
    }

    private func restartDock() { run("/usr/bin/killall", ["Dock"]) }

    private func run(_ launchPath: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        try? process.run()
        process.waitUntilExit()
    }
}

@MainActor
final class LoginItemService: ObservableObject {
    static let shared = LoginItemService()
    @Published private(set) var isEnabled = false

    init() { refresh() }

    func refresh() {
        if #available(macOS 13.0, *) { isEnabled = SMAppService.mainApp.status == .enabled }
    }

    func setEnabled(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            if enabled { try? SMAppService.mainApp.register() }
            else { try? SMAppService.mainApp.unregister() }
            refresh()
        }
    }
}

@MainActor
final class PermissionsService: ObservableObject {
    static let shared = PermissionsService()
    @Published private(set) var accessibilityTrusted = false
    @Published private(set) var screenRecordingGranted = false

    func refresh() {
        accessibilityTrusted = AXIsProcessTrusted()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
    }

    func promptForAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibilityTrusted = AXIsProcessTrustedWithOptions(options)
    }

    func requestScreenRecording() { screenRecordingGranted = CGRequestScreenCaptureAccess() }

    func openAccessibilitySettings() { openSettings(anchor: "Privacy_Accessibility") }
    func openScreenRecordingSettings() { openSettings(anchor: "Privacy_ScreenCapture") }
    func openAutomationSettings() { openSettings(anchor: "Privacy_Automation") }

    private func openSettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}

@MainActor
final class WindowFittingService {
    private let preferences: PreferencesStore
    private var timer: Timer?

    init(preferences: PreferencesStore) { self.preferences = preferences }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.clampFocusedWindow() }
        }
    }

    func fitAllWindowsToFreeSpace() {
        guard AXIsProcessTrusted() else { return }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let application = AXUIElementCreateApplication(app.processIdentifier)
            var rawWindows: CFTypeRef?
            guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &rawWindows) == .success,
                  let windows = rawWindows as? [AXUIElement] else { continue }
            windows.forEach(fit)
        }
    }

    private func fit(_ window: AXUIElement) {
        guard let current = frame(of: window),
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(current) }) ?? NSScreen.main else { return }
        let target = freeRect(on: screen)
        setFrame(window, cocoaFrame: target)
    }

    private func clampFocusedWindow() {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        var rawWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &rawWindow) == .success,
              let window = rawWindow as! AXUIElement?,
              let currentAX = frame(of: window) else { return }
        let current = cocoaFrame(fromAXFrame: currentAX)
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(current) }) ?? NSScreen.main else { return }
        let free = freeRect(on: screen)
        if approximatelyFullScreen(current, screen.frame) { return }
        guard !free.contains(current) else { return }
        let width = min(current.width, free.width)
        let height = min(current.height, free.height)
        let x = min(max(current.minX, free.minX), free.maxX - width)
        let y = min(max(current.minY, free.minY), free.maxY - height)
        setFrame(window, cocoaFrame: CGRect(x: x, y: y, width: width, height: height))
    }

    private func freeRect(on screen: NSScreen) -> CGRect {
        var target = screen.visibleFrame
        let bar = CGFloat(preferences.barHeight)
        switch preferences.position {
        case .bottom: target.origin.y += bar; target.size.height -= bar
        case .top: target.size.height -= bar
        case .left: target.origin.x += bar; target.size.width -= bar
        case .right: target.size.width -= bar
        }
        return target
    }

    private func setFrame(_ window: AXUIElement, cocoaFrame: CGRect) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? cocoaFrame.maxY
        var position = CGPoint(x: cocoaFrame.minX, y: primaryHeight - cocoaFrame.maxY)
        var size = cocoaFrame.size
        if let positionValue = AXValueCreate(.cgPoint, &position), let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
    }

    private func cocoaFrame(fromAXFrame frame: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.maxY
        return CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    private func approximatelyFullScreen(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 4 && abs(lhs.minY - rhs.minY) < 4
            && abs(lhs.width - rhs.width) < 4 && abs(lhs.height - rhs.height) < 4
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var positionRaw: CFTypeRef?
        var sizeRaw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRaw) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRaw) == .success,
              let positionValue = positionRaw as! AXValue?,
              let sizeValue = sizeRaw as! AXValue? else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position), AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }
}
