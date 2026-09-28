import AppKit
import ApplicationServices

struct SystemNotificationScan: Sendable {
    var notifications: [SystemNotificationContent] = []
    var unreadable = false
    var unrecognized = false
}

// The AX tree is read on a background worker; no AX actions are performed.
enum SystemNotificationCapture {
    static func scan() -> SystemNotificationScan {
        var result = SystemNotificationScan()
        for bundleID in ["com.apple.UserNotificationCenter", "com.apple.notificationcenterui"] {
            guard let process = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { continue }
            let root = AXUIElementCreateApplication(process.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.15)
            var rawWindows: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &rawWindows)
            guard status == .success, let windows = rawWindows as? [AXUIElement] else {
                result.unreadable = true
                continue
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 1.5
            var visited: Set<AXUIElement> = []
            var incomplete = false

            func read(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    incomplete = true
                    return nil
                }
                var value: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(element, key as CFString, &value)
                if error == .success { return value }
                if error != .attributeUnsupported && error != .noValue { incomplete = true }
                return nil
            }

            func walk(_ element: AXUIElement, depth: Int) -> NotificationAXNode? {
                guard depth <= 18, visited.count < 800, ProcessInfo.processInfo.systemUptime < deadline else {
                    incomplete = true
                    return nil
                }
                guard visited.insert(element).inserted else { return nil }
                let role = read(element, kAXRoleAttribute) as? String ?? ""
                let subrole = read(element, kAXSubroleAttribute) as? String ?? ""
                let identifier = read(element, kAXIdentifierAttribute) as? String ?? ""
                let value = read(element, kAXValueAttribute) as? String ?? ""
                let title = read(element, kAXTitleAttribute) as? String ?? ""
                let description = read(element, kAXDescriptionAttribute) as? String ?? ""
                let children = (read(element, kAXChildrenAttribute) as? [AXUIElement] ?? [])
                    .compactMap { walk($0, depth: depth + 1) }
                return NotificationAXNode(identity: String(CFHash(element)), role: role, subrole: subrole,
                                          identifier: identifier, value: value, title: title,
                                          description: description, children: children)
            }

            for window in windows {
                incomplete = false
                visited.removeAll(keepingCapacity: true)
                let tree = walk(window, depth: 0)
                result.unreadable = result.unreadable || incomplete
                guard !incomplete, let tree else { continue }
                let notifications = tree.notifications(processID: process.processIdentifier)
                result.notifications.append(contentsOf: notifications)
                if notifications.isEmpty, tree.containsNotification { result.unrecognized = true }
            }
        }
        return result
    }
}
