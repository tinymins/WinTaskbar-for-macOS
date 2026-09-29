import AppKit
import ApplicationServices

// Owns reversible window placement, never notification dismissal. The lock allows
// shutdown to restore windows synchronously even while the capture actor is busy.
final class NotificationBannerVisibility: @unchecked Sendable {
    private struct Placement {
        let original: CGPoint
        let hidden: CGPoint
    }
    private let lock = NSLock()
    private var enabled = true
    private var placements: [AXUIElement: Placement] = [:]

    func setEnabled(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        enabled = value
        if !value { restoreLocked() }
    }

    func restoreAll() {
        lock.lock()
        defer { lock.unlock() }
        restoreLocked()
    }

    func restore(_ window: AXUIElement) {
        lock.lock()
        defer { lock.unlock() }
        restoreLocked(window)
    }

    func restoreUnlisted(_ windows: [AXUIElement]) {
        lock.lock()
        defer { lock.unlock() }
        for window in Array(placements.keys) where !windows.contains(window) { restoreLocked(window) }
    }

    func hide(_ window: AXUIElement) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard enabled, !Task.isCancelled, let currentFrame = Self.frame(window),
              let desktop = Self.desktopBounds() else { return false }
        var frame = currentFrame
        if let placement = placements[window], frame.origin == placement.hidden {
            if !frame.intersects(desktop) { return true }
            restoreLocked(window)
            guard placements[window] == nil, let restored = Self.frame(window) else { return false }
            frame = restored
        }
        // Do not take ownership of windows another process already placed off screen.
        guard frame.intersects(desktop) else { return false }
        var writable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &writable) == .success,
              writable.boolValue else { return false }
        let destination = CGPoint(x: desktop.maxX + 64, y: desktop.minY)
        placements[window] = Placement(original: frame.origin, hidden: destination)
        guard Self.move(window, to: destination), let moved = Self.frame(window),
              moved.origin == destination, !moved.intersects(desktop), !Task.isCancelled else {
            // A setter can partially move or clamp a window even when verification fails.
            if Self.move(window, to: frame.origin) {
                placements.removeValue(forKey: window)
            } else if let current = Self.frame(window) {
                placements[window] = Placement(original: frame.origin, hidden: current.origin)
            }
            return false
        }
        return true
    }

    private func restoreLocked(_ window: AXUIElement? = nil) {
        for candidate in window.map({ [$0] }) ?? Array(placements.keys) {
            guard let placement = placements[candidate] else { continue }
            guard let frame = Self.frame(candidate) else {
                // Dead windows cannot retain a position. Transient read failures may recover.
                var role: CFTypeRef?
                if AXUIElementCopyAttributeValue(candidate, kAXRoleAttribute as CFString, &role) == .invalidUIElement {
                    placements.removeValue(forKey: candidate)
                }
                continue
            }
            // Respect a newer position set by macOS, especially when the center opens.
            if frame.origin != placement.hidden || Self.move(candidate, to: placement.original) {
                placements.removeValue(forKey: candidate)
            }
        }
    }

    private static func move(_ window: AXUIElement, to point: CGPoint) -> Bool {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
    }

    private static func frame(_ window: AXUIElement) -> CGRect? {
        AXUIElementSetMessagingTimeout(window, 0.15)
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              point.x.isFinite, point.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite,
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private static func desktopBounds() -> CGRect? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return nil }
        return displays.prefix(Int(count)).reduce(CGRect.null) { $0.union(CGDisplayBounds($1)) }
    }
}

extension NotificationAXNode {
    // Every visible leaf must belong to a fully parsed card. This also rejects
    // widget windows, unknown siblings and notification-center controls.
    func containsOnlyNotificationCards(_ contents: [SystemNotificationContent], processID: Int32) -> Bool {
        if contents.contains(where: { $0.sourceID == "\(processID):\(identity)" }),
           notifications(processID: processID).count == 1 { return true }
        guard ["AXWindow", "AXGroup", "AXScrollArea", "AXLayoutArea"].contains(role) else { return false }
        guard role == "AXWindow" || [value, title, description].allSatisfy({ $0.isEmpty }) else { return false }
        return children.allSatisfy { $0.containsOnlyNotificationCards(contents, processID: processID) }
    }
}
