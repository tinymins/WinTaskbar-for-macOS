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

// AX references stay on this serial worker. Only content and single-use tokens leave it.
actor SystemNotificationCapture {
    private struct Candidate {
        let window: AXUIElement
        let targetIdentity: String
        let processID: Int32
        let content: SystemNotificationContent
    }
    private struct Snapshot {
        var tree: NotificationAXNode?
        var elements: [String: AXUIElement] = [:]
        var incomplete = false
    }
    private struct Observation {
        let observer: AXObserver
        var elements: Set<AXUIElement> = []
    }
    private var observations: [Int32: Observation] = [:]
    private static let events = [kAXWindowCreatedNotification, kAXCreatedNotification,
                                 kAXLayoutChangedNotification, kAXValueChangedNotification]
    private var candidates: [UUID: Candidate] = [:]

    func stopObserving() {
        for observation in observations.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observation.observer), .commonModes)
        }
        observations.removeAll()
        candidates.removeAll()
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

    func scan() -> SystemNotificationScan {
        candidates.removeAll()
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
                let snapshot = readTree(window, deadline: deadline)
                result.unreadable = result.unreadable || snapshot.incomplete
                guard !snapshot.incomplete, let tree = snapshot.tree else { continue }
                let notifications = tree.notifications(processID: process.processIdentifier)
                result.notifications.append(contentsOf: notifications)
                if notifications.isEmpty, tree.containsNotification { result.unrecognized = true }
                for content in notifications {
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

    func dismiss(_ token: UUID, expected: SystemNotificationContent) -> SystemNotificationDismissalResult {
        guard !Task.isCancelled else { return .cancelled }
        guard let candidate = candidates.removeValue(forKey: token), candidate.content == expected else { return .changed }
        let snapshot = readTree(candidate.window, deadline: ProcessInfo.processInfo.systemUptime + 1.5)
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

    private func readTree(_ window: AXUIElement, deadline: TimeInterval) -> Snapshot {
        var snapshot = Snapshot()
        var visited: Set<AXUIElement> = []
        func read(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else {
                snapshot.incomplete = true
                return nil
            }
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, key as CFString, &value)
            if error == .success { return value }
            if error != .attributeUnsupported && error != .noValue { snapshot.incomplete = true }
            return nil
        }
        func walk(_ element: AXUIElement, depth: Int) -> NotificationAXNode? {
            guard depth <= 18, visited.count < 800, !Task.isCancelled,
                  ProcessInfo.processInfo.systemUptime < deadline else {
                snapshot.incomplete = true
                return nil
            }
            guard visited.insert(element).inserted else { return nil }
            let identity = String(CFHash(element))
            snapshot.elements[identity] = element
            let role = read(element, kAXRoleAttribute) as? String ?? ""
            let subrole = read(element, kAXSubroleAttribute) as? String ?? ""
            let identifier = read(element, kAXIdentifierAttribute) as? String ?? ""
            let value = read(element, kAXValueAttribute) as? String ?? ""
            let title = read(element, kAXTitleAttribute) as? String ?? ""
            let description = read(element, kAXDescriptionAttribute) as? String ?? ""
            let children = (read(element, kAXChildrenAttribute) as? [AXUIElement] ?? [])
                .compactMap { walk($0, depth: depth + 1) }
            return NotificationAXNode(identity: identity, role: role, subrole: subrole,
                                      identifier: identifier, value: value, title: title,
                                      description: description, children: children)
        }
        snapshot.tree = walk(window, depth: 0)
        return snapshot
    }
}
