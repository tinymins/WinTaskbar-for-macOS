import AppKit
import ApplicationServices
import Combine

@MainActor
final class DockBadgeService: ObservableObject {
    @Published private(set) var badges: [String: String] = [:]
    private var timer: Timer?

    init(interval: TimeInterval = 2) {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            badges = [:]
            return
        }
        var result: [String: String] = [:]
        walk(AXUIElementCreateApplication(dock.processIdentifier), depth: 0, result: &result)
        badges = result
    }

    private func walk(_ element: AXUIElement, depth: Int, result: inout [String: String]) {
        guard depth < 8 else { return }
        if let label: String = attribute(element, "AXStatusLabel"),
           let url = elementURL(element),
           let bundleID = Bundle(url: url)?.bundleIdentifier,
           let parsed = Self.parseStatusLabel(label) {
            result[bundleID] = parsed
        }
        let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
        children.forEach { walk($0, depth: depth + 1, result: &result) }
    }

    private func elementURL(_ element: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success else { return nil }
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }

    private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    static func parseStatusLabel(_ label: String) -> String? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "0" else { return nil }
        let digits = trimmed.filter(\.isNumber)
        return digits.isEmpty ? trimmed : digits
    }
}
