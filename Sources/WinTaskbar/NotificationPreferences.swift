import Foundation

struct NotificationCaptureRule: Codable, Equatable, Identifiable {
    var id = UUID()
    var enabled = true
    var appName = ""
    var messagePattern = ""

    var isEmpty: Bool {
        appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && messagePattern.isEmpty
    }

    var patternError: String? {
        guard !messagePattern.isEmpty else { return nil }
        do {
            _ = try NSRegularExpression(pattern: messagePattern)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func matches(app: String, message: String) -> Bool {
        guard enabled, !isEmpty else { return false }
        let name = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.isEmpty || app.localizedCaseInsensitiveContains(name) else { return false }
        guard !messagePattern.isEmpty else { return true }
        guard let expression = try? NSRegularExpression(pattern: messagePattern) else { return false }
        return expression.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)) != nil
    }
}

struct NotificationPreferences: Codable, Equatable {
    var enabled = false
    // Zero means retain until manually dismissed.
    var displaySeconds = 15
    var rules: [NotificationCaptureRule] = []

    func accepts(app: String, title: String, body: String) -> Bool {
        rules.isEmpty || rules.contains { $0.matches(app: app, message: title + "\n" + body) }
    }
}
