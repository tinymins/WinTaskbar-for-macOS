import AppKit
import ApplicationServices

enum SystemNotificationOpenResult: Sendable {
    // AX success means the system accepted the action, not that another app completed routing.
    case handedOff, unavailable
}

// Shared by the capture worker and the isolated PoC. AX references never leave their owner.
struct NotificationOriginalAction {
    let element: AXUIElement
    let processID: Int32
    let identifier: String
    let content: SystemNotificationContent

    static func find(in snapshot: NotificationAXSnapshot, content: SystemNotificationContent, processID: Int32) -> NotificationOriginalAction? {
        guard !snapshot.incomplete, let tree = snapshot.tree else { return nil }
        var matches: [NotificationAXNode] = []
        func visit(_ node: NotificationAXNode) {
            if node.role == "AXGroup", node.subrole != "AXNotificationCenterAlertStack",
               content.sourceID == "\(processID):\(node.identity)",
               node.notifications(processID: processID) == [content] { matches.append(node) }
            for child in node.children { visit(child) }
        }
        visit(tree)
        guard matches.count == 1, let node = matches.first,
              let element = snapshot.elements[node.identity] else { return nil }
        return NotificationOriginalAction(element: element, processID: processID, identifier: node.identifier, content: content)
    }

    func press() -> SystemNotificationOpenResult {
        guard !Task.isCancelled, AXIsProcessTrusted() else { return .unavailable }
        let snapshot = NotificationAXSnapshot.read(element, deadline: ProcessInfo.processInfo.systemUptime + 0.5)
        guard !snapshot.incomplete,
              let current = Self.find(in: snapshot, content: content, processID: processID),
              current.identifier == identifier else { return .unavailable }
        var actions: CFArray?
        guard AXUIElementCopyActionNames(element, &actions) == .success,
              (actions as? [String] ?? []).contains(kAXPressAction) else { return .unavailable }
        guard !Task.isCancelled else { return .unavailable }
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success ? .handedOff : .unavailable
    }
}

struct NotificationAXSnapshot {
    var tree: NotificationAXNode?
    var elements: [String: AXUIElement] = [:]
    var incomplete = false

    static func read(_ window: AXUIElement, deadline: TimeInterval) -> NotificationAXSnapshot {
        var snapshot = NotificationAXSnapshot()
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
