import CoreGraphics
import CoreVideo
import Darwin
import Foundation

/// All mutable render state and event snapshots are owned by this lock. Display
/// callbacks never access AppKit, preferences, or the main actor.
private final class MouseScrollRenderState: @unchecked Sendable {
    private let lock = NSLock()
    private var dynamics = MouseScrollDynamics()
    private var event: CGEvent?
    private var targetPID: pid_t = 0
    private var windowNumber: Int64 = 0
    private var generation: UInt64 = 0
    private var idle = true
    private let source: CGEventSource?

    init(marker: Int64) {
        source = CGEventSource(stateID: .privateState)
        source?.userData = marker
    }

    var canPost: Bool { source != nil }

    func accept(event: CGEvent, targetPID: pid_t, windowNumber: Int64, x: Double, y: Double,
                step: Double, speed: Double, transition: Double) {
        lock.lock()
        defer { lock.unlock() }
        if self.targetPID != targetPID || self.windowNumber != windowNumber || self.event?.flags != event.flags {
            dynamics = MouseScrollDynamics()
        }
        self.event = event
        self.targetPID = targetPID
        self.windowNumber = windowNumber
        dynamics.add(x: x, y: y, step: step, speed: speed, transition: transition)
        generation &+= 1
        idle = false
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        clearLocked()
    }

    private func clearLocked() {
        generation &+= 1
        idle = true
        event = nil
        targetPID = 0
        windowNumber = 0
        dynamics = MouseScrollDynamics()
    }

    func isIdle(generation expected: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return idle && generation == expected
    }

    /// Returns a generation once on becoming idle. No per-frame jobs are queued.
    func renderFrame() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard !idle else { return nil }
        guard let frame = event?.copy(), let source,
              kill(targetPID, 0) == 0 || errno == EPERM else {
            clearLocked()
            return generation
        }
        let output = dynamics.advance()
        if max(abs(output.x), abs(output.y)) > MouseScrollDynamics.deadZone {
            // Match the integer pixel contract: truncate fractional output and
            // discard sub-threshold tails, without a forced final-distance flush.
            guard let pixelFrame = CGEvent(
                scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                wheel1: Int32(clamping: Int64(output.y)),
                wheel2: Int32(clamping: Int64(output.x)), wheel3: 0
            ) else {
                clearLocked()
                return generation
            }
            frame.setSource(source)
            frame.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            // Keep every delta representation consistent with this frame. Copy
            // line fields first because writing them also updates fixed/point fields.
            for field: CGEventField in [
                .scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2,
                .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2,
                .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2
            ] {
                frame.setDoubleValueField(field, value: pixelFrame.getDoubleValueField(field))
            }
            frame.timestamp = DispatchTime.now().uptimeNanoseconds
            frame.postToPid(targetPID)
        }
        if dynamics.isSettled && max(abs(output.x), abs(output.y)) <= MouseScrollDynamics.deadZone {
            clearLocked()
            return generation
        }
        return nil
    }
}

@MainActor
final class MouseScrollRenderer {
    private let state: MouseScrollRenderState
    private var displayLink: CVDisplayLink?

    init(marker: Int64) { state = MouseScrollRenderState(marker: marker) }

    func enqueue(event: CGEvent, targetPID: pid_t, windowNumber: Int64, x: Double, y: Double,
                 step: Double, speed: Double, transition: Double) -> Bool {
        guard state.canPost, let snapshot = event.copy(), prepareDisplayLink() else {
            cancel()
            return false
        }
        state.accept(event: snapshot, targetPID: targetPID, windowNumber: windowNumber,
                     x: x, y: y, step: step, speed: speed, transition: transition)
        return true
    }

    private func prepareDisplayLink() -> Bool {
        if displayLink == nil {
            var created: CVDisplayLink?
            guard CVDisplayLinkCreateWithActiveCGDisplays(&created) == kCVReturnSuccess,
                  let created else { return false }
            let state = state
            guard CVDisplayLinkSetOutputHandler(created, { [weak self, state] _, _, _, _, _ in
                if let generation = state.renderFrame() {
                    Task { @MainActor [weak self] in
                        self?.stopIfIdle(generation: generation)
                    }
                }
                return kCVReturnSuccess
            }) == kCVReturnSuccess else { return false }
            displayLink = created
        }
        guard let displayLink else { return false }
        if CVDisplayLinkIsRunning(displayLink) { return true }
        return CVDisplayLinkStart(displayLink) == kCVReturnSuccess
    }

    private func stopIfIdle(generation: UInt64) {
        guard state.isIdle(generation: generation), let displayLink else { return }
        CVDisplayLinkStop(displayLink)
    }

    func cancel() {
        // Clear under the same lock used for posting before stopping the clock.
        // Once this returns, neither an in-flight frame nor a queued idle callback
        // can post motion from the canceled generation. Events already in the
        // system's queue may still be delivered to the destination afterwards.
        state.clear()
        if let displayLink, CVDisplayLinkIsRunning(displayLink) { CVDisplayLinkStop(displayLink) }
    }

    func shutDown() {
        cancel()
        displayLink = nil
    }
}
