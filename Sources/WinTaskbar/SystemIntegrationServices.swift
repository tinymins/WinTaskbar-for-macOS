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

struct WindowFittingScreenBox: Equatable, Sendable {
    let frame: CGRect
    let visibleFrame: CGRect
}

enum WindowFittingGeometry {
    static let safetyInset: CGFloat = 3
    static let minimumWindowSize = CGSize(width: 100, height: 60)

    static func freeRect(
        on screen: WindowFittingScreenBox,
        position: TaskbarPosition,
        barHeight: CGFloat
    ) -> CGRect {
        var target = screen.visibleFrame
        let reserved = max(0, barHeight + safetyInset)
        switch position {
        case .bottom:
            target.origin.y += reserved
            target.size.height -= reserved
        case .top:
            target.size.height -= reserved
        case .left:
            target.origin.x += reserved
            target.size.width -= reserved
        case .right:
            target.size.width -= reserved
        }
        target.size.width = max(0, target.width)
        target.size.height = max(0, target.height)
        return target
    }

    static func clampedRect(
        _ rect: CGRect,
        on screen: WindowFittingScreenBox,
        position: TaskbarPosition,
        barHeight: CGFloat
    ) -> CGRect? {
        let free = freeRect(on: screen, position: position, barHeight: barHeight)
        var result = rect
        switch position {
        case .bottom where rect.minY < free.minY:
            result.origin.y = free.minY
            result.size.height = rect.maxY - free.minY
        case .top where rect.maxY > free.maxY:
            result.size.height = free.maxY - rect.minY
        case .left where rect.minX < free.minX:
            result.origin.x = free.minX
            result.size.width = rect.maxX - free.minX
        case .right where rect.maxX > free.maxX:
            result.size.width = free.maxX - rect.minX
        default:
            return nil
        }
        guard result.width > minimumWindowSize.width,
              result.height > minimumWindowSize.height,
              result != rect else { return nil }
        return result
    }

    static func cocoaFrame(axPosition: CGPoint, size: CGSize, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: axPosition.x,
            y: primaryHeight - axPosition.y - size.height,
            width: size.width,
            height: size.height
        )
    }

    static func axPosition(cocoaFrame: CGRect, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: cocoaFrame.minX, y: primaryHeight - cocoaFrame.maxY)
    }

    static func box(containing rect: CGRect, in screens: [WindowFittingScreenBox]) -> WindowFittingScreenBox? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return screens.first(where: { $0.frame.contains(center) }) ?? screens.first
    }

    static func isFullScreen(_ rect: CGRect, in screens: [WindowFittingScreenBox]) -> Bool {
        guard let screen = box(containing: rect, in: screens) else { return false }
        return abs(rect.width - screen.frame.width) < 2
            && abs(rect.height - screen.frame.height) < 2
    }
}

private struct WindowFittingContext: Sendable {
    let primaryHeight: CGFloat
    let position: TaskbarPosition
    let barHeight: CGFloat
    let screens: [WindowFittingScreenBox]
}

private let windowFittingAXCallback: AXObserverCallback = { _, _, notification, refcon in
    guard let refcon else { return }
    let service = Unmanaged<WindowFittingService>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    DispatchQueue.main.async {
        MainActor.assumeIsolated { service.handleAXNotification(name) }
    }
}

@MainActor
final class WindowFittingService {
    private let preferences: PreferencesStore
    private let axQueue = DispatchQueue(label: "io.github.tinymins.WinTaskbar.windowfitting.ax", qos: .userInitiated)
    private var workspaceObserver: NSObjectProtocol?
    private var observer: AXObserver?
    private var observedApplication: AXUIElement?
    private var observedWindow: AXUIElement?
    private var pendingClamp: DispatchWorkItem?

    init(preferences: PreferencesStore) { self.preferences = preferences }

    isolated deinit {
        pendingClamp?.cancel()
        detach()
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
    }

    func start() {
        guard workspaceObserver == nil else { return }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      let app = NSWorkspace.shared.frontmostApplication else { return }
                self.attach(to: app)
                self.scheduleClamp()
            }
        }
        if let app = NSWorkspace.shared.frontmostApplication { attach(to: app) }
    }

    func fitAllWindowsToFreeSpace() {
        guard ensureAccessibility(), let context = context() else { return }
        if let app = NSWorkspace.shared.frontmostApplication { attach(to: app) }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let pids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != ownPID }
            .map(\.processIdentifier)
        axQueue.async {
            for pid in pids {
                Self.fitAllWindows(pid: pid, context: context)
            }
        }
    }

    fileprivate func handleAXNotification(_ name: String) {
        if name == kAXFocusedWindowChangedNotification {
            observeFocusedWindowResize()
        }
        scheduleClamp()
    }

    private func ensureAccessibility() -> Bool {
        guard !AXIsProcessTrusted() else { return true }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func attach(to app: NSRunningApplication) {
        detach()
        guard AXIsProcessTrusted(), app.activationPolicy == .regular, !app.isTerminated else { return }
        var createdObserver: AXObserver?
        guard AXObserverCreate(app.processIdentifier, windowFittingAXCallback, &createdObserver) == .success,
              let createdObserver else { return }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(
            createdObserver,
            application,
            kAXFocusedWindowChangedNotification as CFString,
            refcon
        ) == .success else { return }
        observer = createdObserver
        observedApplication = application
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(createdObserver), .defaultMode)
        observeFocusedWindowResize()
    }

    private func detach() {
        pendingClamp?.cancel()
        pendingClamp = nil
        if let observer, let observedWindow {
            _ = AXObserverRemoveNotification(observer, observedWindow, kAXMovedNotification as CFString)
            _ = AXObserverRemoveNotification(observer, observedWindow, kAXResizedNotification as CFString)
        }
        if let observer, let observedApplication {
            _ = AXObserverRemoveNotification(observer, observedApplication, kAXFocusedWindowChangedNotification as CFString)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observedWindow = nil
        observedApplication = nil
        observer = nil
    }

    private func observeFocusedWindowResize() {
        guard let observer, let application = observedApplication else { return }
        if let observedWindow {
            _ = AXObserverRemoveNotification(observer, observedWindow, kAXMovedNotification as CFString)
            _ = AXObserverRemoveNotification(observer, observedWindow, kAXResizedNotification as CFString)
        }
        guard let window = Self.element(application, attribute: kAXFocusedWindowAttribute as CFString) else {
            observedWindow = nil
            return
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        _ = AXObserverAddNotification(observer, window, kAXMovedNotification as CFString, refcon)
        _ = AXObserverAddNotification(observer, window, kAXResizedNotification as CFString, refcon)
        observedWindow = window
    }

    private func scheduleClamp() {
        pendingClamp?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.clampFrontmostApplication() }
        pendingClamp = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200), execute: work)
    }

    private func clampFrontmostApplication() {
        pendingClamp = nil
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.activationPolicy == .regular,
              let context = context() else { return }
        let pid = app.processIdentifier
        axQueue.async {
            Self.clampWindows(pid: pid, context: context)
        }
    }

    private func context() -> WindowFittingContext? {
        let screens = NSScreen.screens.map {
            WindowFittingScreenBox(frame: $0.frame, visibleFrame: $0.visibleFrame)
        }
        guard !screens.isEmpty else { return nil }
        let primaryHeight = screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height
            ?? screens[0].frame.height
        return WindowFittingContext(
            primaryHeight: primaryHeight,
            position: preferences.position,
            barHeight: CGFloat(preferences.barHeight),
            screens: screens
        )
    }

    nonisolated private static func fitAllWindows(pid: pid_t, context: WindowFittingContext) {
        let application = AXUIElementCreateApplication(pid)
        for window in windows(of: application) where isFittable(window, context: context) {
            guard let current = cocoaFrame(of: window, primaryHeight: context.primaryHeight),
                  let screen = WindowFittingGeometry.box(containing: current, in: context.screens) else { continue }
            let target = WindowFittingGeometry.freeRect(
                on: screen,
                position: context.position,
                barHeight: context.barHeight
            )
            setFrame(window, cocoaFrame: target, primaryHeight: context.primaryHeight)
        }
    }

    nonisolated private static func clampWindows(pid: pid_t, context: WindowFittingContext) {
        let application = AXUIElementCreateApplication(pid)
        for window in windows(of: application) where isFittable(window, context: context) {
            guard let current = cocoaFrame(of: window, primaryHeight: context.primaryHeight),
                  let screen = WindowFittingGeometry.box(containing: current, in: context.screens),
                  let target = WindowFittingGeometry.clampedRect(
                      current,
                      on: screen,
                      position: context.position,
                      barHeight: context.barHeight
                  ) else { continue }
            setFrame(window, cocoaFrame: target, primaryHeight: context.primaryHeight)
        }
    }

    nonisolated private static func isFittable(_ window: AXUIElement, context: WindowFittingContext) -> Bool {
        guard string(window, attribute: kAXSubroleAttribute as CFString) == kAXStandardWindowSubrole,
              !bool(window, attribute: kAXMinimizedAttribute as CFString),
              let frame = cocoaFrame(of: window, primaryHeight: context.primaryHeight) else { return false }
        return !WindowFittingGeometry.isFullScreen(frame, in: context.screens)
    }

    nonisolated private static func setFrame(
        _ window: AXUIElement,
        cocoaFrame: CGRect,
        primaryHeight: CGFloat
    ) {
        var position = WindowFittingGeometry.axPosition(cocoaFrame: cocoaFrame, primaryHeight: primaryHeight)
        var size = cocoaFrame.size
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else { return }
        _ = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        _ = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
    }

    nonisolated private static func cocoaFrame(of window: AXUIElement, primaryHeight: CGFloat) -> CGRect? {
        guard let position = point(window, attribute: kAXPositionAttribute as CFString),
              let size = size(window, attribute: kAXSizeAttribute as CFString) else { return nil }
        return WindowFittingGeometry.cocoaFrame(
            axPosition: position,
            size: size,
            primaryHeight: primaryHeight
        )
    }

    nonisolated private static func windows(of application: AXUIElement) -> [AXUIElement] {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &raw) == .success,
              let windows = raw as? [AXUIElement] else { return [] }
        return windows
    }

    nonisolated private static func element(_ element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success else { return nil }
        return raw as! AXUIElement?
    }

    nonisolated private static func string(_ element: AXUIElement, attribute: CFString) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success else { return nil }
        return raw as? String
    }

    nonisolated private static func bool(_ element: AXUIElement, attribute: CFString) -> Bool {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success else { return false }
        return raw as? Bool ?? false
    }

    nonisolated private static func point(_ element: AXUIElement, attribute: CFString) -> CGPoint? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success,
              let value = raw as! AXValue? else { return nil }
        var result = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &result) ? result : nil
    }

    nonisolated private static func size(_ element: AXUIElement, attribute: CFString) -> CGSize? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success,
              let value = raw as! AXValue? else { return nil }
        var result = CGSize.zero
        return AXValueGetValue(value, .cgSize, &result) ? result : nil
    }
}
