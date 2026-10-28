import AppKit
import ApplicationServices
import Combine

private let mouseEnhancementCallback: CGEventTapCallBack = { _, type, event, context in
    guard let context else { return Unmanaged.passUnretained(event) }
    let service = Unmanaged<MouseEnhancementService>.fromOpaque(context).takeUnretainedValue()
    // The tap source is installed exclusively on the main run loop. The C
    // callback borrows this event synchronously; it never crosses a queue.
    nonisolated(unsafe) let callbackEvent = event
    MainActor.assumeIsolated { service.handle(type, event: callbackEvent) }
    return Unmanaged.passUnretained(event)
}

@MainActor
final class MouseEnhancementService: ObservableObject {
    static let shared = MouseEnhancementService()
    private static let eventMarker: Int64 = 0x57544D4F555345
    private let syntheticSource: CGEventSource? = {
        let source = CGEventSource(stateID: .privateState)
        source?.userData = eventMarker
        return source
    }()

    @Published private(set) var statusKey = "Mouse enhancement is off."
    @Published private(set) var isPaused = false
    @Published private(set) var verticalReversalBlocked = false
    @Published private(set) var horizontalReversalBlocked = false

    private var configuration = MouseEnhancementPreferences()
    private var subscription: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var frameTimer: Timer?
    private var template: CGEvent?
    private var target: NSRunningApplication?
    private var remainingX = 0.0
    private var remainingY = 0.0
    private var fractionalX = 0.0
    private var fractionalY = 0.0
    private var discreteRemainders: [UInt32: Double] = [:]
    private var lastFrameTime = 0.0
    private var endTime = 0.0
    private var sleeping = false

    func start(preferences: PreferencesStore) {
        guard subscription == nil else { return }
        subscription = preferences.$mouseEnhancement.removeDuplicates().sink { [weak self] value in
            self?.configuration = value
            self?.refresh()
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sleeping = true
                    self?.removeTap()
                }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sleeping = false
                    self?.refresh()
                }
            })
        }
        observers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
    }

    func stop() {
        subscription = nil
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
        removeTap()
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        refresh()
    }

    func refresh() {
        cancelAnimation()
        readKarabinerReversals()
        guard configuration.enabled else {
            removeTap()
            statusKey = "Mouse enhancement is off."
            return
        }
        guard !isPaused, !sleeping else {
            removeTap()
            statusKey = "Mouse enhancement is paused. Original scrolling is preserved."
            return
        }
        guard AXIsProcessTrusted() else {
            removeTap()
            statusKey = "Allow Accessibility access, then refresh to enable mouse enhancement."
            return
        }
        guard tap == nil else {
            statusKey = "Mouse enhancement is on. Identifiable injected and continuous input pass through."
            return
        }
        let mask = (CGEventMask(1) << CGEventType.scrollWheel.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.rightMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.otherMouseDown.rawValue)
        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: mouseEnhancementCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            statusKey = "Could not start mouse enhancement. Original scrolling is preserved."
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
            CFMachPortInvalidate(newTap)
            statusKey = "Could not start mouse enhancement. Original scrolling is preserved."
            return
        }
        tap = newTap
        tapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        statusKey = "Mouse enhancement is on. Identifiable injected and continuous input pass through."
    }

    private func removeTap() {
        cancelAnimation()
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tapSource = nil
        tap = nil
    }

    // A nonzero source PID identifies injected input, including ToDesk helper processes.
    // PID 0 is not proof of a physical device: remote tools can discard source metadata.
    // In that case the explicit pause control preserves the unmodified remote stream.
    fileprivate func handle(_ type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            cancelAnimation()
            if let tap, configuration.enabled, !isPaused, !sleeping {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.eventMarker {
            return
        }
        guard type == .scrollWheel, configuration.enabled, !isPaused, !sleeping,
              event.getIntegerValueField(.eventSourceUnixProcessID) == 0,
              event.getIntegerValueField(.eventSourceStateID) >= 0,
              event.getIntegerValueField(.eventSourceStateID) <= 1,
              event.getIntegerValueField(.eventSourceUserData) == 0,
              event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0,
              event.getIntegerValueField(.scrollWheelEventScrollPhase) == 0,
              event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0,
              event.getIntegerValueField(.scrollWheelEventScrollCount) == 0,
              event.getIntegerValueField(.scrollWheelEventDeltaAxis3) == 0,
              event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis3) == 0,
              event.getDoubleValueField(.scrollWheelEventPointDeltaAxis3) == 0 else {
            cancelAnimation()
            return
        }
        let pidValue = event.getIntegerValueField(.eventTargetUnixProcessID)
        guard pidValue > 1, pidValue <= Int64(Int32.max),
              let app = NSRunningApplication(processIdentifier: pid_t(pidValue)),
              !app.isTerminated, let bundleID = app.bundleIdentifier,
              !configuration.excludedApps.contains(where: { $0.bundleID == bundleID }) else {
            cancelAnimation()
            return
        }
        if target?.processIdentifier != app.processIdentifier || template?.flags != event.flags
            || template?.location != event.location {
            cancelAnimation()
        }
        let reverseY = configuration.reverseVertical && !verticalReversalBlocked
        let reverseX = configuration.reverseHorizontal && !horizontalReversalBlocked
        guard configuration.smoothScrolling else {
            target = app
            template = event.copy()
            scale(event, axis: 1, multiplier: configuration.effectiveSpeed * (reverseY ? -1 : 1))
            scale(event, axis: 2, multiplier: configuration.effectiveSpeed * (reverseX ? -1 : 1))
            return
        }
        let y = pixelDelta(event, axis: 1) * configuration.effectiveSpeed * (reverseY ? -1 : 1)
        let x = pixelDelta(event, axis: 2) * configuration.effectiveSpeed * (reverseX ? -1 : 1)
        guard x.isFinite, y.isFinite, abs(x) + abs(y) > 0,
              abs(x) < 100_000, abs(y) < 100_000,
              syntheticSource != nil, let copy = event.copy() else {
            cancelAnimation()
            return
        }
        if remainingX * x < 0 { remainingX = 0; fractionalX = 0 }
        if remainingY * y < 0 { remainingY = 0; fractionalY = 0 }
        let now = ProcessInfo.processInfo.systemUptime
        let fraction = min(1, (1.0 / 120) / configuration.effectiveDuration * 3)
        let firstX = (x == 0 ? 0 : copysign(min(abs(x), max(1, abs(x) * fraction)), x)).rounded(.towardZero)
        let firstY = (y == 0 ? 0 : copysign(min(abs(y), max(1, abs(y) * fraction)), y)).rounded(.towardZero)
        template = copy
        target = app
        remainingX += x - firstX
        remainingY += y - firstY
        endTime = now + configuration.effectiveDuration
        if frameTimer == nil {
            lastFrameTime = now
            let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.deliverFrame() }
            }
            frameTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        // Keep the original event on its normal route with the first whole-pixel
        // frame. Subpixel input stays in the tail until it can form a pixel.
        setPixels(event, x: firstX, y: firstY)
        return
    }

    private func deliverFrame() {
        let now = ProcessInfo.processInfo.systemUptime
        guard let tap, CGEvent.tapIsEnabled(tap: tap),
              let target, !target.isTerminated, let frame = template?.copy(),
              now - lastFrameTime < 0.25 else {
            cancelAnimation()
            return
        }
        let finished = now >= endTime
        let fraction = finished ? 1 : 1 - exp(-3 * (now - lastFrameTime) / configuration.effectiveDuration)
        // Decay ideal motion independently of integer output. Fractional output
        // accumulates across frames so small deltas do not stall until the end.
        let idealX = remainingX * fraction
        let idealY = remainingY * fraction
        remainingX -= idealX
        remainingY -= idealY
        fractionalX += idealX
        fractionalY += idealY
        let x = fractionalX.rounded(finished ? .toNearestOrAwayFromZero : .towardZero)
        let y = fractionalY.rounded(finished ? .toNearestOrAwayFromZero : .towardZero)
        fractionalX -= x
        fractionalY -= y
        lastFrameTime = now
        if x != 0 || y != 0 {
            setPixels(frame, x: x, y: y)
            frame.timestamp = DispatchTime.now().uptimeNanoseconds
            frame.postToPid(target.processIdentifier)
        }
        if finished { cancelAnimation() }
    }

    private func cancelAnimation() {
        frameTimer?.invalidate()
        frameTimer = nil
        template = nil
        target = nil
        remainingX = 0
        remainingY = 0
        fractionalX = 0
        fractionalY = 0
        discreteRemainders.removeAll()
    }

    private func setPixels(_ event: CGEvent, x: Double, y: Double) {
        // Source metadata can remain cached after setIntegerValueField. A fresh
        // source carries a reliable marker even when the input explicitly had 0.
        event.setSource(syntheticSource)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        // Setting a line delta also recalculates fixed/point deltas. Write the
        // explicit fixed and point values afterwards to preserve our frame.
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64((y / 10).rounded()))
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64((x / 10).rounded()))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: y / 10)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: x / 10)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(y))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(x))
    }

    private func pixelDelta(_ event: CGEvent, axis: Int) -> Double {
        let point = event.getDoubleValueField(axis == 1 ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventPointDeltaAxis2)
        if point != 0 { return point }
        let fixed = event.getDoubleValueField(axis == 1 ? .scrollWheelEventFixedPtDeltaAxis1 : .scrollWheelEventFixedPtDeltaAxis2)
        if fixed != 0 { return fixed * 10 }
        return Double(event.getIntegerValueField(axis == 1 ? .scrollWheelEventDeltaAxis1 : .scrollWheelEventDeltaAxis2)) * 10
    }

    private func scale(_ event: CGEvent, axis: Int, multiplier: Double) {
        let fields: [CGEventField] = axis == 1
            ? [.scrollWheelEventDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventPointDeltaAxis1]
            : [.scrollWheelEventDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventPointDeltaAxis2]
        let originalValues = fields.map { event.getDoubleValueField($0) }
        for (index, field) in fields.enumerated() {
            let scaled = originalValues[index] * multiplier
            if index == 1 {
                event.setDoubleValueField(field, value: scaled)
            } else {
                let total = scaled + (discreteRemainders[field.rawValue] ?? 0)
                let emitted = total.rounded(.towardZero)
                discreteRemainders[field.rawValue] = total - emitted
                event.setDoubleValueField(field, value: emitted)
            }
        }
    }

    private func readKarabinerReversals() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/karabiner/karabiner.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            verticalReversalBlocked = false
            horizontalReversalBlocked = false
            return
        }
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let profiles = root["profiles"] as? [[String: Any]],
              let profile = profiles.first(where: { ($0["selected"] as? Bool) == true }) else {
            // An unreadable configuration cannot establish that reversal is safe.
            verticalReversalBlocked = true
            horizontalReversalBlocked = true
            return
        }
        let devices = profile["devices"] as? [[String: Any]] ?? []
        verticalReversalBlocked = devices.contains { ($0["ignore"] as? Bool) != true && ($0["mouse_flip_vertical_wheel"] as? Bool) == true }
        horizontalReversalBlocked = devices.contains { ($0["ignore"] as? Bool) != true && ($0["mouse_flip_horizontal_wheel"] as? Bool) == true }
    }
}
