import AppKit
import QuartzCore

@MainActor
final class NotificationGlow {
    static let defaultColor = NSColor(calibratedRed: 1, green: 0.8, blue: 5.0 / 255, alpha: 1)
    private var panel: NSPanel?
    private var completion: Task<Void, Never>?

    func show(on screen: NSScreen, color: NSColor, duration: TimeInterval = 3, showInFullscreen: Bool = true, alwaysOnTop: Bool = true) {
        // Coalesce a burst into one pulse instead of layering or restarting alarms.
        guard panel == nil else { return }
        let panel = NotificationGlowPanel(
            contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = alwaysOnTop ? .statusBar : .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if showInFullscreen { panel.collectionBehavior.insert(.fullScreenAuxiliary) }
        let view = NotificationGlowView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.color = color
        view.wantsLayer = true
        panel.contentView = view
        view.layer?.opacity = 0
        self.panel = panel
        panel.orderFrontRegardless()

        let animation = CAKeyframeAnimation(keyPath: "opacity")
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            animation.values = [0, 0.59, 0.59, 0]
            animation.keyTimes = [0, 0.1, 0.45, 1]
        } else {
            animation.values = [0, 0.59, 0, 0.59, 0]
            animation.keyTimes = [0, 0.25, 0.5, 0.75, 1]
        }
        let interval = max(0.1, duration)
        animation.duration = interval
        animation.calculationMode = .linear
        view.layer?.add(animation, forKey: "notificationGlow")
        completion = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(interval)) } catch { return }
            self?.stop()
        }
    }

    func stop() {
        completion?.cancel()
        completion = nil
        panel?.close()
        panel = nil
    }
}

private final class NotificationGlowPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class NotificationGlowView: NSView {
    var color = NotificationGlow.defaultColor

    override func draw(_ dirtyRect: NSRect) {
        // Four trapezoids meet at the corners without adding their opacity together.
        // The inner rectangle stays transparent; edge depth follows screen dimensions.
        let outer = bounds
        let inner = outer.insetBy(dx: outer.width * 0.1, dy: outer.height * 0.1)
        guard let gradient = NSGradient(starting: color, ending: color.withAlphaComponent(0)) else { return }
        let edges: [([NSPoint], NSPoint, NSPoint)] = [
            ([NSPoint(x: outer.minX, y: outer.minY), NSPoint(x: outer.minX, y: outer.maxY),
              NSPoint(x: inner.minX, y: inner.maxY), NSPoint(x: inner.minX, y: inner.minY)],
             NSPoint(x: outer.minX, y: outer.midY), NSPoint(x: inner.minX, y: outer.midY)),
            ([NSPoint(x: outer.maxX, y: outer.minY), NSPoint(x: outer.maxX, y: outer.maxY),
              NSPoint(x: inner.maxX, y: inner.maxY), NSPoint(x: inner.maxX, y: inner.minY)],
             NSPoint(x: outer.maxX, y: outer.midY), NSPoint(x: inner.maxX, y: outer.midY)),
            ([NSPoint(x: outer.minX, y: outer.minY), NSPoint(x: outer.maxX, y: outer.minY),
              NSPoint(x: inner.maxX, y: inner.minY), NSPoint(x: inner.minX, y: inner.minY)],
             NSPoint(x: outer.midX, y: outer.minY), NSPoint(x: outer.midX, y: inner.minY)),
            ([NSPoint(x: outer.minX, y: outer.maxY), NSPoint(x: outer.maxX, y: outer.maxY),
              NSPoint(x: inner.maxX, y: inner.maxY), NSPoint(x: inner.minX, y: inner.maxY)],
             NSPoint(x: outer.midX, y: outer.maxY), NSPoint(x: outer.midX, y: inner.maxY))
        ]
        for (points, start, end) in edges {
            NSGraphicsContext.saveGraphicsState()
            let path = NSBezierPath()
            path.move(to: points[0])
            points.dropFirst().forEach { path.line(to: $0) }
            path.close()
            path.addClip()
            gradient.draw(from: start, to: end, options: [])
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
