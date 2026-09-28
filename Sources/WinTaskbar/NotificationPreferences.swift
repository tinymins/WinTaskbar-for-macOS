import Foundation

struct NotificationDisplayBehavior: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable {
        case hidden, timed, persistent

        var label: String {
            switch self {
            case .hidden: return "Do not show"
            case .timed: return "Hide after a delay"
            case .persistent: return "Keep until dismissed"
            }
        }
    }

    var mode: Mode = .timed
    var seconds = 15

    var duration: TimeInterval? {
        mode == .timed ? TimeInterval(min(3600, max(1, seconds))) : nil
    }

    var summary: String {
        mode == .timed
            ? String(format: NSLocalizedString("Hide after %ld seconds", comment: "Notification rule behavior"), Int(duration ?? 15))
            : NSLocalizedString(mode.label, comment: "Notification rule behavior")
    }
}

struct NotificationCaptureRule: Codable, Equatable, Identifiable {
    var id = UUID()
    var enabled = true
    var appName = ""
    var messagePattern = ""
    var behavior = NotificationDisplayBehavior()

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
    var rules: [NotificationCaptureRule] = []
    var fallback = NotificationDisplayBehavior()

    func behavior(app: String, title: String, body: String) -> NotificationDisplayBehavior {
        rules.first { $0.matches(app: app, message: title + "\n" + body) }?.behavior ?? fallback
    }
}
