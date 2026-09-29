import AppKit
import ApplicationServices

extension Notification.Name {
    static let systemNotificationAXChanged = Notification.Name("WinTaskbar.SystemNotificationAXChanged")
}

private let systemNotificationAXCallback: AXObserverCallback = { _, _, _, _ in
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: .systemNotificationAXChanged, object: nil)
    }
}

struct SystemNotificationScan: Sendable {
    var notifications: [SystemNotificationContent] = []
    var unreadable = false
    var unrecognized = false
}

// AX content/action references stay on this serial worker. Reversible window placement
// has a separate synchronized owner so termination can restore it before the app exits.
actor SystemNotificationCapture {
    private struct BannerWindow {
        let window: AXUIElement
        let processID: Int32
        let contents: [SystemNotificationContent]
    }
    private nonisolated let bannerVisibility = NotificationBannerVisibility()
    private var bannerWindows: [BannerWindow] = []

    nonisolated func setBannerHidingEnabled(_ enabled: Bool) { bannerVisibility.setEnabled(enabled) }
    nonisolated func restoreBanners() { bannerVisibility.restoreAll() }

    private struct Observation {
        let observer: AXObserver
        var elements: Set<AXUIElement> = []
    }
    private var observations: [Int32: Observation] = [:]
    private static let events = [kAXWindowCreatedNotification, kAXCreatedNotification,
                                 kAXLayoutChangedNotification, kAXValueChangedNotification,
                                 kAXFocusedWindowChangedNotification]
    private var openTargets: [String: NotificationOriginalAction] = [:]

    func stopObserving() {
        for observation in observations.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observation.observer), .commonModes)
        }
        observations.removeAll()
        bannerWindows.removeAll()
        openTargets.removeAll()
    }

    private func observe(processID: Int32, elements: [AXUIElement]) {
        if observations[processID] == nil {
            var observer: AXObserver?
            guard AXObserverCreate(processID, systemNotificationAXCallback, &observer) == .success,
                  let observer else { return }
            observations[processID] = Observation(observer: observer)
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        guard var observation = observations[processID] else { return }
        let current = Set(elements)
        for element in observation.elements.subtracting(current) {
            for event in Self.events { AXObserverRemoveNotification(observation.observer, element, event as CFString) }
        }
        for element in current.subtracting(observation.elements) {
            for event in Self.events { AXObserverAddNotification(observation.observer, element, event as CFString, nil) }
        }
        observation.elements = current
        observations[processID] = observation
    }

    func scan(retaining contents: [SystemNotificationContent] = []) -> SystemNotificationScan {
        bannerWindows.removeAll()
        let retained = Dictionary(grouping: contents, by: \.sourceID)
        openTargets = openTargets.filter { retained[$0.key]?.contains($0.value.content) == true }
        var result = SystemNotificationScan()
        var liveWindows: [AXUIElement] = []
        var runningProcessIDs: Set<Int32> = []
        for bundleID in ["com.apple.UserNotificationCenter", "com.apple.notificationcenterui"] {
            guard !Task.isCancelled else { break }
            guard let process = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { continue }
            runningProcessIDs.insert(process.processIdentifier)
            let root = AXUIElementCreateApplication(process.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.15)
            var rawWindows: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &rawWindows)
            guard status == .success, let windows = rawWindows as? [AXUIElement] else {
                result.unreadable = true
                continue
            }
            observe(processID: process.processIdentifier, elements: [root] + windows)
            liveWindows.append(contentsOf: windows)
            guard isPassive(processID: process.processIdentifier) else {
                for window in windows { bannerVisibility.restore(window) }
                continue
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 1.5
            for window in windows {
                let snapshot = NotificationAXSnapshot.read(window, deadline: deadline)
                result.unreadable = result.unreadable || snapshot.incomplete
                guard !snapshot.incomplete, let tree = snapshot.tree else {
                    bannerVisibility.restore(window)
                    continue
                }
                let notifications = tree.notifications(processID: process.processIdentifier)
                result.notifications.append(contentsOf: notifications)
                bannerWindows.append(BannerWindow(window: window, processID: process.processIdentifier, contents: notifications))
                if notifications.isEmpty, tree.containsNotification { result.unrecognized = true }
                for content in notifications {
                    if let target = NotificationOriginalAction.find(in: snapshot, content: content, processID: process.processIdentifier) {
                        openTargets[content.sourceID] = target
                    }
                }
            }
        }
        for processID in Array(observations.keys) where !runningProcessIDs.contains(processID) {
            if let observation = observations.removeValue(forKey: processID) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observation.observer), .commonModes)
            }
        }
        bannerVisibility.restoreUnlisted(liveWindows)
        return result
    }

    // References are held only for currently displayed important messages / pending countdowns.
    // A fresh AX tree is always checked before invoking an original notification action.
    func open(_ expected: SystemNotificationContent) -> SystemNotificationOpenResult {
        guard !Task.isCancelled, AXIsProcessTrusted(),
              let original = openTargets[expected.sourceID], original.content == expected else { return .unavailable }
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        if case .handedOff = original.press() { return .handedOff }

        // Generic identifiers and matching text are not durable identities: repeated messages
        // can have identical contents. Only an identifier containing a UUID permits re-finding.
        guard original.identifier.range(of: #"(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#,
                                        options: .regularExpression) != nil else { return .unavailable }
        var matches: [NotificationOriginalAction] = []
        for bundleID in ["com.apple.UserNotificationCenter", "com.apple.notificationcenterui"] {
            guard let process = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
                  process.processIdentifier == original.processID else { continue }
            let root = AXUIElementCreateApplication(process.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.15)
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &raw) == .success,
                  let windows = raw as? [AXUIElement] else { return .unavailable }
            for window in windows {
                let current = NotificationAXSnapshot.read(window, deadline: deadline)
                guard !current.incomplete, let tree = current.tree else { return .unavailable }
                for content in tree.notifications(processID: process.processIdentifier) {
                    if let target = NotificationOriginalAction.find(in: current, content: content, processID: process.processIdentifier),
                       target.identifier == original.identifier { matches.append(target) }
                }
            }
        }
        guard matches.count == 1, let target = matches.first,
              target.content.appName == expected.appName, target.content.title == expected.title,
              target.content.body == expected.body else { return .unavailable }
        return target.press()
    }

    // Only move an entire shared window when every card in it opted in. Re-read
    // immediately before moving so a newly arrived unmatched card remains visible.
    func hideBanners(matching expected: [SystemNotificationContent]) -> Bool {
        var failed = false
        for candidate in bannerWindows {
            guard !Task.isCancelled else { bannerVisibility.restoreAll(); return false }
            guard isPassive(processID: candidate.processID) else {
                bannerVisibility.restore(candidate.window)
                continue
            }
            let requested = candidate.contents.filter { expected.contains($0) }
            guard !requested.isEmpty else { bannerVisibility.restore(candidate.window); continue }
            let snapshot = NotificationAXSnapshot.read(candidate.window, deadline: ProcessInfo.processInfo.systemUptime + 0.5)
            guard !snapshot.incomplete, let tree = snapshot.tree,
                  tree.notifications(processID: candidate.processID) == candidate.contents,
                  candidate.contents.allSatisfy({ expected.contains($0) }),
                  tree.containsOnlyNotificationCards(candidate.contents, processID: candidate.processID),
                  isPassive(processID: candidate.processID) else {
                bannerVisibility.restore(candidate.window)
                failed = true
                continue
            }
            if !bannerVisibility.hide(candidate.window) { failed = true }
        }
        return failed
    }

    private func isPassive(processID: Int32) -> Bool {
        guard NSRunningApplication(processIdentifier: processID)?.isActive == false else { return false }
        let root = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(root, 0.15)
        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute as CFString, &focused)
        return status == .noValue || status == .attributeUnsupported || (status == .success && focused == nil)
    }
}
