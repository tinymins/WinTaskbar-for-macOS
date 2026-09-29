import Foundation

@MainActor
final class NotificationAlertSelfTest {
    private var failures = 0

    static func run() -> Bool {
        let suite = NotificationAlertSelfTest()
        let cases: [(String, () -> Void)] = [
            ("testTextIncludesBodyAndTruncatesWithoutSplittingCharacters", suite.testTextIncludesBodyAndTruncatesWithoutSplittingCharacters),
            ("testSourceApplicationRequiresUniqueExactName", suite.testSourceApplicationRequiresUniqueExactName),
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

    private func testTextIncludesBodyAndTruncatesWithoutSplittingCharacters() {
        let settings = NotificationPreferences()
        let full = settings.plan(for: content("text", title: "Sender", body: "Full message body"))
        checkEqual(full.text(for: .centerText), "Sender\nFull message body")
        checkEqual(full.text(for: .largeText), "Sender\nFull message body")
        checkEqual(full.text(for: .countdown), "Sender")
        checkEqual(settings.plan(for: content("body-only", title: "", body: "Body")).text(for: .largeText), "Body")
        checkEqual(settings.plan(for: content("title-only", title: "Title", body: "")).text(for: .centerText), "Title")
        checkEqual(NotificationTextPresentation.displayText("Title\nBody"), "Title\nBody")
        let emoji = "👩🏽‍💻"
        let limit = NotificationTextPresentation.maximumCharacters
        let exact = String(repeating: emoji, count: limit)
        checkEqual(NotificationTextPresentation.displayText(exact), exact)
        let clipped = NotificationTextPresentation.displayText(exact + "extra")
        checkEqual(clipped, String(repeating: emoji, count: limit - 1) + "…")
        var custom = NotificationOutputs(enabled: [.largeText])
        custom.overrides[.largeText] = NotificationOutputSettings(textTemplate: "{body}")
        checkEqual(NotificationPreferences(fallback: custom).plan(for: content("template", title: "Title", body: "Body")).text(for: .largeText), "Body")
    }

    private func testSourceApplicationRequiresUniqueExactName() {
        let first = URL(fileURLWithPath: "/Applications/Example.app")
        let second = URL(fileURLWithPath: "/Applications/Other.app")
        let candidates = [
            NotificationSourceApplicationPolicy.Candidate(url: first, names: ["Example", "示例"]),
            NotificationSourceApplicationPolicy.Candidate(url: first, names: ["Example"]),
            NotificationSourceApplicationPolicy.Candidate(url: second, names: ["Other"])
        ]
        checkEqual(NotificationSourceApplicationPolicy.applicationURL(named: " example ", candidates: candidates), first)
        checkEqual(NotificationSourceApplicationPolicy.applicationURL(named: "示例", candidates: candidates), first)
        checkEqual(NotificationSourceApplicationPolicy.applicationURL(named: "Exam", candidates: candidates), nil)
        checkEqual(NotificationSourceApplicationPolicy.applicationURL(named: "", candidates: candidates), nil)
        checkEqual(NotificationSourceApplicationPolicy.applicationURL(named: "Unknown", candidates: candidates), nil)
        let ambiguous = candidates + [.init(url: second, names: ["Example"])]
        checkEqual(NotificationSourceApplicationPolicy.applicationURL(named: "Example", candidates: ambiguous), nil)
    }

    private func testFirstRuleAndFallbackKeepIndependentOutputs() {
        var first = NotificationOutputs(enabled: [.glow, .important], overrides: [
            .important: NotificationOutputSettings(colorHex: "#AABBCC")
        ])
        first.dismissSystemNotification = true
        let second = NotificationOutputs(enabled: [.card, .sound])
        var fallback = NotificationOutputs(enabled: [.card])
        fallback.dismissSystemNotification = true
        var settings = NotificationPreferences(rules: [
            NotificationCaptureRule(appName: "mess", messagePattern: "(?i)urgent", outputs: first),
            NotificationCaptureRule(appName: "Messenger", outputs: second)
        ], fallback: fallback)
        settings.outputDefaults[.glow] = NotificationOutputSettings(colorHex: "#112233")
        settings.outputDefaults[.important] = NotificationOutputSettings(colorHex: "#445566")
        let urgent = content("urgent", title: "URGENT release")
        let selected = settings.plan(for: urgent)
        checkEqual(selected.outputs.enabled, first.enabled)
        check(selected.outputs.dismissSystemNotification)
        checkEqual(selected.outputs.settings(for: .glow).colorHex, "#112233")
        checkEqual(selected.outputs.settings(for: .important).colorHex, "#AABBCC")
        check(!selected.outputs.enabled.contains(.card), "Card disabled must not suppress glow")
        check(selected.outputs.enabled.contains(.glow))
        settings.outputDefaults[.glow] = NotificationOutputSettings(colorHex: "#778899")
        checkEqual(settings.plan(for: urgent).outputs.settings(for: .glow).colorHex, "#778899")
        checkEqual(settings.plan(for: urgent).outputs.settings(for: .important).colorHex, "#AABBCC")
        checkEqual(settings.plan(for: content("ordinary")).outputs.enabled, second.enabled)
        check(!settings.plan(for: content("ordinary")).outputs.dismissSystemNotification)
        checkEqual(settings.plan(for: content("other", app: "Calendar")).outputs.enabled, fallback.enabled)
        check(settings.plan(for: content("other", app: "Calendar")).outputs.dismissSystemNotification)
        settings.rules[0].enabled = false
        checkEqual(settings.plan(for: urgent).outputs.enabled, second.enabled)
        check(!settings.plan(for: urgent).outputs.dismissSystemNotification)
        settings.rules[1].enabled = false
        checkEqual(settings.plan(for: urgent).outputs.enabled, fallback.enabled)
        check(settings.plan(for: urgent).outputs.dismissSystemNotification)
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
        let outputs = NotificationOutputs(enabled: [.countdown, .glow], overrides: [
            .countdown: NotificationOutputSettings(countdownSeconds: 5,
                                                   completionOutputs: [.largeText, .glow, .countdown])
        ])
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
        let outputs = NotificationOutputs(enabled: [.countdown], overrides: [
            .countdown: NotificationOutputSettings(countdownSeconds: 5)
        ], cooldownSeconds: 10)
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
        let countdown = NotificationOutputs(enabled: [.countdown], overrides: [
            .countdown: NotificationOutputSettings(countdownSeconds: 1, completionOutputs: [.glow])
        ])
        check(runtime.ingest(plan("same", outputs: countdown), now: 3))
        guard let completion = runtime.tick(now: 4).first else { return }
        check(runtime.ingest(completion, now: 4))
        checkEqual(runtime.important.map(\.id), ["same"])
    }

    private func testInvalidCountdownPatternLeavesOtherOutputs() {
        let runtime = NotificationAlertRuntime()
        let outputs = NotificationOutputs(enabled: [.countdown, .glow], overrides: [
            .countdown: NotificationOutputSettings(countdownPattern: "in (\\d+) seconds")
        ])
        let invalid = plan("invalid", outputs: outputs)
        check(invalid.countdownDuration == nil)
        check(invalid.outputs.enabled.contains(.glow))
        check(runtime.ingest(invalid, now: 1))
        check(runtime.countdowns.isEmpty)
    }

    private func testTemplateExpandsCapturesWithoutReinterpretingInsertedText() {
        let outputs = NotificationOutputs(enabled: [.largeText], overrides: [
            .largeText: NotificationOutputSettings(textTemplate: "{app}|{title}|{body}|{1}|{2}")
        ])
        let rule = NotificationCaptureRule(appName: "App", messagePattern: "(?s)(URGENT).*?(5)", outputs: outputs)
        let settings = NotificationPreferences(rules: [rule])
        let source = content("template", app: "App {body}", title: "URGENT {1}", body: "5 minutes left")
        checkEqual(settings.plan(for: source).text(for: .largeText),
                   "App {body}|URGENT {1}|5 minutes left|URGENT|5")
    }

    private func testSavedPreferencesExcludeRuntimeMessages() {
        let runtime = NotificationAlertRuntime()
        var settings = NotificationPreferences(enabled: true, fallback: NotificationOutputs(enabled: [.important]))
        settings.outputDefaults[.important] = NotificationOutputSettings(colorHex: "#123456")
        settings.fallback.dismissSystemNotification = true
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
        let decoded = try? JSONDecoder().decode(NotificationPreferences.self, from: data)
        checkEqual(decoded?.fallback, settings.fallback)
        checkEqual(decoded?.fallback.dismissSystemNotification, true)
        checkEqual(decoded?.outputDefaults, settings.outputDefaults)
        checkEqual(decoded?.plan(for: privateContent).outputs.settings(for: .important).colorHex, "#123456")
        if var oldFields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let defaultsField = oldFields["outputDefaults"]
            oldFields.removeValue(forKey: "outputDefaults")
            if let oldData = try? JSONSerialization.data(withJSONObject: oldFields) {
                check((try? JSONDecoder().decode(NotificationPreferences.self, from: oldData)) == nil,
                      "Old preferences without outputDefaults must reset")
            } else {
                check(false, "Old preferences fixture must encode")
            }
            oldFields["outputDefaults"] = defaultsField
            if var fallbackFields = oldFields["fallback"] as? [String: Any] {
                fallbackFields.removeValue(forKey: "dismissSystemNotification")
                oldFields["fallback"] = fallbackFields
                if let oldData = try? JSONSerialization.data(withJSONObject: oldFields) {
                    check((try? JSONDecoder().decode(NotificationPreferences.self, from: oldData)) == nil,
                          "Preferences without the dismissal decision must reset")
                } else {
                    check(false, "Missing-dismissal fixture must encode")
                }
            } else {
                check(false, "Fallback JSON must be an object")
            }
        } else {
            check(false, "Preferences JSON must be an object")
        }
        checkEqual(runtime.important.count, 1)
    }
}
