import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
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

struct TaskbarAppPrimaryClickPolicy {
    static func showsPreviewsImmediately(windowCount: Int, previewsEnabled: Bool) -> Bool {
        previewsEnabled && windowCount > 1
    }
}

private enum AccessibilityWindowIdentity {
    private typealias GetWindowID = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    // AX has no public window-ID attribute. Resolve this SPI optionally so its
    // absence on a future macOS cannot prevent the application from launching.
    private static let getWindowID: GetWindowID? = {
        guard let handle = dlopen(nil, RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: GetWindowID.self)
    }()

    static var isAvailable: Bool { getWindowID != nil }

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        var windowID = kCGNullWindowID
        guard getWindowID?(element, &windowID) == .success,
              windowID != kCGNullWindowID else { return nil }
        return windowID
    }
}

struct WindowIdentityCandidate {
    let windowID: CGWindowID?
    let title: String?
    let frame: CGRect?
}

struct WindowIdentityPolicy {
    static func matchingIndex(for window: WindowInfo, in candidates: [WindowIdentityCandidate]) -> Int? {
        if let index = candidates.firstIndex(where: { $0.windowID == window.windowID }) { return index }
        let fallbackIndices = candidates.indices.filter { index in
            let candidate = candidates[index]
            guard candidate.windowID == nil,
                  let frame = candidate.frame,
                  abs(frame.minX - window.frame.minX) < 4,
                  abs(frame.minY - window.frame.minY) < 4,
                  abs(frame.width - window.frame.width) < 4,
                  abs(frame.height - window.frame.height) < 4 else { return false }
            return candidate.title == nil || candidate.title == window.title || window.title == "Window"
        }
        // Never guess which same-title/overlapping window to activate or close.
        return fallbackIndices.count == 1 ? fallbackIndices.first : nil
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

    @discardableResult
    func close(window: WindowInfo) -> Bool {
        guard let match = matchingWindow(for: window),
              let closeButton: AXUIElement = attribute(match, kAXCloseButtonAttribute) else { return false }
        return AXUIElementPerformAction(closeButton, kAXPressAction as CFString) == .success
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
        let elements = windows(of: AXUIElementCreateApplication(window.ownerPID))
        let candidates = elements.map { element in
            let windowID = AccessibilityWindowIdentity.windowID(of: element)
            return WindowIdentityCandidate(
                windowID: windowID,
                title: windowID == nil ? attribute(element, kAXTitleAttribute) : nil,
                frame: windowID == nil ? frame(of: element) : nil
            )
        }
        guard let index = WindowIdentityPolicy.matchingIndex(for: window, in: candidates) else { return nil }
        return elements[index]
    }

    private func isFocused(_ window: WindowInfo, in application: AXUIElement) -> Bool {
        guard let focusedWindow: AXUIElement = attribute(application, kAXFocusedWindowAttribute) else { return false }
        if let focusedWindowID = AccessibilityWindowIdentity.windowID(of: focusedWindow) {
            return focusedWindowID == window.windowID
        }
        guard let match = matchingWindow(for: window) else { return false }
        return CFEqual(match, focusedWindow)
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
        if let image = images.object(forKey: key) { return image }
        return refreshImage(for: windowID, capture: capture)
    }

    func refreshImage(for windowID: CGWindowID, capture: () -> NSImage?) -> NSImage? {
        let key = NSNumber(value: windowID)
        if let image = capture() {
            images.setObject(image, forKey: key)
            return image
        }
        return images.object(forKey: key)
    }
}

struct WindowAppearanceOrder {
    private var orderedWindowIDsByPID: [pid_t: [CGWindowID]] = [:]

    mutating func reconcile(observedWindowIDs: [CGWindowID], forPID pid: pid_t) -> [CGWindowID] {
        guard !observedWindowIDs.isEmpty else {
            orderedWindowIDsByPID.removeValue(forKey: pid)
            return []
        }

        let observedWindowIDSet = Set(observedWindowIDs)
        var orderedWindowIDs = (orderedWindowIDsByPID[pid] ?? []).filter(observedWindowIDSet.contains)
        var knownWindowIDs = Set(orderedWindowIDs)
        for windowID in observedWindowIDs where knownWindowIDs.insert(windowID).inserted {
            orderedWindowIDs.append(windowID)
        }
        orderedWindowIDsByPID[pid] = orderedWindowIDs
        return orderedWindowIDs
    }
}

@MainActor
final class WindowsService {
    private let thumbnailCache = WindowThumbnailCache()
    private var appearanceOrder = WindowAppearanceOrder()

    func windows(forPID pid: pid_t) -> [WindowInfo] {
        windows(forPIDs: [pid])[pid] ?? []
    }

    func windows(forPIDs pids: [pid_t]) -> [pid_t: [WindowInfo]] {
        let requestedPIDs = Set(pids)
        guard !requestedPIDs.isEmpty else { return [:] }
        guard let raw = CGWindowListCopyWindowInfo(WindowPreviewWindowPolicy.listOptions, kCGNullWindowID)
                as? [[String: Any]] else { return [:] }
        let candidates: [(pid: pid_t, windowID: CGWindowID, title: String, frame: CGRect, isOnScreen: Bool)]
        candidates = raw.compactMap { info in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  requestedPIDs.contains(ownerPID),
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
            return (ownerPID, windowID, title, frame, isOnScreen)
        }
        let observedWindowIDsByPID = Dictionary(grouping: candidates, by: \.pid).mapValues {
            $0.map(\.windowID)
        }

        var accessibilityWindowsByPID: [pid_t: [CGWindowID: Bool]] = [:]
        for pid in observedWindowIDsByPID.keys {
            accessibilityWindowsByPID[pid] = accessibilityWindowStates(forPID: pid)
        }
        var windowsByPID: [pid_t: [WindowInfo]] = [:]
        for candidate in candidates {
            guard WindowPreviewWindowPolicy.shouldInclude(
                windowID: candidate.windowID,
                isOnScreen: candidate.isOnScreen,
                accessibilityWindows: accessibilityWindowsByPID[candidate.pid]
            ) else { continue }
            windowsByPID[candidate.pid, default: []].append(WindowInfo(
                windowID: candidate.windowID,
                title: candidate.title,
                ownerPID: candidate.pid,
                frame: candidate.frame,
                isMinimized: accessibilityWindowsByPID[candidate.pid]?[candidate.windowID] ?? false
            ))
        }
        for pid in requestedPIDs {
            let orderedWindowIDs = appearanceOrder.reconcile(
                observedWindowIDs: observedWindowIDsByPID[pid] ?? [], forPID: pid
            )
            let currentWindowsByID = Dictionary(
                uniqueKeysWithValues: (windowsByPID[pid] ?? []).map { ($0.windowID, $0) }
            )
            let orderedWindows = orderedWindowIDs.compactMap { currentWindowsByID[$0] }
            if orderedWindows.isEmpty {
                windowsByPID.removeValue(forKey: pid)
            } else {
                windowsByPID[pid] = orderedWindows
            }
        }
        return windowsByPID
    }

    func cacheThumbnails(forPID pid: pid_t) {
        for window in windows(forPID: pid) {
            _ = thumbnailCache.refreshImage(for: window.windowID) {
                captureThumbnail(for: window)
            }
        }
    }

    func thumbnail(for window: WindowInfo) -> NSImage? {
        thumbnailCache.image(for: window.windowID) {
            captureThumbnail(for: window)
        }
    }

    private func captureThumbnail(for window: WindowInfo) -> NSImage? {
        guard !window.isMinimized else { return nil }
        guard let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            window.windowID,
            [.boundsIgnoreFraming, .bestResolution]
        ) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private func accessibilityWindowStates(forPID pid: pid_t) -> [CGWindowID: Bool]? {
        guard AccessibilityWindowIdentity.isAvailable else { return nil }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.1)
        var rawWindows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &rawWindows) == .success,
              let windows = rawWindows as? [AXUIElement] else { return nil }
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXMinimizedAttribute] as CFArray
        var states: [CGWindowID: Bool] = [:]
        for window in windows {
            AXUIElementSetMessagingTimeout(window, 0.1)
            var rawValues: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(window, names, [], &rawValues) == .success,
                  let values = rawValues as? [Any], values.count == 3 else { return nil }
            guard values[0] as? String == kAXWindowRole else { continue }
            let subrole = values[1] as? String
            guard subrole != kAXFloatingWindowSubrole else { continue }
            guard let windowID = AccessibilityWindowIdentity.windowID(of: window) else { return nil }
            states[windowID] = values[2] as? Bool ?? false
        }
        return states
    }
}

struct WindowPreviewWindowPolicy {
    static let listOptions: CGWindowListOption = [.excludeDesktopElements]

    static func shouldInclude(
        windowID: CGWindowID,
        isOnScreen: Bool,
        accessibilityWindows: [CGWindowID: Bool]?
    ) -> Bool {
        // Unavailable AX data is different from a successfully read empty list.
        guard let accessibilityWindows else { return isOnScreen }
        guard let isMinimized = accessibilityWindows[windowID] else { return false }
        return isOnScreen || isMinimized
    }
}

enum ProjectFolder {
    private static let markers: Set<String> = [
        ".git", ".svn", "package.json", "Package.swift", "Cargo.toml", "go.mod", "pyproject.toml",
        "pom.xml", "build.gradle", "tsconfig.json",
    ]

    static func resolve(forFile url: URL) -> URL {
        let startingFolder = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        return root(forFile: startingFolder) ?? startingFolder
    }

    static func root(forFile url: URL) -> URL? {
        var folder = url.standardizedFileURL
        let fileManager = FileManager.default
        while folder.path != "/" {
            if markers.contains(where: {
                fileManager.fileExists(atPath: folder.appendingPathComponent($0).path)
            }) {
                return folder
            }
            let parent = folder.deletingLastPathComponent()
            guard parent != folder else { break }
            folder = parent
        }
        return nil
    }
}

struct RecentDocumentsHistory {
    static func recording(
        bundleID: String,
        folder: String,
        in store: [String: [String]],
        limit: Int
    ) -> [String: [String]] {
        var result = store
        var values = result[bundleID] ?? []
        values.removeAll { $0 == folder }
        values.insert(folder, at: 0)
        result[bundleID] = Array(values.prefix(limit))
        return result
    }
}

@MainActor
final class RecentDocumentsService: ObservableObject {
    private static let storageKey = "winbar.recentProjects"
    private let defaults: UserDefaults
    private let maxPerApp = 10
    @Published private var store: [String: [String]]
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        store = defaults.dictionary(forKey: Self.storageKey) as? [String: [String]] ?? [:]
    }

    deinit {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  let bundleID = application.bundleIdentifier,
                  application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let documentURL = Self.focusedDocumentURL(pid: application.processIdentifier) else { return }
            let folder = ProjectFolder.resolve(forFile: documentURL).absoluteString
            Task { @MainActor [weak self] in
                self?.record(bundleID: bundleID, folder: folder)
            }
        }
    }

    func recentDocuments(forBundleID bundleID: String, limit: Int = 10) -> [RecentDocument] {
        (store[bundleID] ?? []).prefix(limit).compactMap { raw in
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

    nonisolated static func documentURL(from rawValue: String) -> URL? {
        guard !rawValue.isEmpty else { return nil }
        if rawValue.hasPrefix("file:") {
            guard let url = URL(string: rawValue), url.isFileURL else { return nil }
            return url
        }
        let url = URL(fileURLWithPath: rawValue)
        return url.isFileURL ? url : nil
    }

    private nonisolated static func focusedDocumentURL(pid: pid_t) -> URL? {
        let application = AXUIElementCreateApplication(pid)
        var focusedRaw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &focusedRaw
        ) == .success,
        let focusedRaw,
        CFGetTypeID(focusedRaw) == AXUIElementGetTypeID() else { return nil }

        let focusedWindow = focusedRaw as! AXUIElement
        var documentRaw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedWindow,
            kAXDocumentAttribute as CFString,
            &documentRaw
        ) == .success,
        let document = documentRaw as? String else { return nil }
        return documentURL(from: document)
    }

    private func record(bundleID: String, folder: String) {
        store = RecentDocumentsHistory.recording(
            bundleID: bundleID,
            folder: folder,
            in: store,
            limit: maxPerApp
        )
        defaults.set(store, forKey: Self.storageKey)
    }
}
