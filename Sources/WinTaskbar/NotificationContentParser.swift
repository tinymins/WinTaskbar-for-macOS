import Foundation

struct SystemNotificationContent: Equatable, Sendable {
    let sourceID: String
    let appName: String
    let title: String
    let body: String
}

// Keep AX attributes separate: a container's description is not its visible body text.
struct NotificationAXNode: Sendable {
    let identity: String
    let role: String
    var subrole = ""
    var identifier = ""
    var value = ""
    var title = ""
    var description = ""
    var children: [NotificationAXNode] = []

    var containsNotification: Bool {
        subrole.hasPrefix("AXNotificationCenter") || identifier == "AXNotificationListItems"
            || (role == "AXGroup" && !description.isEmpty && !textFields.isEmpty)
            || children.contains { $0.containsNotification }
    }

    private var isControl: Bool {
        ["AXButton", "AXMenuButton", "AXPopUpButton", "AXMenu", "AXTextField", "AXComboBox",
         "AXCheckBox", "AXRadioButton"].contains(role)
    }

    private struct TextField {
        let kind: String
        let text: String
    }

    private var ownText: String {
        [value, title, description].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    private var textFields: [TextField] {
        guard !isControl else { return [] }
        if ["header", "title", "body"].contains(identifier) {
            let text = ownText.isEmpty ? children.flatMap(\.textFields).map(\.text).joined(separator: "\n") : ownText
            return text.isEmpty ? [] : [TextField(kind: identifier, text: text)]
        }
        if role == "AXStaticText" {
            return ownText.isEmpty ? [] : [TextField(kind: "", text: ownText)]
        }
        return children.flatMap(\.textFields)
    }

    private var visibleTexts: [String] {
        guard !isControl else { return [] }
        if role == "AXStaticText" { return ownText.isEmpty ? [] : [ownText] }
        return children.flatMap(\.visibleTexts)
    }

    func notifications(processID: Int32) -> [SystemNotificationContent] {
        guard !isControl else { return [] }
        // Resolve individual cards before their containing stack. Never merge sibling cards.
        let nested = children.flatMap { $0.notifications(processID: processID) }
        if !nested.isEmpty { return nested }
        guard role == "AXGroup" || role == "AXWindow" else { return [] }

        let payload = visibleTexts
        let summary = Self.normalized(description)
        let suffix = ", " + payload.map(Self.normalized).joined(separator: ", ")
        let appName: String
        let title: String
        let body: String
        if role == "AXGroup", !payload.isEmpty, summary.hasSuffix(suffix) {
            // A system card describes itself as source + its visible text nodes. Match the
            // entire payload as a suffix; splitting on commas would corrupt message content.
            appName = String(summary.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            title = payload[0]
            body = payload.dropFirst().joined(separator: "\n")
        } else {
            let fields = textFields
            let headers = fields.filter { $0.kind == "header" }
            let titles = fields.filter { $0.kind == "title" }
            let bodies = fields.filter { $0.kind == "body" }
            guard headers.count == 1, titles.count <= 1, bodies.count <= 1 else { return [] }
            appName = headers[0].text
            title = titles.first?.text ?? ""
            body = bodies.first?.text ?? ""
        }
        guard !appName.isEmpty, !title.isEmpty || !body.isEmpty else { return [] }
        return [SystemNotificationContent(sourceID: "\(processID):\(identity)", appName: appName, title: title, body: body)]
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
