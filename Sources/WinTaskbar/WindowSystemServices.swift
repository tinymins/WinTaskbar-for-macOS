import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
final class WindowActivationService {
    func activateOrMinimize(_ item: TaskbarItem) {
        guard let pid = item.processIdentifier,
              let application = NSRunningApplication(processIdentifier: pid) else {
            NSWorkspace.shared.open(item.url)
            return
        }

        if application.isActive, hasVisibleWindow(pid: pid) {
            minimize(pid: pid)
        } else {
            application.activate(options: [.activateIgnoringOtherApps])
        }
    }

    func raise(window: WindowInfo) {
        guard let match = matchingWindow(for: window) else { return }
        AXUIElementSetAttributeValue(match, kAXMinimizedAttribute as CFString, false as CFBoolean)
        AXUIElementPerformAction(match, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: window.ownerPID)?.activate(options: [.activateIgnoringOtherApps])
    }

    func close(window: WindowInfo) {
        guard let match = matchingWindow(for: window),
              let closeButton: AXUIElement = attribute(match, kAXCloseButtonAttribute) else { return }
        AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
    }

    func hasVisibleWindow(pid: pid_t) -> Bool {
        windows(of: AXUIElementCreateApplication(pid)).contains { element in
            let minimized: Bool = attribute(element, kAXMinimizedAttribute) ?? false
            return !minimized
        }
    }

    func minimize(pid: pid_t) {
        let application = AXUIElementCreateApplication(pid)
        let candidates = windows(of: application)
        let main: AXUIElement? = attribute(application, kAXMainWindowAttribute)
        let target = main ?? candidates.first
        if let target {
            AXUIElementSetAttributeValue(target, kAXMinimizedAttribute as CFString, true as CFBoolean)
        }
    }

    func openNewWindow(_ item: TaskbarItem) {
        if item.isRunning {
            NSRunningApplication(processIdentifier: item.processIdentifier ?? 0)?.activate(options: [.activateIgnoringOtherApps])
            let source = CGEventSource(stateID: .hidSystemState)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 45, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 45, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    private func windows(of application: AXUIElement) -> [AXUIElement] {
        attribute(application, kAXWindowsAttribute) ?? []
    }

    private func matchingWindow(for window: WindowInfo) -> AXUIElement? {
        windows(of: AXUIElementCreateApplication(window.ownerPID)).first { element in
            let elementTitle: String? = attribute(element, kAXTitleAttribute)
            let elementFrame = frame(of: element)
            return elementTitle == window.title || elementFrame.map { framesMatch($0, window.frame) } == true
        }
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue: AXValue = attribute(element, kAXPositionAttribute),
              let sizeValue: AXValue = attribute(element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 4 && abs(lhs.minY - rhs.minY) < 4
            && abs(lhs.width - rhs.width) < 4 && abs(lhs.height - rhs.height) < 4
    }

    private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}

@MainActor
final class WindowsService {
    func windows(forPID pid: pid_t) -> [WindowInfo] {
        let minimizedWindowFrames = minimizedWindowFrames(forPID: pid)
        guard let raw = CGWindowListCopyWindowInfo(WindowPreviewWindowPolicy.listOptions, kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return raw.compactMap { info in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid,
                  let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  (info[kCGWindowLayer as String] as? Int ?? 0) == 0 else { return nil }
            let title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Window"
            let frame = CGRect(
                x: bounds["X"] ?? 0,
                y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0,
                height: bounds["Height"] ?? 0
            )
            guard frame.width > 80, frame.height > 50 else { return nil }
            let isOnScreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false
            guard WindowPreviewWindowPolicy.shouldInclude(
                isOnScreen: isOnScreen,
                frame: frame,
                minimizedWindowFrames: minimizedWindowFrames
            ) else { return nil }
            return WindowInfo(windowID: windowID, title: title, ownerPID: ownerPID, frame: frame)
        }
    }

    func thumbnail(for windowID: CGWindowID) -> NSImage? {
        guard let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        ) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private func minimizedWindowFrames(forPID pid: pid_t) -> [CGRect] {
        let application = AXUIElementCreateApplication(pid)
        let windows: [AXUIElement] = attribute(application, kAXWindowsAttribute) ?? []
        return windows.compactMap { window in
            let minimized: Bool = attribute(window, kAXMinimizedAttribute) ?? false
            guard minimized,
                  let positionValue: AXValue = attribute(window, kAXPositionAttribute),
                  let sizeValue: AXValue = attribute(window, kAXSizeAttribute) else { return nil }
            var origin = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(positionValue, .cgPoint, &origin),
                  AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
            return CGRect(origin: origin, size: size)
        }
    }

    private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}

struct WindowPreviewWindowPolicy {
    static let listOptions: CGWindowListOption = [.excludeDesktopElements]

    static func shouldInclude(
        isOnScreen: Bool,
        frame: CGRect,
        minimizedWindowFrames: [CGRect]
    ) -> Bool {
        isOnScreen || minimizedWindowFrames.contains { minimizedFrame in
            abs(minimizedFrame.minX - frame.minX) < 4
                && abs(minimizedFrame.minY - frame.minY) < 4
                && abs(minimizedFrame.width - frame.width) < 4
                && abs(minimizedFrame.height - frame.height) < 4
        }
    }
}

@MainActor
final class RecentDocumentsService {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func recentDocuments(forBundleID bundleID: String, limit: Int = 10) -> [RecentDocument] {
        let recentProjects = defaults.dictionary(forKey: "wintaskbar.recentProjects") as? [String: [String]]
        return (recentProjects?[bundleID] ?? []).prefix(limit).compactMap { raw in
            guard let url = URL(string: raw) else { return nil }
            let label = url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent
            return RecentDocument(url: url, label: label)
        }
    }

    func open(_ document: RecentDocument, with item: TaskbarItem) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([document.url], withApplicationAt: item.url, configuration: configuration)
    }
}
