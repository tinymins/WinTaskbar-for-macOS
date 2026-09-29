import Foundation

final class NotificationDismissalSelfTest {
    private var failures = 0

    static func run() -> Bool {
        let suite = NotificationDismissalSelfTest()
        let cases: [(String, () -> Void)] = [
            ("testExactSingleCardOwner", suite.testExactSingleCardOwner),
            ("testRejectStackAndMultipleCards", suite.testRejectStackAndMultipleCards),
            ("testRejectIncompleteSibling", suite.testRejectIncompleteSibling),
            ("testRejectNonsemanticAndWindowOwners", suite.testRejectNonsemanticAndWindowOwners),
            ("testRejectAmbiguousOwners", suite.testRejectAmbiguousOwners),
            ("testChooseOnlyExplicitCloseActions", suite.testChooseOnlyExplicitCloseActions)
        ]
        for (name, run) in cases {
            let before = suite.failures
            run()
            print("DISMISSAL TEST \(suite.failures == before ? "PASSED" : "FAILED"): \(name)")
        }
        print("DISMISSAL TESTS: \(cases.count) cases, \(suite.failures) failures")
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

    private func text(_ value: String) -> NotificationAXNode {
        NotificationAXNode(identity: value, role: "AXStaticText", value: value)
    }

    private func card(_ id: String, title: String = "Sender", body: String = "Message",
                      description: String = "Example, Sender, Message") -> NotificationAXNode {
        NotificationAXNode(identity: id, role: "AXGroup", description: description,
                           children: [text(title), text(body)])
    }

    private func owner(_ id: String = "owner", subrole: String = "AXNotificationCenterBanner",
                       children: [NotificationAXNode]) -> NotificationAXNode {
        NotificationAXNode(identity: id, role: "AXGroup", subrole: subrole, children: children)
    }

    private func expected(_ id: String = "message") -> SystemNotificationContent {
        SystemNotificationContent(sourceID: "42:\(id)", appName: "Example", title: "Sender", body: "Message")
    }

    private func testExactSingleCardOwner() {
        let item = card("message")
        let banner = owner(children: [item])
        let tree = NotificationAXNode(identity: "window", role: "AXWindow", children: [banner])
        checkEqual(NotificationDismissalPolicy.targetIdentity(in: tree, for: expected(), processID: 42), "owner")
        checkEqual(NotificationDismissalPolicy.targetIdentity(in: tree, for: expected(), processID: 41), nil)
        checkEqual(NotificationDismissalPolicy.targetIdentity(in: tree,
            for: SystemNotificationContent(sourceID: "42:message", appName: "Example", title: "Sender", body: "Different"),
            processID: 42), nil)
    }

    private func testRejectStackAndMultipleCards() {
        let stack = owner(subrole: "AXNotificationCenterAlertStack", children: [card("message")])
        checkEqual(NotificationDismissalPolicy.targetIdentity(in: stack, for: expected(), processID: 42), nil)
        let nestedBanner = owner("nested", children: [card("message")])
        let stackWithBanner = owner(subrole: "AXNotificationCenterAlertStack", children: [nestedBanner])
        checkEqual(NotificationDismissalPolicy.targetIdentity(in: stackWithBanner, for: expected(), processID: 42), nil)
        let withStack = owner(children: [card("message"), stack])
        checkEqual(NotificationDismissalPolicy.targetIdentity(in: withStack, for: expected(), processID: 42), nil)
        let second = card("another", title: "Other", body: "Text", description: "Example, Other, Text")
        let multiple = owner(children: [card("message"), second])
        checkEqual(NotificationDismissalPolicy.targetIdentity(in: multiple, for: expected(), processID: 42), nil)
    }

    private func testRejectIncompleteSibling() {
        let unrecognized = card("incomplete", title: "Other", body: "Text",
                                description: "Example, Other, Missing body")
        let mixed = owner(children: [card("message"), unrecognized])
        // The parser returns the one valid card, but the owner also contains another card.
        checkEqual(mixed.notifications(processID: 42), [expected()])
        checkEqual(NotificationDismissalPolicy.targetIdentity(in: mixed, for: expected(), processID: 42), nil)
        let headerOnly = NotificationAXNode(identity: "partial", role: "AXGroup", children: [
            NotificationAXNode(identity: "source", role: "AXStaticText", identifier: "header", value: "Another app")
        ])
        let mixedFields = owner(children: [card("message"), headerOnly])
        checkEqual(mixedFields.notifications(processID: 42), [expected()])
        checkEqual(NotificationDismissalPolicy.targetIdentity(in: mixedFields, for: expected(), processID: 42), nil)
        let unknownTextGroup = NotificationAXNode(identity: "unknown", role: "AXGroup", children: [text("Unrecognized text")])
        let mixedUnknown = owner(children: [card("message"), unknownTextGroup])
        checkEqual(mixedUnknown.notifications(processID: 42), [expected()])
        checkEqual(NotificationDismissalPolicy.targetIdentity(in: mixedUnknown, for: expected(), processID: 42), nil)
    }

    private func testRejectNonsemanticAndWindowOwners() {
        let plain = owner(subrole: "", children: [card("message")])
        checkEqual(NotificationDismissalPolicy.targetIdentity(in: plain, for: expected(), processID: 42), nil)
        let window = NotificationAXNode(identity: "window", role: "AXWindow",
                                        subrole: "AXNotificationCenterAlert", children: [card("message")])
        checkEqual(NotificationDismissalPolicy.targetIdentity(in: window, for: expected(), processID: 42), nil)
        let unrelated = owner(subrole: "AXNotificationCenterAlertStack", children: [card("message")])
        checkEqual(NotificationDismissalPolicy.targetIdentity(in: unrelated, for: expected(), processID: 42), nil)
        let insideButton = NotificationAXNode(identity: "button", role: "AXButton", children: [
            owner(children: [card("message")])
        ])
        checkEqual(NotificationDismissalPolicy.targetIdentity(in: insideButton, for: expected(), processID: 42), nil)
        let labelled = NotificationAXNode(identity: "labelled", role: "AXGroup", children: [
            NotificationAXNode(identity: "header", role: "AXStaticText", identifier: "header", value: "Example"),
            NotificationAXNode(identity: "title", role: "AXStaticText", identifier: "title", value: "Sender"),
            NotificationAXNode(identity: "body", role: "AXStaticText", identifier: "body", value: "Message")
        ])
        let labelledOwner = owner(children: [labelled])
        checkEqual(NotificationDismissalPolicy.targetIdentity(in: labelledOwner, for: expected("labelled"), processID: 42),
                   "owner")
        var labelledWithUnknown = labelled
        labelledWithUnknown.children.append(NotificationAXNode(identity: "unknown", role: "AXGroup", children: [
            text("Unrecognized extra content")
        ]))
        let ownerWithUnknown = owner(children: [labelledWithUnknown])
        checkEqual(ownerWithUnknown.notifications(processID: 42), [expected("labelled")])
        checkEqual(NotificationDismissalPolicy.targetIdentity(in: ownerWithUnknown,
            for: expected("labelled"), processID: 42), nil)
    }

    private func testRejectAmbiguousOwners() {
        let duplicate = NotificationAXNode(identity: "window", role: "AXWindow", children: [
            owner("first", children: [card("message")]), owner("second", children: [card("message")])
        ])
        checkEqual(NotificationDismissalPolicy.targetIdentity(in: duplicate, for: expected(), processID: 42), nil)
    }

    private func testChooseOnlyExplicitCloseActions() {
        let actions = [
            NotificationDismissalAction(name: "AXPress", description: "Close"),
            NotificationDismissalAction(name: "Clear All", description: "Clear All"),
            NotificationDismissalAction(name: "Close", description: ""),
            NotificationDismissalAction(name: "AXCancel", description: "")
        ]
        checkEqual(NotificationDismissalPolicy.closeAction(actions: actions), "AXCancel")
        checkEqual(NotificationDismissalPolicy.closeAction(actions: [
            NotificationDismissalAction(name: "Close", description: "")
        ]), "Close")
        checkEqual(NotificationDismissalPolicy.closeAction(actions: [
            NotificationDismissalAction(name: "closeAction", description: " 關閉 ")
        ]), "closeAction")
        checkEqual(NotificationDismissalPolicy.closeAction(actions: [
            NotificationDismissalAction(name: "AXPress", description: "Close"),
            NotificationDismissalAction(name: "Clear All", description: "Close"),
            NotificationDismissalAction(name: "Clear Notifications", description: "Close"),
            NotificationDismissalAction(name: "清除所有通知", description: "关闭"),
            NotificationDismissalAction(name: "Open", description: "Close"),
            NotificationDismissalAction(name: "Body", description: "Open notification")
        ]), nil)
    }
}
