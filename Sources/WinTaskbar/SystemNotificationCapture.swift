import AppKit
import ApplicationServices

struct SystemNotificationContent: Equatable, Sendable {
    let sourceID: String
    let appName: String
    let title: String
    let body: String
}

struct SystemNotificationScan: Sendable {
    var notifications: [SystemNotificationContent] = []
    var unreadable = false
    var unrecognized = false
}

// The AX tree is read on a background worker; no AX actions are performed.
enum SystemNotificationCapture {
    private struct Node {
        let identity: CFHashCode
        let identifier: String
        let role: String
        let subrole: String
        let text: String
        let children: [Node]

        var containsNotification: Bool {
            subrole.hasPrefix("AXNotificationCenter") || identifier == "AXNotificationListItems"
                || children.contains { $0.containsNotification }
        }

        var textContent: String {
            if !text.isEmpty { return text }
            return children.filter { $0.role != kAXButtonRole && $0.role != kAXMenuButtonRole }
                .map(\.textContent).filter { !$0.isEmpty }.joined(separator: "\n")
        }

        func fields() -> [String: [String]] {
            if ["header", "title", "body"].contains(identifier) {
                return [identifier: [textContent]]
            }
            var result: [String: [String]] = [:]
            for child in children {
                for (key, values) in child.fields() { result[key, default: []].append(contentsOf: values) }
            }
            return result
        }

        func notifications(processID: pid_t) -> [SystemNotificationContent] {
            // Choose the innermost complete card, never combine different cards in a stack.
            let nested = children.flatMap { $0.notifications(processID: processID) }
            if !nested.isEmpty { return nested }
            let values = fields()
            guard let headers = values["header"], headers.count == 1,
                  let appName = headers.first, !appName.isEmpty,
                  (values["title"]?.count ?? 0) <= 1,
                  (values["body"]?.count ?? 0) <= 1 else { return [] }
            let title = values["title"]?.first ?? ""
            let body = values["body"]?.first ?? ""
            guard !title.isEmpty || !body.isEmpty else { return [] }
            return [SystemNotificationContent(
                sourceID: "\(processID):\(identity)", appName: appName, title: title, body: body
            )]
        }
    }

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

            func walk(_ element: AXUIElement, depth: Int) -> Node? {
                guard depth <= 18, visited.count < 800, ProcessInfo.processInfo.systemUptime < deadline else {
                    incomplete = true
                    return nil
                }
                guard visited.insert(element).inserted else { return nil }
                let role = read(element, kAXRoleAttribute) as? String ?? ""
                let subrole = read(element, kAXSubroleAttribute) as? String ?? ""
                let identifier = read(element, kAXIdentifierAttribute) as? String ?? ""
                var text = ""
                if role == kAXStaticTextRole || ["header", "title", "body"].contains(identifier) {
                    for key in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                        if let value = read(element, key) as? String, !value.isEmpty {
                            text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                            break
                        }
                    }
                }
                let children = (read(element, kAXChildrenAttribute) as? [AXUIElement] ?? [])
                    .compactMap { walk($0, depth: depth + 1) }
                return Node(identity: CFHash(element), identifier: identifier, role: role, subrole: subrole, text: text, children: children)
            }

            for window in windows {
                guard let tree = walk(window, depth: 0) else { continue }
                guard !incomplete else { continue }
                let notifications = tree.notifications(processID: process.processIdentifier)
                result.notifications.append(contentsOf: notifications)
                if notifications.isEmpty, tree.containsNotification { result.unrecognized = true }
            }
            result.unreadable = result.unreadable || incomplete
        }
        return result
    }
}
