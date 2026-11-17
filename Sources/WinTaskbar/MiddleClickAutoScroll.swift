import AppKit
import CoreGraphics

/// Distance controls velocity. Keep fractional pixels between ticks so that a
/// pointer held just outside the dead zone still produces steady motion.
struct MiddleClickScrollMotion {
    static let deadZone = 8.0
    private var remainder = CGPoint.zero

    mutating func advance(offset: CGPoint, seconds: TimeInterval) -> (x: Int32, y: Int32) {
        let distance = hypot(offset.x, offset.y)
        guard distance > Self.deadZone else {
            remainder = .zero
            return (0, 0)
        }
        let scale = 5 * (distance - Self.deadZone) / distance * seconds
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
    // WindowServer stores the destination window and its local hit-test point
    // separately from the global pointer position on process-directed events.
    private static let destinationWindow = CGEventField(rawValue: 51)!
    private typealias SetWindowPoint = @convention(c) (CGEvent, CGPoint) -> Void
    private static let setWindowPoint = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation")
        .map { unsafeBitCast($0, to: SetWindowPoint.self) }
    private let origin: CGPoint
    private let target: NSRunningApplication
    private let windowNumber: Int64
    private let windowPoint: CGPoint
    private let setWindowPoint: SetWindowPoint
    private let source: CGEventSource
    private let indicator: MiddleClickScrollIndicator
    private var motion = MiddleClickScrollMotion()
    private var timer: Timer?
    private var lastTick = ProcessInfo.processInfo.systemUptime

    init?(event: CGEvent, target: NSRunningApplication, marker: Int64) {
        guard let source = CGEventSource(stateID: .privateState),
              let setPoint = Self.setWindowPoint,
              let number = NSEvent(cgEvent: event)?.windowNumber, number > 0,
              event.getIntegerValueField(Self.destinationWindow) == Int64(number),
              let windowID = CGWindowID(exactly: number),
              let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let window = windows.first,
              window[kCGWindowOwnerPID as String] as? pid_t == target.processIdentifier,
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              rect.contains(event.location) else { return nil }
        source.userData = marker
        self.source = source
        self.target = target
        origin = event.location
        windowNumber = Int64(number)
        windowPoint = CGPoint(x: origin.x - rect.minX, y: origin.y - rect.minY)
        setWindowPoint = setPoint
        indicator = MiddleClickScrollIndicator(origin: origin, target: target)
    }

    func start(onTargetExit: @escaping @MainActor () -> Void) {
        indicator.show()
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
        indicator.hide()
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = min(now - lastTick, 0.05)
        lastTick = now
        guard let pointer = CGEvent(source: nil)?.location else { return }
        indicator.update(at: pointer)
        let offset = CGPoint(x: pointer.x - origin.x, y: pointer.y - origin.y)
        let delta = motion.advance(offset: offset, seconds: elapsed)
        guard delta.x != 0 || delta.y != 0, let frame = CGEvent(
            scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
            wheel1: delta.y, wheel2: delta.x, wheel3: 0
        ) else { return }
        frame.flags = []
        frame.setIntegerValueField(Self.destinationWindow, value: windowNumber)
        setWindowPoint(frame, windowPoint)
        frame.postToPid(target.processIdentifier)
    }

}
