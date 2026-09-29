import Foundation

struct ImportantMessage: Identifiable {
    let id: String
    var content: SystemNotificationContent
    var text: String
    var colorHex: String
    let receivedAt: Date
}

struct NotificationCountdown: Identifiable {
    let id: String
    var content: SystemNotificationContent
    var text: String
    var colorHex: String
    var deadline: TimeInterval
    var duration: TimeInterval
    var completionPlan: NotificationAlertPlan
}

@MainActor
final class NotificationAlertRuntime {
    private(set) var important: [ImportantMessage] = []
    private(set) var countdowns: [NotificationCountdown] = []
    private var lastAlertByRule: [String: TimeInterval] = [:]

    // Returns whether transient outputs should fire. Important entries still track content
    // changes during a rule's cooldown, while countdowns start only for accepted alerts.
    func ingest(_ plan: NotificationAlertPlan, now: TimeInterval, receivedAt: Date = Date()) -> Bool {
        let id = plan.content.sourceID
        if plan.outputs.enabled.contains(.important) {
            let settings = plan.outputs.settings(for: .important)
            let body = settings.textTemplate.isEmpty ? plan.content.body : plan.text(for: .important)
            important.removeAll { $0.id == id }
            important.insert(ImportantMessage(
                id: id, content: plan.content, text: body,
                colorHex: settings.colorHex, receivedAt: receivedAt
            ), at: 0)
        }

        let cooldown = plan.outputs.cooldownSeconds
        if cooldown.isFinite, cooldown > 0,
           let last = lastAlertByRule[plan.ruleID], now - last < cooldown {
            return false
        }
        if cooldown.isFinite, cooldown > 0 { lastAlertByRule[plan.ruleID] = now }

        if let duration = plan.countdownDuration {
            let settings = plan.outputs.settings(for: .countdown)
            var completionOutputs = plan.outputs
            completionOutputs.enabled = settings.completionOutputs.subtracting([.countdown])
            completionOutputs.cooldownSeconds = 0
            let completion = NotificationAlertPlan(
                content: plan.content, outputs: completionOutputs,
                countdownDuration: nil, ruleID: plan.ruleID, captures: plan.captures
            )
            let countdown = NotificationCountdown(
                id: id, content: plan.content, text: plan.text(for: .countdown),
                colorHex: settings.colorHex, deadline: now + duration,
                duration: duration, completionPlan: completion
            )
            if let index = countdowns.firstIndex(where: { $0.id == id }) {
                countdowns[index] = countdown
            } else {
                countdowns.append(countdown)
            }
        }
        return true
    }

    func tick(now: TimeInterval) -> [NotificationAlertPlan] {
        let expired = countdowns.filter { $0.deadline <= now }
        countdowns.removeAll { $0.deadline <= now }
        return expired.map(\.completionPlan)
    }

    func removeImportant(_ id: String) {
        important.removeAll { $0.id == id }
    }

    func removeCountdown(_ id: String) {
        countdowns.removeAll { $0.id == id }
    }

    func clear() {
        important.removeAll()
        countdowns.removeAll()
        lastAlertByRule.removeAll()
    }
}
