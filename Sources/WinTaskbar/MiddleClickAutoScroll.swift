import AppKit
import CoreGraphics

/// Distance controls velocity. Keep fractional pixels between ticks so that a
/// pointer held just outside the dead zone still produces steady motion.
struct MiddleClickScrollMotion {
    private var remainder = CGPoint.zero

    mutating func advance(offset: CGPoint, seconds: TimeInterval) -> (x: Int32, y: Int32) {
        let distance = hypot(offset.x, offset.y)
        let deadZone = 8.0
        guard distance > deadZone else {
            remainder = .zero
            return (0, 0)
        }
        let scale = 5 * (distance - deadZone) / distance * seconds
        // Quartz screen coordinates grow down and right. Negative wheel deltas
        // move the viewport in those directions.
        let x = remainder.x - offset.x * scale
        let y = remainder.y - offset.y * scale
        let wholeX = x.rounded(.towardZero)
        let wholeY = y.rounded(.towardZero)
        remainder = CGPoint(x: x - wholeX, y: y - wholeY)
        return (Int32(wholeX), Int32(wholeY))
    }
}

@MainActor
final class MiddleClickAutoScroll {
    private let origin: CGPoint
    private let target: NSRunningApplication
    private let windowNumber: Int64
    private let source: CGEventSource
    private let indicator: NSPanel
    private var motion = MiddleClickScrollMotion()
    private var timer: Timer?
    private var lastTick = ProcessInfo.processInfo.systemUptime

    init?(event: CGEvent, target: NSRunningApplication, marker: Int64) {
        guard let source = CGEventSource(stateID: .privateState) else { return nil }
        source.userData = marker
        self.source = source
        self.target = target
        origin = event.location
        let handlingWindow = event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)
        windowNumber = handlingWindow != 0 ? handlingWindow
            : event.getIntegerValueField(.mouseEventWindowUnderMousePointer)
        indicator = Self.makeIndicator(at: origin)
    }

    func start(onTargetExit: @escaping @MainActor () -> Void) {
        indicator.orderFrontRegardless()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.target.isTerminated { onTargetExit() } else { self.tick() }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        indicator.orderOut(nil)
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = min(now - lastTick, 0.05)
        lastTick = now
        guard let pointer = CGEvent(source: nil)?.location else { return }
        let offset = CGPoint(x: pointer.x - origin.x, y: pointer.y - origin.y)
        let delta = motion.advance(offset: offset, seconds: elapsed)
        guard delta.x != 0 || delta.y != 0, let frame = CGEvent(
            scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
            wheel1: delta.y, wheel2: delta.x, wheel3: 0
        ) else { return }
        frame.location = origin
        frame.flags = []
        frame.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: windowNumber)
        frame.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: windowNumber)
        frame.postToPid(target.processIdentifier)
    }

    private static func makeIndicator(at origin: CGPoint) -> NSPanel {
        let size = 28.0
        let y = CGDisplayBounds(CGMainDisplayID()).height - origin.y
        let panel = NSPanel(
            contentRect: CGRect(x: origin.x - size / 2, y: y - size / 2, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let image = NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right", accessibilityDescription: nil)
        let icon = NSImageView(frame: CGRect(x: 0, y: 0, width: size, height: size))
        icon.image = image
        icon.contentTintColor = .white
        icon.wantsLayer = true
        icon.layer?.cornerRadius = size / 2
        icon.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        panel.contentView = icon
        return panel
    }
}
