import Foundation

final class NotificationParserSelfTest {
    private var failures = 0

    static func run() -> Bool {
        let suite = NotificationParserSelfTest()
        let cases: [(String, () -> Void)] = [
            ("testScreenshotStructureWithoutFieldIdentifiers", suite.testScreenshotStructureWithoutFieldIdentifiers),
            ("testSiblingCardsKeepSeparateSourcesAndIdentities", suite.testSiblingCardsKeepSeparateSourcesAndIdentities),
            ("testPunctuationAndLineBreaksDoNotSplitSourceOrPayload", suite.testPunctuationAndLineBreaksDoNotSplitSourceOrPayload),
            ("testSingleTextAndMultipleBodyNodes", suite.testSingleTextAndMultipleBodyNodes),
            ("testControlLabelsAndTheirSubtreesAreNotNotifications", suite.testControlLabelsAndTheirSubtreesAreNotNotifications),
            ("testDescriptionAndVisibleTextTakePrecedenceOverAmbiguousIdentifiers", suite.testDescriptionAndVisibleTextTakePrecedenceOverAmbiguousIdentifiers),
            ("testExplicitSemanticFieldsRemainSupported", suite.testExplicitSemanticFieldsRemainSupported),
            ("testMissingSourceAndMismatchedSummaryAreNotGuessed", suite.testMissingSourceAndMismatchedSummaryAreNotGuessed),
            ("testIncompleteSiblingCardsCannotSupplyEachOthersFields", suite.testIncompleteSiblingCardsCannotSupplyEachOthersFields),
            ("testParsedContentsUseFirstMatchingRuleAndFallback", suite.testParsedContentsUseFirstMatchingRuleAndFallback)
        ]
        for (name, run) in cases {
            let before = suite.failures
            run()
            print("NOTIFICATION TEST \(suite.failures == before ? "PASSED" : "FAILED"): \(name)")
        }
        print("NOTIFICATION TESTS: \(cases.count) cases, \(suite.failures) failures")
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

    private func checkNil<T>(_ value: T?, line: Int = #line) {
        check(value == nil, "Expected nil; got \(String(describing: value))", line: line)
    }

    private func text(_ value: String, id: String = "", kind: String = "") -> NotificationAXNode {
        NotificationAXNode(identity: id, role: "AXStaticText", identifier: kind, value: value)
    }

    private func card(_ id: String, description: String, children: [NotificationAXNode]) -> NotificationAXNode {
        NotificationAXNode(identity: id, role: "AXGroup", description: description, children: children)
    }

    private func window(_ cards: [NotificationAXNode]) -> NotificationAXNode {
        NotificationAXNode(identity: "window", role: "AXWindow", title: "Notification Center", children: [
            NotificationAXNode(identity: "container", role: "AXGroup", children: [
                NotificationAXNode(identity: "scroll", role: "AXScrollArea", children: cards)
            ])
        ])
    }

    func testScreenshotStructureWithoutFieldIdentifiers() {
        // Same roles and attribute placement as the supplied screenshot; all text is synthetic.
        let root = window([card("message", description: "示例应用, 测试发送者, 测试内容", children: [
            text("测试发送者"), text("测试内容")
        ])])
        checkEqual(root.notifications(processID: 42), [
            SystemNotificationContent(sourceID: "42:message", appName: "示例应用", title: "测试发送者", body: "测试内容")
        ])
    }

    func testSiblingCardsKeepSeparateSourcesAndIdentities() {
        let root = window([
            card("calendar", description: "Calendar, Meeting, Room A", children: [text("Meeting"), text("Room A")]),
            card("chat", description: "消息客户端, 同事, 下午见", children: [text("同事"), text("下午见")])
        ])
        checkEqual(root.notifications(processID: 7), [
            SystemNotificationContent(sourceID: "7:calendar", appName: "Calendar", title: "Meeting", body: "Room A"),
            SystemNotificationContent(sourceID: "7:chat", appName: "消息客户端", title: "同事", body: "下午见")
        ])
    }

    func testPunctuationAndLineBreaksDoNotSplitSourceOrPayload() {
        let root = card("punctuation", description: "Build, Inc., Release, v2, Line one, with comma Line two，中文 ✅", children: [
            text("Release, v2"), text("Line one, with comma\nLine two，中文 ✅")
        ])
        checkEqual(root.notifications(processID: 1), [
            SystemNotificationContent(sourceID: "1:punctuation", appName: "Build, Inc.", title: "Release, v2",
                                      body: "Line one, with comma\nLine two，中文 ✅")
        ])
    }

    func testSingleTextAndMultipleBodyNodes() {
        let root = window([
            card("short", description: "Calendar, Starts now", children: [text("Starts now")]),
            card("long", description: "Reader, Chapter, Paragraph one, Paragraph two", children: [
                text("Chapter"), text("Paragraph one"), text("Paragraph two")
            ])
        ])
        checkEqual(root.notifications(processID: 1), [
            SystemNotificationContent(sourceID: "1:short", appName: "Calendar", title: "Starts now", body: ""),
            SystemNotificationContent(sourceID: "1:long", appName: "Reader", title: "Chapter", body: "Paragraph one\nParagraph two")
        ])
    }

    func testControlLabelsAndTheirSubtreesAreNotNotifications() {
        let button = NotificationAXNode(identity: "close", role: "AXButton", children: [
            text("Dismiss"), card("fake", description: "Button, Fake title, Fake body", children: [text("Fake title"), text("Fake body")])
        ])
        let root = card("real", description: "Reader, Title, Body", children: [text("Title"), button, text("Body")])
        checkEqual(root.notifications(processID: 1), [
            SystemNotificationContent(sourceID: "1:real", appName: "Reader", title: "Title", body: "Body")
        ])
        check(button.notifications(processID: 1).isEmpty)
    }

    func testDescriptionAndVisibleTextTakePrecedenceOverAmbiguousIdentifiers() {
        let root = card("message", description: "Messenger, Sender, Body", children: [
            text("Sender", kind: "header"), text("Body", kind: "body")
        ])
        checkEqual(root.notifications(processID: 1), [
            SystemNotificationContent(sourceID: "1:message", appName: "Messenger", title: "Sender", body: "Body")
        ])
    }

    func testExplicitSemanticFieldsRemainSupported() {
        let root = card("labelled", description: "", children: [
            text("Mail", kind: "header"), text("Subject", kind: "title"), text("Message", kind: "body"), text("now")
        ])
        checkEqual(root.notifications(processID: 2), [
            SystemNotificationContent(sourceID: "2:labelled", appName: "Mail", title: "Subject", body: "Message")
        ])
    }

    func testMissingSourceAndMismatchedSummaryAreNotGuessed() {
        let root = window([
            card("missing", description: "Title, Body", children: [text("Title"), text("Body")]),
            card("mismatch", description: "App, Title, Different body", children: [text("Title"), text("Body")])
        ])
        check(root.containsNotification)
        check(root.notifications(processID: 1).isEmpty)
    }

    func testIncompleteSiblingCardsCannotSupplyEachOthersFields() {
        let incompleteCards = [
            card("source-only", description: "App A, Missing content", children: [text("App A", kind: "header")]),
            card("payload-only", description: "App B, Unrecognized content", children: [
                text("Title B", kind: "title"), text("Body B", kind: "body")
            ])
        ]
        let root = window(incompleteCards)
        check(root.notifications(processID: 1).isEmpty, "Never fabricate App A + Title B + Body B from separate cards")
        let valid = card("complete", description: "Calendar, Meeting, Room A", children: [text("Meeting"), text("Room A")])
        checkEqual(window(incompleteCards + [valid]).notifications(processID: 1), [
            SystemNotificationContent(sourceID: "1:complete", appName: "Calendar", title: "Meeting", body: "Room A")
        ])
    }

    func testParsedContentsUseFirstMatchingRuleAndFallback() {
        let root = window([
            card("chat", description: "Messaging, Team, Urgent release", children: [text("Team"), text("Urgent release")]),
            card("calendar", description: "Calendar, Meeting, Room A", children: [text("Meeting"), text("Room A")])
        ])
        let parsed = root.notifications(processID: 1)
        checkEqual(parsed.count, 2)
        guard parsed.count == 2 else { return }
        let chat = parsed[0]
        let calendar = parsed[1]
        let persistent = NotificationDisplayBehavior(mode: .persistent)
        let hidden = NotificationDisplayBehavior(mode: .hidden)
        var settings = NotificationPreferences(rules: [
            NotificationCaptureRule(appName: "messag", messagePattern: "(?i)urgent", behavior: persistent),
            NotificationCaptureRule(appName: "Messaging", behavior: hidden)
        ])
        func behavior(_ content: SystemNotificationContent) -> NotificationDisplayBehavior {
            settings.behavior(app: content.appName, title: content.title, body: content.body)
        }
        checkEqual(behavior(chat), persistent)
        checkNil(behavior(chat).duration)
        checkEqual(behavior(calendar).duration, 15)
        settings.rules.swapAt(0, 1)
        checkEqual(behavior(chat).mode, .hidden)
        settings.rules[0].enabled = false
        checkEqual(behavior(chat), persistent)
        settings.rules[1].messagePattern = "does not match"
        checkEqual(behavior(chat), settings.fallback)
    }
}
