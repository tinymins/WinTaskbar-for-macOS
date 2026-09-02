import AppKit
import ApplicationServices
import Combine

struct TaskbarAttentionState: Equatable, Sendable {
    let pulseGeneration: Int
}

struct TaskbarAttentionTracker {
    private(set) var badges: [String: String] = [:]
    private(set) var states: [String: TaskbarAttentionState] = [:]
    private(set) var hasBaseline = false

    mutating func apply(_ newBadges: [String: String], activeBundleID: String?) {
        defer {
            badges = newBadges
            hasBaseline = true
        }

        guard hasBaseline else {
            states.removeAll()
            return
        }

        for (bundleID, badge) in newBadges where bundleID != activeBundleID {
            guard TaskbarAttentionPolicy.shouldRequest(previous: badges[bundleID], current: badge) else { continue }
            let generation = (states[bundleID]?.pulseGeneration ?? 0) + 1
            states[bundleID] = TaskbarAttentionState(pulseGeneration: generation)
        }
    }

    mutating func acknowledge(_ bundleID: String) {
        states.removeValue(forKey: bundleID)
    }

    mutating func retainRunning(_ runningBundleIDs: Set<String>) {
        states = states.filter { runningBundleIDs.contains($0.key) }
    }
}

struct TaskbarAttentionPolicy {
    static func shouldRequest(previous: String?, current: String?) -> Bool {
        guard let current else { return false }
        guard let previous else { return true }
        if let previousCount = Int(previous), let currentCount = Int(current) {
            return currentCount > previousCount
        }
        return current != previous
    }
}

private extension Notification.Name {
    static let dockBadgeAXValueDidChange = Notification.Name("WinTaskbar.DockBadgeAXValueDidChange")
}

private let dockBadgeAXCallback: AXObserverCallback = { _, _, _, _ in
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: .dockBadgeAXValueDidChange, object: nil)
    }
}

@MainActor
private final class DockBadgeAXMonitor {
    private var observer: AXObserver?
    private var elements: [AXUIElement] = []

    func start() {
        stop()
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }

        var createdObserver: AXObserver?
        guard AXObserverCreate(dock.processIdentifier, dockBadgeAXCallback, &createdObserver) == .success,
              let createdObserver else { return }

        observer = createdObserver
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(createdObserver), .defaultMode)
        observe(AXUIElementCreateApplication(dock.processIdentifier), depth: 0)
    }

    func stop() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        elements.removeAll()
    }

    private func observe(_ element: AXUIElement, depth: Int) {
        guard depth < 8, let observer else { return }
        elements.append(element)
        _ = AXObserverAddNotification(observer, element, kAXValueChangedNotification as CFString, nil)
        _ = AXObserverAddNotification(observer, element, kAXCreatedNotification as CFString, nil)
        _ = AXObserverAddNotification(observer, element, kAXUIElementDestroyedNotification as CFString, nil)

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return }
        children.forEach { observe($0, depth: depth + 1) }
    }
}

private struct BadgeReadResult: Sendable {
    let badges: [String: String]
    let sourceWasAvailable: Bool
}

@MainActor
final class DockBadgeService: ObservableObject {
    @Published private(set) var badges: [String: String] = [:]
    @Published private(set) var attentionStates: [String: TaskbarAttentionState] = [:]

    private let interval: TimeInterval
    private var tracker = TaskbarAttentionTracker()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?
    private var eventRefreshTask: Task<Void, Never>?
    private var refreshPending = false
    private let axMonitor = DockBadgeAXMonitor()
#if DEBUG
    private var demoTask: Task<Void, Never>?
    private var isDemoRunning = false
#endif

    init(interval: TimeInterval = 4) {
        self.interval = interval
        start()
    }

    isolated deinit {
        timer?.invalidate()
        refreshTask?.cancel()
        eventRefreshTask?.cancel()
#if DEBUG
        demoTask?.cancel()
#endif
        axMonitor.stop()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func acknowledge(_ bundleID: String) {
        tracker.acknowledge(bundleID)
        publishState()
    }

    func refresh() {
#if DEBUG
        guard !isDemoRunning else { return }
#endif
        guard refreshTask == nil else {
            refreshPending = true
            return
        }

        let bundleIDs = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .compactMap(\.bundleIdentifier)

        refreshTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                let lsappinfo = Self.readBadgesWithLSAppInfo(bundleIDs: bundleIDs)
                if lsappinfo.sourceWasAvailable { return lsappinfo.badges }
                return Self.readBadgesWithAccessibility()
            }.value

            guard let self, !Task.isCancelled else { return }
            let activeBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            tracker.apply(result, activeBundleID: activeBundleID)
            tracker.retainRunning(Set(bundleIDs))
            publishState()
            refreshTask = nil
            if refreshPending {
                refreshPending = false
                refresh()
            }
        }
    }

    private func publishState() {
        if badges != tracker.badges { badges = tracker.badges }
        if attentionStates != tracker.states { attentionStates = tracker.states }
    }

#if DEBUG
    func runAttentionDemo() {
        guard demoTask == nil,
              let target = NSWorkspace.shared.runningApplications.first(where: {
                  $0.activationPolicy == .regular
                      && !$0.isActive
                      && $0.bundleIdentifier != nil
                      && $0.bundleIdentifier != "com.apple.finder"
              })?.bundleIdentifier else {
            fputs("ATTENTION DEMO: no inactive regular application is available\n", stderr)
            return
        }

        refreshTask?.cancel()
        refreshTask = nil
        refreshPending = false
        eventRefreshTask?.cancel()
        eventRefreshTask = nil
        isDemoRunning = true
        demoTask = Task { [weak self] in
            guard let self else { return }
            print("ATTENTION DEMO: using \(target)")
            var sample = tracker.badges
            sample.removeValue(forKey: target)
            publishDemo(sample, activeBundleID: nil)

            let steps: [(String?, String?)] = [
                ("1", nil),
                ("2", nil),
                ("2", nil),
                ("1", nil),
                (nil, nil),
                ("1", target)
            ]
            for (badge, activeBundleID) in steps {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                if let badge { sample[target] = badge } else { sample.removeValue(forKey: target) }
                publishDemo(sample, activeBundleID: activeBundleID)
                if activeBundleID == target {
                    acknowledge(target)
                }
            }

            try? await Task.sleep(for: .seconds(1.5))
            isDemoRunning = false
            demoTask = nil
            refresh()
        }
    }

    private func publishDemo(_ sample: [String: String], activeBundleID: String?) {
        tracker.apply(sample, activeBundleID: activeBundleID)
        publishState()
    }
#endif

    nonisolated static func parseStatusLabel(_ label: String) -> String? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "0" else { return nil }
        let digits = trimmed.filter(\.isNumber)
        return digits.isEmpty ? trimmed : digits
    }

    nonisolated static func parseLSAppInfoOutput(_ output: String) -> String? {
        let marker = "\"label\"=\""
        guard let markerRange = output.range(of: marker) else { return nil }
        let valueStart = markerRange.upperBound
        guard let valueEnd = output[valueStart...].firstIndex(of: "\"") else { return nil }
        return parseStatusLabel(String(output[valueStart..<valueEnd]))
    }

    nonisolated static func parseLSAppInfoBatchOutput(
        _ output: String,
        bundleIDs: Set<String>
    ) -> [String: String]? {
        var result: [String: String] = [:]
        var currentBundleID: String?
        var receivedStatus = false
        let identifierPrefix = "\"CFBundleIdentifier\"=\""
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("\"CFBundleIdentifier\"=") {
                currentBundleID = nil
                if line.hasPrefix(identifierPrefix), line.hasSuffix("\"") {
                    let identifier = String(line.dropFirst(identifierPrefix.count).dropLast())
                    if bundleIDs.contains(identifier) { currentBundleID = identifier }
                }
            } else if line.hasPrefix("\"StatusLabel\"="), let bundleID = currentBundleID {
                currentBundleID = nil
                guard line.contains("\"label\"=\"") || line.hasSuffix("[ NULL ]") else { continue }
                receivedStatus = true
                result[bundleID] = parseLSAppInfoOutput(line)
            }
        }
        return receivedStatus ? result : nil
    }

    private func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didWakeNotification
        ] {
            observers.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self, name] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == NSWorkspace.didActivateApplicationNotification,
                       let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
                        self.acknowledge(bundleID)
                        return
                    }
                    if name == NSWorkspace.didLaunchApplicationNotification
                        || name == NSWorkspace.didTerminateApplicationNotification
                        || name == NSWorkspace.didWakeNotification {
                        self.axMonitor.start()
                    }
                    self.refresh()
                }
            })
        }

        observers.append(NotificationCenter.default.addObserver(
            forName: .dockBadgeAXValueDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleEventRefresh() }
        })
        axMonitor.start()
    }

    private func scheduleEventRefresh() {
        eventRefreshTask?.cancel()
        eventRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    nonisolated private static func readBadgesWithLSAppInfo(bundleIDs: [String]) -> BadgeReadResult {
        guard !bundleIDs.isEmpty else { return BadgeReadResult(badges: [:], sourceWasAvailable: true) }
        let executableURL = URL(fileURLWithPath: "/usr/bin/lsappinfo")
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return BadgeReadResult(badges: [:], sourceWasAvailable: false)
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = bundleIDs.flatMap { ["info", "-only", "CFBundleIdentifier,StatusLabel", "-app", $0] }
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            // An exited application can resolve to the frontmost app; trust the returned identity.
            if let text = String(data: data, encoding: .utf8),
               let badges = parseLSAppInfoBatchOutput(text, bundleIDs: Set(bundleIDs)) {
                return BadgeReadResult(badges: badges, sourceWasAvailable: true)
            }
        } catch {
            return BadgeReadResult(badges: [:], sourceWasAvailable: false)
        }
        return BadgeReadResult(badges: [:], sourceWasAvailable: false)
    }

    nonisolated private static func readBadgesWithAccessibility() -> [String: String] {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [:] }
        var result: [String: String] = [:]
        walk(AXUIElementCreateApplication(dock.processIdentifier), depth: 0, result: &result)
        return result
    }

    nonisolated private static func walk(_ element: AXUIElement, depth: Int, result: inout [String: String]) {
        guard depth < 8 else { return }
        if let label: String = attribute(element, "AXStatusLabel"),
           let url = elementURL(element),
           let bundleID = Bundle(url: url)?.bundleIdentifier,
           let parsed = parseStatusLabel(label) {
            result[bundleID] = parsed
        }
        let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
        children.forEach { walk($0, depth: depth + 1, result: &result) }
    }

    nonisolated private static func elementURL(_ element: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success else { return nil }
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }

    nonisolated private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
