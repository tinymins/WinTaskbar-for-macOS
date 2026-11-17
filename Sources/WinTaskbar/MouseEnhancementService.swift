import AppKit
import ApplicationServices
import Combine
import Darwin

private let mouseEnhancementCallback: CGEventTapCallBack = { _, type, event, context in
    guard let context else { return Unmanaged.passUnretained(event) }
    let service = Unmanaged<MouseEnhancementService>.fromOpaque(context).takeUnretainedValue()
    // The tap source is installed exclusively on the main run loop. The C
    // callback borrows this event synchronously; it never crosses a queue.
    nonisolated(unsafe) let callbackEvent = event
    let consumed = MainActor.assumeIsolated { service.handle(type, event: callbackEvent) }
    return consumed ? nil : Unmanaged.passUnretained(event)
}

@MainActor
final class MouseEnhancementService: ObservableObject {
    static let shared = MouseEnhancementService()
    private static let eventMarker: Int64 = 0x57544D4F555345
    private let renderer = MouseScrollRenderer(marker: eventMarker)

    @Published private(set) var statusKey = "Mouse enhancement is off."
    @Published private(set) var isPaused = false
    @Published private(set) var verticalReversalBlocked = false
    @Published private(set) var horizontalReversalBlocked = false

    private var configuration = MouseEnhancementPreferences()
    private var subscription: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var autoScroll: MiddleClickAutoScroll?
    private var swallowMiddleUp = false
    private var sleeping = false
    private enum ScrollSource {
        case local, toDesk, passThrough
    }

    private var sourcePolicyCache: (pid: pid_t, expires: TimeInterval, source: ScrollSource)?

    func start(preferences: PreferencesStore) {
        guard subscription == nil else { return }
        subscription = preferences.$mouseEnhancement.removeDuplicates().sink { [weak self] value in
            if self?.configuration.middleClickAutoScroll != value.middleClickAutoScroll { self?.removeTap() }
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
        stopAutoScroll()
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
            statusKey = "Mouse enhancement is on."
            return
        }
        var mask = (CGEventMask(1) << CGEventType.scrollWheel.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.rightMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.otherMouseDown.rawValue)
        if configuration.middleClickAutoScroll {
            mask |= (CGEventMask(1) << CGEventType.otherMouseUp.rawValue)
                | (CGEventMask(1) << CGEventType.keyDown.rawValue)
        }
        guard let newTap = CGEvent.tapCreate(
            // Target PID/window routing is available after session annotation.
            tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
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
        statusKey = "Mouse enhancement is on."
    }

    private func removeTap() {
        stopAutoScroll()
        swallowMiddleUp = false
        renderer.shutDown()
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tapSource = nil
        tap = nil
    }

    // Local mouse drivers also inject events. Resolve the source instead of
    // treating every nonzero PID/private source as remote input.
    fileprivate func handle(_ type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            stopAutoScroll()
            swallowMiddleUp = false
            cancelAnimation()
            if let tap, configuration.enabled, !isPaused, !sleeping {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return false
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.eventMarker {
            return false
        }
        if type == .keyDown {
            guard autoScroll != nil, event.getIntegerValueField(.keyboardEventKeycode) == 53 else { return false }
            stopAutoScroll()
            return true
        }
        if type == .otherMouseUp {
            guard event.getIntegerValueField(.mouseEventButtonNumber) == 2, swallowMiddleUp else { return false }
            swallowMiddleUp = false
            return true
        }
        if type == .otherMouseDown, event.getIntegerValueField(.mouseEventButtonNumber) == 2,
           configuration.middleClickAutoScroll, configuration.enabled, !isPaused, !sleeping,
           scrollSource(event.getIntegerValueField(.eventSourceUnixProcessID)) != .passThrough {
            if autoScroll != nil {
                stopAutoScroll()
                swallowMiddleUp = true
                return true
            }
            if let target = targetApplication(for: event),
               let session = MiddleClickAutoScroll(event: event, target: target, marker: Self.eventMarker) {
                cancelAnimation()
                autoScroll = session
                session.start { [weak self] in self?.stopAutoScroll() }
                swallowMiddleUp = true
                return true
            }
        }
        stopAutoScroll()
        guard type == .scrollWheel, configuration.enabled, !isPaused, !sleeping,
              event.getIntegerValueField(.scrollWheelEventScrollPhase) == 0,
              event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0 else {
            cancelAnimation()
            return false
        }
        let source = scrollSource(event.getIntegerValueField(.eventSourceUnixProcessID))
        // ToDesk can mark wheel steps as continuous and populate unused third-axis fields.
        guard source != .passThrough, source == .toDesk || (
            event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0
                && event.getIntegerValueField(.scrollWheelEventDeltaAxis3) == 0
                && event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis3) == 0
                && event.getDoubleValueField(.scrollWheelEventPointDeltaAxis3) == 0
        ) else {
            cancelAnimation()
            return false
        }
        guard let app = targetApplication(for: event) else {
            cancelAnimation()
            return false
        }
        let reverseY = source == .local && configuration.reverseVertical && !verticalReversalBlocked
        let reverseX = source == .local && configuration.reverseHorizontal && !horizontalReversalBlocked
        // Reverse before capturing the output template, including legacy line and
        // fixed-point metadata. If smoothing is unavailable this reversed native
        // event still follows its original route.
        if reverseY { reverse(event, axis: 1) }
        if reverseX { reverse(event, axis: 2) }
        guard configuration.smoothScrolling else {
            cancelAnimation()
            return false
        }
        guard let y = scrollLines(event, axis: 1), let x = scrollLines(event, axis: 2),
              x.isFinite, y.isFinite, abs(x) + abs(y) > 0,
              abs(x) < 100_000, abs(y) < 100_000 else {
            cancelAnimation()
            return false
        }
        let handlingWindow = event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)
        let windowNumber = handlingWindow != 0 ? handlingWindow
            : event.getIntegerValueField(.mouseEventWindowUnderMousePointer)
        // Preserve the original stream unless its snapshot and display clock are
        // ready. The first visible frame comes from the display-paced response.
        return renderer.enqueue(
            event: event, targetPID: app.processIdentifier, windowNumber: windowNumber,
            x: x, y: y, isToDesk: source == .toDesk,
            speed: configuration.effectiveSpeed, transition: configuration.transition
        )
    }

    private func stopAutoScroll() {
        autoScroll?.stop()
        autoScroll = nil
    }

    private func targetApplication(for event: CGEvent) -> NSRunningApplication? {
        let pidValue = event.getIntegerValueField(.eventTargetUnixProcessID)
        guard pidValue > 1, pidValue <= Int64(Int32.max),
              let app = NSRunningApplication(processIdentifier: pid_t(pidValue)),
              !app.isTerminated, let bundleID = app.bundleIdentifier,
              !configuration.excludedApps.contains(where: { $0.bundleID == bundleID }) else {
            return nil
        }
        return app
    }

    private func cancelAnimation() { renderer.cancel() }

    private func scrollLines(_ event: CGEvent, axis: Int) -> Double? {
        let fixed = event.getDoubleValueField(axis == 1 ? .scrollWheelEventFixedPtDeltaAxis1 : .scrollWheelEventFixedPtDeltaAxis2)
        if fixed != 0 { return fixed }
        let lines = event.getIntegerValueField(axis == 1 ? .scrollWheelEventDeltaAxis1 : .scrollWheelEventDeltaAxis2)
        if lines != 0 { return Double(lines) }
        // Pixel-only input has no known line distance. Preserve the whole event
        // rather than guessing a conversion or discarding one of its axes.
        let point = event.getDoubleValueField(axis == 1 ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventPointDeltaAxis2)
        return point == 0 ? 0 : nil
    }

    private func reverse(_ event: CGEvent, axis: Int) {
        let fields: [CGEventField] = axis == 1
            ? [.scrollWheelEventDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventPointDeltaAxis1]
            : [.scrollWheelEventDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventPointDeltaAxis2]
        let originalValues = fields.map { event.getDoubleValueField($0) }
        // Line writes also update fixed/point fields, so restore those explicitly.
        for (index, field) in fields.enumerated() {
            event.setDoubleValueField(field, value: -originalValues[index])
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

    private func scrollSource(_ value: Int64) -> ScrollSource {
        // Hardware commonly has no source process. Remote tools that strip this
        // metadata cannot be distinguished here; manual pause remains available.
        if value == 0 { return .local }
        guard value > 0, value <= Int64(Int32.max) else { return .passThrough }
        let pid = pid_t(value)
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = sourcePolicyCache, cached.pid == pid, now < cached.expires {
            return cached.source
        }
        let app = NSRunningApplication(processIdentifier: pid)
        var path = app?.executableURL?.path
        if path == nil {
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
                path = String(cString: buffer)
            }
        }
        let bundleID = app?.bundleIdentifier ?? ""
        let toDeskExecutables: Set<String> = [
            "ToDesk", "ToDesk_Service", "ToDesk_Session_Proxy", "ToDesk_Session",
            "ToDesk_Screenwall_Helper", "ToDesk_XPCHelper"
        ]
        let executable = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        let source: ScrollSource
        if bundleID.hasPrefix("com.youqu.todesk.") || toDeskExecutables.contains(executable) {
            source = .toDesk
        } else if path == nil || bundleID == "com.apple.screensharing.agent"
                    || executable == "screensharingd" || executable == "screensharingagent" {
            source = .passThrough
        } else {
            source = .local
        }
        sourcePolicyCache = (pid, now + 1, source)
        return source
    }
}
