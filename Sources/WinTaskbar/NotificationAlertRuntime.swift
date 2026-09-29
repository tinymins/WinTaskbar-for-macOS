import Foundation

struct ImportantMessage: Identifiable {
    let id: String
    var content: SystemNotificationContent
    var text: String
    var colorHex: String
    let createdAt: TimeInterval
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
    func ingest(_ plan: NotificationAlertPlan, now: TimeInterval) -> Bool {
        let id = plan.content.sourceID
        if plan.outputs.enabled.contains(.important) {
            let body = plan.outputs.textTemplate.isEmpty ? plan.content.body : plan.text
            if let index = important.firstIndex(where: { $0.id == id }) {
                important[index].content = plan.content
                important[index].text = body
                important[index].colorHex = plan.outputs.colorHex
            } else {
                important.append(ImportantMessage(
                    id: id, content: plan.content, text: body,
                    colorHex: plan.outputs.colorHex, createdAt: now
                ))
            }
        }

        let cooldown = plan.outputs.cooldownSeconds
        if cooldown.isFinite, cooldown > 0,
           let last = lastAlertByRule[plan.ruleID], now - last < cooldown {
            return false
        }
        if cooldown.isFinite, cooldown > 0 { lastAlertByRule[plan.ruleID] = now }

        if let duration = plan.countdownDuration {
            var completionOutputs = plan.outputs
            completionOutputs.enabled = plan.outputs.completionOutputs.subtracting([.countdown])
            completionOutputs.cooldownSeconds = 0
            let completion = NotificationAlertPlan(
                content: plan.content, outputs: completionOutputs, text: plan.text,
                countdownDuration: nil, ruleID: plan.ruleID
            )
            let countdown = NotificationCountdown(
                id: id, content: plan.content, text: plan.text,
                colorHex: plan.outputs.colorHex, deadline: now + duration,
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
