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
    var dismissalTokens: [String: UUID] = [:]
    var unreadable = false
    var unrecognized = false
}

enum SystemNotificationDismissalResult: Sendable {
    case closed, unsupported, changed, failed, cancelled
}

// AX references stay on this serial worker. Only content and single-use dismissal tokens leave it.
actor SystemNotificationCapture {
    private struct Candidate {
        let window: AXUIElement
        let targetIdentity: String
        let processID: Int32
        let content: SystemNotificationContent
    }
    private struct Observation {
        let observer: AXObserver
        var elements: Set<AXUIElement> = []
    }
    private var observations: [Int32: Observation] = [:]
    private static let events = [kAXWindowCreatedNotification, kAXCreatedNotification,
                                 kAXLayoutChangedNotification, kAXValueChangedNotification]
    private var candidates: [UUID: Candidate] = [:]
    private var openTargets: [String: NotificationOriginalAction] = [:]

    func stopObserving() {
        for observation in observations.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observation.observer), .commonModes)
        }
        observations.removeAll()
        candidates.removeAll()
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
        candidates.removeAll()
        let retained = Dictionary(grouping: contents, by: \.sourceID)
        openTargets = openTargets.filter { retained[$0.key]?.contains($0.value.content) == true }
        var result = SystemNotificationScan()
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
            let deadline = ProcessInfo.processInfo.systemUptime + 1.5
            for window in windows {
                let snapshot = NotificationAXSnapshot.read(window, deadline: deadline)
                result.unreadable = result.unreadable || snapshot.incomplete
                guard !snapshot.incomplete, let tree = snapshot.tree else { continue }
                let notifications = tree.notifications(processID: process.processIdentifier)
                result.notifications.append(contentsOf: notifications)
                if notifications.isEmpty, tree.containsNotification { result.unrecognized = true }
                for content in notifications {
                    if let target = NotificationOriginalAction.find(in: snapshot, content: content, processID: process.processIdentifier) {
                        openTargets[content.sourceID] = target
                    }
                    guard let identity = NotificationDismissalPolicy.targetIdentity(
                        in: tree, for: content, processID: process.processIdentifier
                    ) else { continue }
                    let token = UUID()
                    candidates[token] = Candidate(window: window, targetIdentity: identity,
                                                  processID: process.processIdentifier, content: content)
                    result.dismissalTokens[content.sourceID] = token
                }
            }
        }
        for processID in Array(observations.keys) where !runningProcessIDs.contains(processID) {
            if let observation = observations.removeValue(forKey: processID) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observation.observer), .commonModes)
            }
        }
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

    func dismiss(_ token: UUID, expected: SystemNotificationContent) -> SystemNotificationDismissalResult {
        guard !Task.isCancelled else { return .cancelled }
        guard let candidate = candidates.removeValue(forKey: token), candidate.content == expected else { return .changed }
        let snapshot = NotificationAXSnapshot.read(candidate.window, deadline: ProcessInfo.processInfo.systemUptime + 1.5)
        guard !Task.isCancelled else { return .cancelled }
        guard !snapshot.incomplete, let tree = snapshot.tree else { return .failed }
        guard NotificationDismissalPolicy.targetIdentity(in: tree, for: expected, processID: candidate.processID)
                == candidate.targetIdentity,
              let target = snapshot.elements[candidate.targetIdentity] else { return .changed }
        var rawActions: CFArray?
        guard AXUIElementCopyActionNames(target, &rawActions) == .success,
              let names = rawActions as? [String] else { return .unsupported }
        let actions = names.map { name in
            var description: CFString?
            AXUIElementCopyActionDescription(target, name as CFString, &description)
            return NotificationDismissalAction(name: name, description: description as String? ?? "")
        }
        guard let action = NotificationDismissalPolicy.closeAction(actions: actions) else { return .unsupported }
        guard !Task.isCancelled else { return .cancelled }
        return AXUIElementPerformAction(target, action as CFString) == .success ? .closed : .failed
    }
}
