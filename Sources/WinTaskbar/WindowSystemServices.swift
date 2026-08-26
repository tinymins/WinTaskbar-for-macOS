import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum TaskbarAppClickAction: Equatable {
    case activateApplication
    case doNothing
    case restoreWindow
    case minimizeWindow
    case bringWindowToFront
}

struct TaskbarAppClickPolicy {
    static func action(
        windows: [WindowInfo],
        isApplicationActive: Bool,
        isSingleWindowFocused: Bool
    ) -> TaskbarAppClickAction {
        guard windows.count == 1, let window = windows.first else {
            return windows.isEmpty ? .activateApplication : .doNothing
        }
        if window.isMinimized { return .restoreWindow }
        if isApplicationActive && isSingleWindowFocused { return .minimizeWindow }
        return .bringWindowToFront
    }
}

@MainActor
final class WindowActivationService {
    private let windowsService: WindowsService

    init(windowsService: WindowsService) {
        self.windowsService = windowsService
    }

    func activateOrMinimize(_ item: TaskbarItem) {
        guard let pid = item.processIdentifier,
              let application = NSRunningApplication(processIdentifier: pid) else {
            NSWorkspace.shared.open(item.url)
            return
        }

        let windows = windowsService.windows(forPID: pid)
        let applicationElement = AXUIElementCreateApplication(pid)
        let isSingleWindowFocused = windows.first.map {
            windows.count == 1 && isFocused($0, in: applicationElement)
        } ?? false

        switch TaskbarAppClickPolicy.action(
            windows: windows,
            isApplicationActive: application.isActive,
            isSingleWindowFocused: isSingleWindowFocused
        ) {
        case .activateApplication:
            application.activate(options: [.activateIgnoringOtherApps])
        case .doNothing:
            break
        case .restoreWindow, .bringWindowToFront:
            raise(window: windows[0])
        case .minimizeWindow:
            windowsService.cacheThumbnails(forPID: pid)
            minimize(window: windows[0])
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

    func minimize(window: WindowInfo) {
        guard let match = matchingWindow(for: window) else { return }
        AXUIElementSetAttributeValue(match, kAXMinimizedAttribute as CFString, true as CFBoolean)
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
        windows(of: AXUIElementCreateApplication(window.ownerPID)).first { matches($0, window) }
    }

    private func isFocused(_ window: WindowInfo, in application: AXUIElement) -> Bool {
        guard let focusedWindow: AXUIElement = attribute(application, kAXFocusedWindowAttribute) else { return false }
        return matches(focusedWindow, window)
    }

    private func matches(_ element: AXUIElement, _ window: WindowInfo) -> Bool {
        let elementTitle: String? = attribute(element, kAXTitleAttribute)
        let elementFrame = frame(of: element)
        return elementTitle == window.title || elementFrame.map { framesMatch($0, window.frame) } == true
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
final class WindowThumbnailCache {
    private let images = NSCache<NSNumber, NSImage>()

    init() {
        images.countLimit = 32
    }

    func image(for windowID: CGWindowID, capture: () -> NSImage?) -> NSImage? {
        let key = NSNumber(value: windowID)
        if let image = capture() {
            images.setObject(image, forKey: key)
            return image
        }
        return images.object(forKey: key)
    }
}

@MainActor
final class WindowsService {
    private let thumbnailCache = WindowThumbnailCache()

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
            return WindowInfo(
                windowID: windowID,
                title: title,
                ownerPID: ownerPID,
                frame: frame,
                isMinimized: !isOnScreen
            )
        }
    }

    func cacheThumbnails(forPID pid: pid_t) {
        for window in windows(forPID: pid) {
            _ = thumbnail(for: window)
        }
    }

    func thumbnail(for window: WindowInfo) -> NSImage? {
        thumbnailCache.image(for: window.windowID) {
            guard !window.isMinimized else { return nil }
            guard let image = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                window.windowID,
                [.boundsIgnoreFraming, .bestResolution]
            ) else { return nil }
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
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
