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

enum NotificationOutputKind: String, Codable, CaseIterable, Identifiable {
    case card, centerText, largeText, glow, countdown, sound, important

    var id: String { rawValue }

    var label: String {
        switch self {
        case .card: return NSLocalizedString("Bottom-right card", comment: "Notification output")
        case .centerText: return NSLocalizedString("Center text", comment: "Notification output")
        case .largeText: return NSLocalizedString("Large text", comment: "Notification output")
        case .glow: return NSLocalizedString("Full-screen glow", comment: "Notification output")
        case .countdown: return NSLocalizedString("Countdown bar", comment: "Notification output")
        case .sound: return NSLocalizedString("Sound and speech", comment: "Notification output")
        case .important: return NSLocalizedString("Important messages", comment: "Notification output")
        }
    }
}

struct NotificationOutputSettings: Codable, Equatable {
    var card = NotificationDisplayBehavior()
    var colorHex = "#FFCC05"
    var textTemplate = ""
    var durationSeconds: Double = 3
    var countdownSeconds: Double = 60
    var countdownPattern = ""
    var completionOutputs: Set<NotificationOutputKind> = [.largeText, .glow]
    var soundName = "Glass"
    var speechEnabled = false

    func countdownDuration(message: String) -> TimeInterval? {
        let seconds: Double
        if countdownPattern.isEmpty {
            seconds = countdownSeconds
        } else {
            guard let expression = try? NSRegularExpression(pattern: countdownPattern),
                  let match = expression.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: message),
                  let parsed = Double(message[range]) else { return nil }
            seconds = parsed
        }
        return seconds.isFinite && seconds > 0 ? min(86_400, seconds) : nil
    }
}

struct NotificationOutputs: Codable, Equatable {
    var enabled: Set<NotificationOutputKind> = [.card]
    var overrides: [NotificationOutputKind: NotificationOutputSettings] = [:]
    var cooldownSeconds: Double = 0
    // Stored rule field; controls reversible banner hiding, never notification deletion.
    var dismissSystemNotification = false

    func warnsAboutHiddenNotification(defaults: [NotificationOutputKind: NotificationOutputSettings]) -> Bool {
        let card = overrides[.card] ?? defaults[.card] ?? NotificationOutputSettings()
        return dismissSystemNotification && (!enabled.contains(.card) || card.card.mode == .hidden)
    }

    // Every key is present after NotificationPreferences resolves the rule against defaults.
    func settings(for kind: NotificationOutputKind) -> NotificationOutputSettings {
        overrides[kind] ?? NotificationOutputSettings()
    }

    var summary: String {
        let names = NotificationOutputKind.allCases.filter { enabled.contains($0) }.map(\.label)
        return names.isEmpty ? NSLocalizedString("Do not show", comment: "Notification outputs")
            : names.joined(separator: ", ")
    }
}

struct NotificationCaptureRule: Codable, Equatable, Identifiable {
    var id = UUID()
    var enabled = true
    var appName = ""
    var messagePattern = ""
    var outputs = NotificationOutputs()

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

    func captureGroups(in message: String) -> [String] {
        guard !messagePattern.isEmpty,
              let expression = try? NSRegularExpression(pattern: messagePattern),
              let match = expression.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)) else { return [] }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: message).map { String(message[$0]) } ?? ""
        }
    }
}

struct NotificationPresentationPreferences: Codable, Equatable {
    var centerX: Double = 0.5
    var centerY: Double = 0.7
    var largeX: Double = 0.5
    var largeY: Double = 0.5
    var countdownX: Double = 0.8
    var countdownY: Double = 0.7
    var importantX: Double = 0.8
    var importantY: Double = 0.35
    var importantWidth: Double = 380
    var importantHeight: Double = 360
    var centerFontSize: Double = 22
    var largeFontSize: Double = 44
    private var centerWidthOverride: Double?
    private var largeWidthOverride: Double?
    var centerMaximumWidth: Double {
        get { centerWidthOverride ?? 620 }
        set { centerWidthOverride = newValue }
    }
    var largeMaximumWidth: Double {
        get { largeWidthOverride ?? 900 }
        set { largeWidthOverride = newValue }
    }
    var alwaysOnTop = true
    var showInFullscreen = true
}

enum NotificationTextPresentation {
    static let maximumCharacters = 240

    static func displayText(_ text: String) -> String {
        let text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard let end = text.index(text.startIndex, offsetBy: maximumCharacters, limitedBy: text.endIndex),
              end < text.endIndex else { return text }
        return String(text[..<text.index(before: end)]) + "…"
    }
}

struct NotificationAlertPlan {
    let content: SystemNotificationContent
    let outputs: NotificationOutputs
    let countdownDuration: TimeInterval?
    let ruleID: String
    let captures: [String]

    func text(for kind: NotificationOutputKind) -> String {
        let template = outputs.settings(for: kind).textTemplate
        if template.isEmpty {
            if kind == .centerText || kind == .largeText {
                return [content.title, content.body].filter { !$0.isEmpty }.joined(separator: "：")
            }
            return content.title.isEmpty ? content.body : content.title
        }
        let expression = try? NSRegularExpression(pattern: #"\{(app|title|body|[1-9][0-9]*)\}"#)
        var rendered = ""
        var cursor = template.startIndex
        for match in expression?.matches(in: template, range: NSRange(template.startIndex..., in: template)) ?? [] {
            guard let fullRange = Range(match.range, in: template),
                  let keyRange = Range(match.range(at: 1), in: template) else { continue }
            rendered.append(contentsOf: template[cursor..<fullRange.lowerBound])
            let key = String(template[keyRange])
            switch key {
            case "app": rendered += content.appName
            case "title": rendered += content.title
            case "body": rendered += content.body
            default:
                if let number = Int(key), number <= captures.count {
                    rendered += captures[number - 1]
                } else {
                    rendered.append(contentsOf: template[fullRange])
                }
            }
            cursor = fullRange.upperBound
        }
        rendered.append(contentsOf: template[cursor...])
        return rendered
    }
}

struct NotificationPreferences: Codable, Equatable {
    var enabled = true
    var rules: [NotificationCaptureRule] = []
    var fallback = NotificationOutputs(dismissSystemNotification: true)
    var outputDefaults: [NotificationOutputKind: NotificationOutputSettings] = Dictionary(
        uniqueKeysWithValues: NotificationOutputKind.allCases.map { ($0, NotificationOutputSettings()) }
    )
    var presentation = NotificationPresentationPreferences()

    func outputs(app: String, title: String, body: String) -> NotificationOutputs {
        resolved(rules.first { $0.matches(app: app, message: title + "\n" + body) }?.outputs ?? fallback)
    }

    func plan(for content: SystemNotificationContent) -> NotificationAlertPlan {
        let message = content.title + "\n" + content.body
        let rule = rules.first { $0.matches(app: content.appName, message: message) }
        let selected = resolved(rule?.outputs ?? fallback)
        return NotificationAlertPlan(
            content: content, outputs: selected,
            countdownDuration: selected.enabled.contains(.countdown)
                ? selected.settings(for: .countdown).countdownDuration(message: message) : nil,
            ruleID: rule?.id.uuidString ?? "fallback", captures: rule?.captureGroups(in: message) ?? []
        )
    }

    private func resolved(_ selected: NotificationOutputs) -> NotificationOutputs {
        var result = selected
        result.overrides = Dictionary(uniqueKeysWithValues: NotificationOutputKind.allCases.map { kind in
            (kind, selected.overrides[kind] ?? outputDefaults[kind] ?? NotificationOutputSettings())
        })
        return result
    }
}
