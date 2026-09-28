import AppKit
import ApplicationServices
import Combine

enum TaskbarFullscreenMode: Equatable, Sendable {
    case normal
    case autoHide
    case hidden
}

private struct FocusedWindowSnapshot: Sendable {
    let processID: pid_t
    let isFullscreen: Bool
    let frame: CGRect?
}

private let fullscreenFocusChangedCallback: AXObserverCallback = { _, _, _, context in
    guard let context else { return }
    let service = Unmanaged<FullscreenAvoidanceService>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated { service.refresh() }
}

@MainActor
final class FullscreenAvoidanceService: ObservableObject {
    @Published private(set) var modesByDisplay: [CGDirectDisplayID: TaskbarFullscreenMode] = [:]
    @Published private(set) var shortcutsSuspended = false

    private let preferences: PreferencesStore
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var preferenceCancellable: AnyCancellable?
    private var focusedWindow: FocusedWindowSnapshot?
    private var observedPID: pid_t?
    private var focusObserver: AXObserver?
    private var focusObserverSource: CFRunLoopSource?
    private var observationGeneration = 0

    init(preferences: PreferencesStore) {
        self.preferences = preferences
    }

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        preferenceCancellable = preferences.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        refresh()
    }

    func mode(for screen: NSScreen) -> TaskbarFullscreenMode {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return .normal
        }
        return modesByDisplay[displayID] ?? .normal
    }

    func refresh() {
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        observeFocusedWindow(for: frontmostPID)
        observationGeneration &+= 1
        let generation = observationGeneration
        focusedWindow = focusedWindow?.processID == frontmostPID ? focusedWindow : nil
        updateState(frontmostPID: frontmostPID)
        guard let frontmostPID, frontmostPID != ProcessInfo.processInfo.processIdentifier else { return }
        Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                Self.readFocusedWindow(processID: frontmostPID)
            }.value
            guard let self, self.observationGeneration == generation else { return }
            self.focusedWindow = snapshot
            self.updateState(frontmostPID: frontmostPID)
        }
    }

    private func observeFocusedWindow(for processID: pid_t?) {
        guard observedPID != processID || (processID != nil && focusObserver == nil) else { return }
        if let focusObserverSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), focusObserverSource, .commonModes)
        }
        focusObserver = nil
        focusObserverSource = nil
        observedPID = processID
        guard let processID, processID != ProcessInfo.processInfo.processIdentifier else { return }
        var observer: AXObserver?
        guard AXObserverCreate(processID, fullscreenFocusChangedCallback, &observer) == .success,
              let observer else { return }
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.1)
        guard AXObserverAddNotification(
            observer,
            application,
            kAXFocusedWindowChangedNotification as CFString,
            Unmanaged.passUnretained(self).toOpaque()
        ) == .success else { return }
        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        focusObserver = observer
        focusObserverSource = source
    }

    private func updateState(frontmostPID: pid_t?) {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return }

        let screens: [(id: CGDirectDisplayID, bounds: CGRect)] = NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return nil
            }
            return (id, CGDisplayBounds(id))
        }
        var fullscreenApplications: [CGDirectDisplayID: Set<String>] = [:]
        var focusedVisibleWindowIsFullscreen: Bool?
        var focusedVisibleWindowFound = false
        var focusedSnapshotMatchesTopmostWindow = false
        for window in windows {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  pid != ProcessInfo.processInfo.processIdentifier,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  let application = NSRunningApplication(processIdentifier: pid),
                  let bundleID = application.bundleIdentifier else { continue }
            let coveredScreens = screens.filter { screen in
                bounds.minX <= screen.bounds.minX + 3
                    && bounds.minY <= screen.bounds.minY + 3
                    && bounds.maxX >= screen.bounds.maxX - 3
                    && bounds.maxY >= screen.bounds.maxY - 3
            }
            for screen in coveredScreens {
                fullscreenApplications[screen.id, default: []].insert(bundleID)
            }
            let matchesFocusedWindow = focusedWindow?.processID == pid
                && focusedWindow?.frame.map { focusedFrame in
                    abs(focusedFrame.minX - bounds.minX) <= 8
                        && abs(focusedFrame.minY - bounds.minY) <= 8
                        && abs(focusedFrame.maxX - bounds.maxX) <= 8
                        && abs(focusedFrame.maxY - bounds.maxY) <= 8
                } == true
            if pid == frontmostPID, !focusedVisibleWindowFound,
               bounds.width >= 100, bounds.height >= 100 {
                focusedVisibleWindowFound = true
                focusedSnapshotMatchesTopmostWindow = matchesFocusedWindow
                focusedVisibleWindowIsFullscreen = !coveredScreens.isEmpty
                    || (focusedWindow?.isFullscreen == true && matchesFocusedWindow)
            }
        }

        if let focusedWindow, focusedWindow.isFullscreen,
           let bundleID = NSRunningApplication(processIdentifier: focusedWindow.processID)?.bundleIdentifier,
           let frame = focusedWindow.frame,
           focusedSnapshotMatchesTopmostWindow {
            for screen in screens {
                let intersection = screen.bounds.intersection(frame)
                if intersection.width * intersection.height
                    >= screen.bounds.width * screen.bounds.height * 0.9 {
                    fullscreenApplications[screen.id, default: []].insert(bundleID)
                }
            }
        }

        let rules = Dictionary(preferences.fullscreenAppRules.map { ($0.bundleID, $0) }, uniquingKeysWith: { first, _ in first })
        var modes: [CGDirectDisplayID: TaskbarFullscreenMode] = [:]
        for (displayID, bundleIDs) in fullscreenApplications {
            if bundleIDs.contains(where: { rules[$0]?.hideTaskbarWhenFullscreen == true }) {
                modes[displayID] = .hidden
            } else if preferences.autoHideTaskbarInFullscreen {
                modes[displayID] = .autoHide
            }
        }
        if modesByDisplay != modes { modesByDisplay = modes }

        let focusedBundleID = frontmostPID.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
        let rule = focusedBundleID.flatMap { rules[$0] }
        let isFullscreen = focusedVisibleWindowIsFullscreen ?? false
        let suspended = isFullscreen
            ? rule?.disableShortcutsWhenFullscreen == true
            : rule?.disableShortcutsWhenWindowed == true
        if shortcutsSuspended != suspended { shortcutsSuspended = suspended }
    }

    nonisolated private static func readFocusedWindow(processID: pid_t) -> FocusedWindowSnapshot? {
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.15)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let windowValue else { return nil }
        let window = windowValue as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 0.15)
        var fullscreenValue: CFTypeRef?
        let fullscreen = AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullscreenValue) == .success
            && (fullscreenValue as? Bool == true)
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        var frame: CGRect?
        if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
           AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
           let positionValue, let sizeValue {
            var position = CGPoint.zero
            var size = CGSize.zero
            if AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
               AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) {
                frame = CGRect(origin: position, size: size)
            }
        }
        return FocusedWindowSnapshot(processID: processID, isFullscreen: fullscreen, frame: frame)
    }
}
