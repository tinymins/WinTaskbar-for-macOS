import Foundation

@MainActor
final class NotificationAlertSelfTest {
    private var failures = 0

    static func run() -> Bool {
        let suite = NotificationAlertSelfTest()
        let cases: [(String, () -> Void)] = [
            ("testFirstRuleAndFallbackKeepIndependentOutputs", suite.testFirstRuleAndFallbackKeepIndependentOutputs),
            ("testImportantMessagesUpdateAndClearOnlyInMemory", suite.testImportantMessagesUpdateAndClearOnlyInMemory),
            ("testCooldownAppliesAcrossSourcesButUpdatesImportant", suite.testCooldownAppliesAcrossSourcesButUpdatesImportant),
            ("testCountdownCompletesOnceWithoutRecursion", suite.testCountdownCompletesOnceWithoutRecursion),
            ("testCooldownDoesNotRestartCountdown", suite.testCooldownDoesNotRestartCountdown),
            ("testUnselectedOutputDoesNotRemoveExistingImportant", suite.testUnselectedOutputDoesNotRemoveExistingImportant),
            ("testInvalidCountdownPatternLeavesOtherOutputs", suite.testInvalidCountdownPatternLeavesOtherOutputs),
            ("testTemplateExpandsCapturesWithoutReinterpretingInsertedText", suite.testTemplateExpandsCapturesWithoutReinterpretingInsertedText),
            ("testSavedPreferencesExcludeRuntimeMessages", suite.testSavedPreferencesExcludeRuntimeMessages)
        ]
        for (name, run) in cases {
            let before = suite.failures
            run()
            print("DBM TEST \(suite.failures == before ? "PASSED" : "FAILED"): \(name)")
        }
        print("DBM TESTS: \(cases.count) cases, \(suite.failures) failures")
        return suite.failures == 0
    }

    private func check(_ condition: Bool, _ message: String = "Expected true", line: Int = #line) {
        if !condition {
            failures += 1
            print("  Line \(line): \(message)")
        }
    }

    private func checkEqual<T: Equatable>(_ actual: T, _ expected: T, line: Int = #line) {
        check(actual == expected, "Expected \(expected); got \(actual)", line: line)
    }

    private func content(_ id: String, app: String = "Messenger", title: String = "New message",
                         body: String = "Full message body") -> SystemNotificationContent {
        SystemNotificationContent(sourceID: id, appName: app, title: title, body: body)
    }

    private func plan(_ id: String, outputs: NotificationOutputs) -> NotificationAlertPlan {
        NotificationPreferences(fallback: outputs).plan(for: content(id))
    }

    private func testFirstRuleAndFallbackKeepIndependentOutputs() {
        let first = NotificationOutputs(enabled: [.glow, .important])
        let second = NotificationOutputs(enabled: [.card, .sound])
        let fallback = NotificationOutputs(enabled: [.card])
        var settings = NotificationPreferences(rules: [
            NotificationCaptureRule(appName: "mess", messagePattern: "(?i)urgent", outputs: first),
            NotificationCaptureRule(appName: "Messenger", outputs: second)
        ], fallback: fallback)
        let urgent = content("urgent", title: "URGENT release")
        let selected = settings.plan(for: urgent)
        checkEqual(selected.outputs, first)
        check(!selected.outputs.enabled.contains(.card), "Card disabled must not suppress glow")
        check(selected.outputs.enabled.contains(.glow))
        checkEqual(settings.plan(for: content("ordinary")).outputs, second)
        checkEqual(settings.plan(for: content("other", app: "Calendar")).outputs, fallback)
        settings.rules[0].enabled = false
        checkEqual(settings.plan(for: urgent).outputs, second)
        settings.rules[1].enabled = false
        checkEqual(settings.plan(for: urgent).outputs, fallback)
    }

    private func testImportantMessagesUpdateAndClearOnlyInMemory() {
        let runtime = NotificationAlertRuntime()
        let outputs = NotificationOutputs(enabled: [.important])
        let settings = NotificationPreferences(fallback: outputs)
        check(runtime.ingest(settings.plan(for: content("one", body: "First full body")), now: 1))
        checkEqual(runtime.important.count, 1)
        checkEqual(runtime.important.first?.text, "First full body")
        check(runtime.ingest(settings.plan(for: content("one", body: "Updated full body")), now: 2))
        checkEqual(runtime.important.count, 1)
        checkEqual(runtime.important.first?.text, "Updated full body")
        check(runtime.ingest(settings.plan(for: content("two", body: "Separate message")), now: 3))
        checkEqual(runtime.important.count, 2)
        runtime.removeImportant("one")
        checkEqual(runtime.important.map(\.id), ["two"])
        runtime.clear()
        check(runtime.important.isEmpty)
        check(runtime.countdowns.isEmpty)
        check(NotificationAlertRuntime().important.isEmpty, "A fresh runtime must not restore messages")
    }

    private func testCooldownAppliesAcrossSourcesButUpdatesImportant() {
        let runtime = NotificationAlertRuntime()
        let outputs = NotificationOutputs(enabled: [.largeText, .important], cooldownSeconds: 10)
        let settings = NotificationPreferences(rules: [NotificationCaptureRule(appName: "Messenger", outputs: outputs)])
        let first = settings.plan(for: content("one", body: "First"))
        let second = settings.plan(for: content("two", body: "Second"))
        check(runtime.ingest(first, now: 100))
        check(!runtime.ingest(second, now: 101), "A different source under the same rule is cooled down")
        checkEqual(runtime.important.map(\.text), ["First", "Second"])
        check(runtime.ingest(second, now: 110))
    }

    private func testCountdownCompletesOnceWithoutRecursion() {
        let runtime = NotificationAlertRuntime()
        let outputs = NotificationOutputs(enabled: [.countdown, .glow], countdownSeconds: 5,
                                          completionOutputs: [.largeText, .glow, .countdown])
        let scheduled = plan("countdown", outputs: outputs)
        checkEqual(scheduled.countdownDuration, 5)
        check(runtime.ingest(scheduled, now: 10))
        checkEqual(runtime.countdowns.count, 1)
        check(runtime.tick(now: 14.9).isEmpty)
        let completed = runtime.tick(now: 15)
        checkEqual(completed.count, 1)
        guard let completion = completed.first else { return }
        checkEqual(completion.outputs.enabled, [.largeText, .glow])
        checkEqual(completion.outputs.cooldownSeconds, 0)
        check(completion.countdownDuration == nil)
        check(runtime.ingest(completion, now: 15))
        check(runtime.countdowns.isEmpty, "Completion must not schedule itself")
        check(runtime.tick(now: 100).isEmpty, "Completion fires once")
    }

    private func testCooldownDoesNotRestartCountdown() {
        let runtime = NotificationAlertRuntime()
        let outputs = NotificationOutputs(enabled: [.countdown], countdownSeconds: 5, cooldownSeconds: 10)
        let settings = NotificationPreferences(rules: [NotificationCaptureRule(appName: "Messenger", outputs: outputs)])
        check(runtime.ingest(settings.plan(for: content("one")), now: 10))
        check(!runtime.ingest(settings.plan(for: content("two")), now: 11))
        check(!runtime.ingest(settings.plan(for: content("one", body: "Changed")), now: 12))
        checkEqual(runtime.countdowns.count, 1)
        checkEqual(runtime.countdowns.first?.deadline, 15)
        checkEqual(runtime.tick(now: 15).count, 1)
    }

    private func testUnselectedOutputDoesNotRemoveExistingImportant() {
        let runtime = NotificationAlertRuntime()
        check(runtime.ingest(plan("same", outputs: NotificationOutputs(enabled: [.important])), now: 1))
        check(runtime.ingest(plan("same", outputs: NotificationOutputs(enabled: [.glow])), now: 2))
        checkEqual(runtime.important.map(\.id), ["same"])
        let countdown = NotificationOutputs(enabled: [.countdown], countdownSeconds: 1,
                                            completionOutputs: [.glow])
        check(runtime.ingest(plan("same", outputs: countdown), now: 3))
        guard let completion = runtime.tick(now: 4).first else { return }
        check(runtime.ingest(completion, now: 4))
        checkEqual(runtime.important.map(\.id), ["same"])
    }

    private func testInvalidCountdownPatternLeavesOtherOutputs() {
        let runtime = NotificationAlertRuntime()
        let outputs = NotificationOutputs(enabled: [.countdown, .glow], countdownPattern: "in (\\d+) seconds")
        let invalid = plan("invalid", outputs: outputs)
        check(invalid.countdownDuration == nil)
        check(invalid.outputs.enabled.contains(.glow))
        check(runtime.ingest(invalid, now: 1))
        check(runtime.countdowns.isEmpty)
    }

    private func testTemplateExpandsCapturesWithoutReinterpretingInsertedText() {
        let outputs = NotificationOutputs(enabled: [.largeText],
                                          textTemplate: "{app}|{title}|{body}|{1}|{2}")
        let rule = NotificationCaptureRule(appName: "App", messagePattern: "(?s)(URGENT).*?(5)", outputs: outputs)
        let settings = NotificationPreferences(rules: [rule])
        let source = content("template", app: "App {body}", title: "URGENT {1}", body: "5 minutes left")
        checkEqual(settings.plan(for: source).text,
                   "App {body}|URGENT {1}|5 minutes left|URGENT|5")
    }

    private func testSavedPreferencesExcludeRuntimeMessages() {
        let runtime = NotificationAlertRuntime()
        let settings = NotificationPreferences(enabled: true, fallback: NotificationOutputs(enabled: [.important]))
        let privateContent = content("secret-source-8472", title: "secret-title-8472", body: "secret-body-8472")
        check(runtime.ingest(settings.plan(for: privateContent), now: 1))
        guard let data = try? JSONEncoder().encode(settings),
              let encoded = String(data: data, encoding: .utf8) else {
            check(false, "Preferences must encode")
            return
        }
        check(!encoded.contains("secret-source-8472"))
        check(!encoded.contains("secret-title-8472"))
        check(!encoded.contains("secret-body-8472"))
        checkEqual((try? JSONDecoder().decode(NotificationPreferences.self, from: data))?.fallback, settings.fallback)
        checkEqual(runtime.important.count, 1)
    }
}
