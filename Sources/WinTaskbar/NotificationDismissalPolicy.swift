import Foundation

struct NotificationDismissalAction {
    let name: String
    let description: String
}

enum NotificationDismissalPolicy {
    static func targetIdentity(in tree: NotificationAXNode, for content: SystemNotificationContent,
                               processID: Int32) -> String? {
        var matches: [String] = []

        func visit(_ node: NotificationAXNode) {
            guard !isControl(node), node.subrole != "AXNotificationCenterAlertStack" else { return }
            if node.role != "AXWindow",
               node.subrole == "AXNotificationCenterBanner" || node.subrole == "AXNotificationCenterAlert",
               !containsStack(in: node), cardCount(in: node) == 1,
               node.notifications(processID: processID) == [content] {
                matches.append(node.identity)
            }
            for child in node.children { visit(child) }
        }

        visit(tree)
        return matches.count == 1 ? matches[0] : nil
    }

    static func closeAction(actions: [NotificationDismissalAction]) -> String? {
        if let cancel = actions.first(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == "AXCancel" }) {
            return cancel.name
        }
        return actions.first { action in
            let name = action.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = name.lowercased()
            guard name != "AXPress", !["clear", "open", "show", "default", "remove all"].contains(where: lower.hasPrefix),
                  !["清除", "清空", "全部", "打开", "打開"].contains(where: name.contains) else {
                return false
            }
            return isCloseLabel(name) || isCloseLabel(action.description.trimmingCharacters(in: .whitespacesAndNewlines))
        }?.name
    }

    private static func isCloseLabel(_ text: String) -> Bool {
        text.localizedCaseInsensitiveCompare("Close") == .orderedSame || text == "关闭" || text == "關閉"
    }

    private static func containsStack(in node: NotificationAXNode) -> Bool {
        node.subrole == "AXNotificationCenterAlertStack" || node.children.contains { containsStack(in: $0) }
    }

    private static func cardCount(in node: NotificationAXNode) -> Int {
        guard !isControl(node) else { return 0 }
        guard !["header", "title", "body"].contains(node.identifier) else { return 0 }
        let children = node.children.reduce(0) { $0 + cardCount(in: $1) }
        if isLabelledCard(node) {
            // Explicit fields do not consume anonymous text. The parser ignores that text,
            // so an extra group must make this owner ineligible for dismissal.
            return 1 + children
        }
        if isDescribedCard(node) {
            // A card may wrap its own title/body in anonymous groups. Treat those as one
            // card, but count every sibling when another explicit card lies below it.
            return node.children.contains { containsExplicitCard(in: $0) } ? children : 1
        }
        if children > 0 { return children }
        // Unknown visible groups may be incomplete sibling cards. Fail closed.
        return node.role == "AXGroup" && containsVisibleText(in: node) ? 1 : 0
    }

    private static func isExplicitCard(_ node: NotificationAXNode) -> Bool {
        isLabelledCard(node) || isDescribedCard(node)
    }

    private static func isLabelledCard(_ node: NotificationAXNode) -> Bool {
        node.role == "AXGroup" && !["header", "title", "body"].contains(node.identifier)
            && node.children.contains { !isControl($0) && ["header", "title", "body"].contains($0.identifier) }
    }

    private static func isDescribedCard(_ node: NotificationAXNode) -> Bool {
        node.role == "AXGroup" && !["header", "title", "body"].contains(node.identifier)
            && !node.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && containsVisibleText(in: node)
    }

    private static func containsExplicitCard(in node: NotificationAXNode) -> Bool {
        guard !isControl(node), !["header", "title", "body"].contains(node.identifier) else { return false }
        return isExplicitCard(node) || node.children.contains { containsExplicitCard(in: $0) }
    }

    private static func containsVisibleText(in node: NotificationAXNode) -> Bool {
        guard !isControl(node) else { return false }
        return (node.role == "AXStaticText" && ![node.value, node.title, node.description].allSatisfy(\.isEmpty))
            || node.children.contains { containsVisibleText(in: $0) }
    }

    private static func isControl(_ node: NotificationAXNode) -> Bool {
        ["AXButton", "AXMenuButton", "AXPopUpButton", "AXMenu", "AXTextField", "AXComboBox",
         "AXCheckBox", "AXRadioButton"].contains(node.role)
    }
}
