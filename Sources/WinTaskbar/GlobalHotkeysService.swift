import AppKit
import Carbon
import Combine
import Foundation

private let winTaskbarHotKeySignature: OSType = 0x5754534B

struct WindowsKeyGestureState {
    private static let allCombinationModifiers: NSEvent.ModifierFlags = [
        .command, .control, .option, .shift, .function
    ]

    private let windowsModifier: NSEvent.ModifierFlags
    private var modifierIsDown = false
    private var canTrigger = false

    init(windowsModifier: NSEvent.ModifierFlags = .option) {
        self.windowsModifier = windowsModifier
    }

    mutating func flagsChanged(to rawFlags: NSEvent.ModifierFlags) -> Bool {
        let flags = rawFlags.intersection(.deviceIndependentFlagsMask)
        let modifierIsNowDown = flags.contains(windowsModifier)
        let otherModifiers = Self.allCombinationModifiers.subtracting(windowsModifier)

        if !modifierIsDown, modifierIsNowDown {
            modifierIsDown = true
            canTrigger = flags.intersection(otherModifiers).isEmpty
            return false
        }

        if modifierIsDown, modifierIsNowDown {
            canTrigger = false
            return false
        }

        guard modifierIsDown else { return false }
        let shouldTrigger = canTrigger && flags.intersection(otherModifiers).isEmpty
        reset()
        return shouldTrigger
    }

    mutating func keyDown() {
        if modifierIsDown { canTrigger = false }
    }

    mutating func handle(eventType: CGEventType, modifierFlags: NSEvent.ModifierFlags = []) -> Bool {
        switch eventType {
        case .flagsChanged:
            return flagsChanged(to: modifierFlags)
        case .keyDown:
            keyDown()
            return false
        default:
            return false
        }
    }

    mutating func reset() {
        modifierIsDown = false
        canTrigger = false
    }
}

enum WindowsSpaceGestureAction: Equatable {
    case present
    case advance
    case retreat
    case dismiss
}

enum AltTabGestureAction: Equatable {
    case present(reverse: Bool)
    case advance
    case retreat
    case commit
    case cancel
}

enum ShortcutCaptureAction: Equatable {
    case passThrough
    case suppress
    case cancel
    case capture(HotkeyShortcut)
}

struct AltTabGestureState {
    private let altModifier: NSEvent.ModifierFlags
    private(set) var isActive = false

    init(altModifier: NSEvent.ModifierFlags = .option) {
        self.altModifier = altModifier
    }

    mutating func press(reverse: Bool) -> AltTabGestureAction {
        if isActive { return reverse ? .retreat : .advance }
        isActive = true
        return .present(reverse: reverse)
    }

    mutating func flagsChanged(to rawFlags: NSEvent.ModifierFlags) -> AltTabGestureAction? {
        guard isActive else { return nil }
        let flags = rawFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(altModifier) else { return nil }
        isActive = false
        return .commit
    }

    mutating func cancel() -> AltTabGestureAction? {
        guard isActive else { return nil }
        isActive = false
        return .cancel
    }
}

struct WindowsSpaceGestureState {
    static let presentationDelayMilliseconds = 300

    private let windowsModifier: NSEvent.ModifierFlags
    private var isActive = false
    private var isPresented = false
    private var pendingCycleAction = WindowsSpaceGestureAction.advance

    init(windowsModifier: NSEvent.ModifierFlags = .option) {
        self.windowsModifier = windowsModifier
    }

    mutating func press(reverse: Bool = false) -> WindowsSpaceGestureAction? {
        let cycleAction = reverse ? WindowsSpaceGestureAction.retreat : .advance
        if isActive { return cycleAction }
        isActive = true
        pendingCycleAction = cycleAction
        return nil
    }

    mutating func presentationDelayElapsed() -> WindowsSpaceGestureAction? {
        guard isActive, !isPresented else { return nil }
        isPresented = true
        return .present
    }

    mutating func flagsChanged(to rawFlags: NSEvent.ModifierFlags) -> WindowsSpaceGestureAction? {
        guard isActive else { return nil }
        let flags = rawFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(windowsModifier) else { return nil }
        let action: WindowsSpaceGestureAction = isPresented ? .dismiss : pendingCycleAction
        isActive = false
        isPresented = false
        pendingCycleAction = .advance
        return action
    }

    mutating func reset() -> WindowsSpaceGestureAction? {
        guard isActive else { return nil }
        let action: WindowsSpaceGestureAction? = isPresented ? .dismiss : nil
        isActive = false
        isPresented = false
        pendingCycleAction = .advance
        return action
    }
}

private let windowsKeyEventTapHandler: CGEventTapCallBack = { _, eventType, event, userData in
    guard let userData else { return Unmanaged.passUnretained(event) }
    let service = Unmanaged<GlobalHotkeysService>.fromOpaque(userData).takeUnretainedValue()
    let rawFlags = event.flags.rawValue
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    MainActor.assumeIsolated {
        service.handleWindowsKeyEvent(eventType, rawFlags: rawFlags, keyCode: keyCode)
    }
    return Unmanaged.passUnretained(event)
}

private let shortcutCaptureEventTapHandler: CGEventTapCallBack = { _, eventType, event, userData in
    guard let userData else { return Unmanaged.passUnretained(event) }
    let service = Unmanaged<GlobalHotkeysService>.fromOpaque(userData).takeUnretainedValue()
    let rawFlags = event.flags.rawValue
    let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
    let keyLabel = NSEvent(cgEvent: event)?.charactersIgnoringModifiers?.uppercased()
    let shouldSuppress = MainActor.assumeIsolated {
        service.handleShortcutCaptureEvent(
            eventType,
            rawFlags: rawFlags,
            keyCode: keyCode,
            keyLabel: keyLabel
        )
    }
    return shouldSuppress ? nil : Unmanaged.passUnretained(event)
}

private let winTaskbarHotKeyHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    var actualSize = 0
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        &actualSize,
        &hotKeyID
    )
    guard status == noErr else { return status }
    let service = Unmanaged<GlobalHotkeysService>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { service.handle(id: Int(hotKeyID.id)) }
    return noErr
}

@MainActor
final class GlobalHotkeysService: ObservableObject {
    static let shared = GlobalHotkeysService()

    var onInvoke: ((GlobalShortcutConfiguration) -> Void)?
    var onWindowsSpaceGesture: ((WindowsSpaceGestureAction) -> Void)?
    var onAltTabGesture: ((AltTabGestureAction) -> Void)?

    @Published private(set) var registrationIssues: [String: String] = [:]
    @Published private(set) var windowsKeyIssue: String?
    @Published private(set) var altTabIssue: String?
    @Published private(set) var isCapturingShortcut = false

    private var handler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []
    private var configurationByHotKeyID: [Int: GlobalShortcutConfiguration] = [:]
    private var windowsKeyEventTap: CFMachPort?
    private var windowsKeyEventTapSource: CFRunLoopSource?
    private(set) var isEnabled = false
    private var configurations: [GlobalShortcutConfiguration] = []
    private var requestedEnabled = false
    private var reverseWindowsSpaceHotKeyIDs: Set<Int> = []
    private var altTabHotKeyIDs: Set<Int> = []
    private var windowsKeyMapping: WindowsKeyMapping = .option
    private var windowsKeyOpensStart = true
    private var windowsKeyGesture = WindowsKeyGestureState()
    private var windowsSpaceGesture = WindowsSpaceGestureState()
    private var windowsSpacePresentationWorkItem: DispatchWorkItem?
    private var windowsSpacePresentationGeneration = 0
    private var windowsSpaceTrackingEnabled = false
    private var altTabGesture = AltTabGestureState()
    private var altTabTrackingEnabled = false
    private var altTabModifierPollingTask: Task<Void, Never>?
    private var altTabModifierPollingGeneration: UInt = 0
    private var altTabSessionID: UInt = 0
    private var altTabSessionStartedAt: UInt64 = 0
    private var altTabSwitcherEnabled = false
    private var altTabModifier: AltTabModifier = .option
    private var shortcutCaptureEventTap: CFMachPort?
    private var shortcutCaptureEventTapSource: CFRunLoopSource?
    private var shortcutCaptureLocalMonitor: Any?
    private var shortcutCaptureOwner: UUID?
    private var shortcutCaptureCompletion: ((HotkeyShortcut?) -> Void)?
    private var workspaceTerminationObserver: NSObjectProtocol?
    private var registrationRetryTask: Task<Void, Never>?

    private static let altTabForwardHotKeyID = Int(UInt32.max - 1)
    private static let altTabReverseHotKeyID = Int(UInt32.max)

    private init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            winTaskbarHotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        workspaceTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryUnavailableRegistrationsAfterApplicationExit() }
        }
    }

    func setConfiguration(
        enabled: Bool,
        altTabSwitcherEnabled: Bool,
        altTabModifier: AltTabModifier,
        windowsKeyMapping: WindowsKeyMapping,
        windowsKeyOpensStart: Bool,
        configurations: [GlobalShortcutConfiguration]
    ) {
        self.configurations = configurations
        requestedEnabled = enabled
        self.windowsKeyMapping = windowsKeyMapping
        self.windowsKeyOpensStart = windowsKeyOpensStart
        self.altTabSwitcherEnabled = altTabSwitcherEnabled
        self.altTabModifier = altTabModifier
        applyConfiguration()
    }

    func beginShortcutCapture(
        owner: UUID,
        completion: @escaping (HotkeyShortcut?) -> Void
    ) {
        if isCapturingShortcut {
            completeShortcutCapture(with: nil)
        }
        shortcutCaptureOwner = owner
        shortcutCaptureCompletion = completion
        isCapturingShortcut = true
        applyConfiguration()
        installShortcutCaptureLocalMonitor()
        _ = installShortcutCaptureEventTap()
    }

    func finishShortcutCapture(owner: UUID, with shortcut: HotkeyShortcut?) {
        guard shortcutCaptureOwner == owner else { return }
        completeShortcutCapture(with: shortcut)
    }

    func cancelShortcutCapture(owner: UUID) {
        finishShortcutCapture(owner: owner, with: nil)
    }

    private func applyConfiguration() {
        unregisterAll()
        windowsKeyGesture = WindowsKeyGestureState(windowsModifier: windowsKeyMapping.eventModifier)
        windowsSpaceGesture = WindowsSpaceGestureState(windowsModifier: windowsKeyMapping.eventModifier)
        altTabGesture = AltTabGestureState(altModifier: altTabModifier.eventModifier)
        var issues = Self.duplicateIssues(configurations: configurations, mapping: windowsKeyMapping)
        if self.altTabSwitcherEnabled {
            issues.merge(Self.altTabConflicts(
                configurations: configurations,
                mapping: windowsKeyMapping,
                altTabModifier: altTabModifier
            )) {
                current, _ in current
            }
        }
        for configuration in configurations where configuration.isEnabled && issues[configuration.id] == nil {
            issues[configuration.id] = configuration.validationIssue
        }
        windowsKeyIssue = nil
        altTabIssue = nil
        if requestedEnabled && !isCapturingShortcut {
            for (index, configuration) in configurations.enumerated() where configuration.isEnabled {
                guard issues[configuration.id] == nil else { continue }
                let shortcut = configuration.resolvedShortcut(mapping: windowsKeyMapping)
                if let issue = register(id: index + 1, shortcut: shortcut, configuration: configuration) {
                    issues[configuration.id] = issue
                }
            }
            for (index, configuration) in configurations.enumerated() where configuration.isEnabled {
                guard configuration.usesWindowsKey,
                      configuration.action == .toggleInputSources,
                      issues[configuration.id] == nil,
                      configurationByHotKeyID[index + 1] != nil,
                      let reverseShortcut = Self.reverseWindowsSpaceShortcut(
                          for: configuration.resolvedShortcut(mapping: windowsKeyMapping)
                      ) else { continue }
                let reverseID = configurations.count + index + 1
                if let issue = register(
                    id: reverseID,
                    shortcut: reverseShortcut,
                    configuration: configuration
                ) {
                    issues[configuration.id] = "Reverse shortcut \(issue.lowercased())"
                } else {
                    reverseWindowsSpaceHotKeyIDs.insert(reverseID)
                }
            }
            let tracksWindowsSpace = configurations.contains {
                $0.isEnabled && $0.usesWindowsKey && $0.action == .toggleInputSources
            }
            if (windowsKeyOpensStart || tracksWindowsSpace), !installWindowsKeyEventTap() {
                windowsKeyIssue = "Event monitoring unavailable"
            }
            windowsSpaceTrackingEnabled = tracksWindowsSpace && windowsKeyEventTap != nil
            if self.altTabSwitcherEnabled {
                altTabIssue = registerAltTabHotKeys()
                altTabTrackingEnabled = altTabIssue == nil
            }
        } else if !isCapturingShortcut {
            removeWindowsKeyEventTap()
        }
        registrationIssues = issues
        isEnabled = requestedEnabled && !isCapturingShortcut
    }

    static func duplicateIssues(
        configurations: [GlobalShortcutConfiguration],
        mapping: WindowsKeyMapping
    ) -> [String: String] {
        var issues: [String: String] = [:]
        var configurationsByShortcut: [String: [GlobalShortcutConfiguration]] = [:]
        for configuration in configurations where configuration.isEnabled {
            let shortcut = configuration.resolvedShortcut(mapping: mapping)
            let shortcutKey = "\(shortcut.keyCode):\(shortcut.modifiers)"
            configurationsByShortcut[shortcutKey, default: []].append(configuration)
        }
        for group in configurationsByShortcut.values where group.count > 1 {
            for configuration in group {
                let conflictingTitles = group
                    .filter { $0.id != configuration.id }
                    .map(\.title)
                    .joined(separator: ", ")
                issues[configuration.id] = "Conflicts with \(conflictingTitles)"
            }
        }
        return issues
    }

    static func reverseWindowsSpaceShortcut(for shortcut: HotkeyShortcut) -> HotkeyShortcut? {
        guard shortcut.modifiers & UInt32(shiftKey) == 0 else { return nil }
        var reverseShortcut = shortcut
        reverseShortcut.modifiers |= UInt32(shiftKey)
        return reverseShortcut
    }

    static func altTabConflicts(
        configurations: [GlobalShortcutConfiguration],
        mapping: WindowsKeyMapping,
        altTabModifier: AltTabModifier
    ) -> [String: String] {
        Dictionary(uniqueKeysWithValues: configurations.compactMap { configuration in
            guard configuration.isEnabled else { return nil }
            let shortcut = configuration.resolvedShortcut(mapping: mapping)
            let modifiers = shortcut.modifiers & ~UInt32(shiftKey)
            guard shortcut.keyCode == 48, modifiers == altTabModifier.carbonModifier else { return nil }
            return (configuration.id, "Conflicts with Alt+Tab Window Switcher")
        })
    }

    static func registrationIssue(for status: OSStatus) -> String {
        status == OSStatus(eventHotKeyExistsErr)
            ? "Already in use by another application"
            : "Unavailable (\(status))"
    }

    static func shouldRetryRegistration(
        registrationIssues: [String: String],
        altTabIssue: String?
    ) -> Bool {
        altTabIssue != nil || registrationIssues.values.contains {
            $0 == registrationIssue(for: OSStatus(eventHotKeyExistsErr))
        }
    }

    static func shortcutCaptureAction(
        eventType: CGEventType,
        keyCode: UInt32,
        modifiers: UInt32,
        keyLabel: String?
    ) -> ShortcutCaptureAction {
        guard eventType == .keyDown else {
            return eventType == .keyUp || eventType == .flagsChanged ? .suppress : .passThrough
        }
        if keyCode == 53 { return .cancel }
        guard modifiers != 0 else { return .suppress }
        return .capture(HotkeyShortcut(
            keyCode: keyCode,
            modifiers: modifiers,
            keyLabel: Self.keyLabel(keyCode: keyCode, fallback: keyLabel)
        ))
    }

    fileprivate func handle(id: Int) {
        if altTabTrackingEnabled, altTabHotKeyIDs.contains(id) {
            let action = altTabGesture.press(reverse: id == Self.altTabReverseHotKeyID)
            if case .present = action {
                altTabSessionID &+= 1
                altTabSessionStartedAt = AltTabDiagnostics.timestamp()
                AltTabDiagnostics.logger.notice(
                    "session=\(self.altTabSessionID, privacy: .public) hotkey-pressed"
                )
            }
            startAltTabModifierPolling()
            let presentationStartedAt = AltTabDiagnostics.timestamp()
            onAltTabGesture?(action)
            AltTabDiagnostics.logger.notice(
                "session=\(self.altTabSessionID, privacy: .public) gesture-dispatched action=\(String(describing: action), privacy: .public) durationMs=\(AltTabDiagnostics.milliseconds(since: presentationStartedAt), privacy: .public)"
            )
            commitAltTabIfModifierWasReleased()
            return
        }
        guard let configuration = configurationByHotKeyID[id] else { return }
        if windowsSpaceTrackingEnabled,
           configuration.usesWindowsKey,
           configuration.action == .toggleInputSources {
            if let action = windowsSpaceGesture.press(reverse: reverseWindowsSpaceHotKeyIDs.contains(id)) {
                onWindowsSpaceGesture?(action)
            } else {
                scheduleWindowsSpacePresentation()
            }
            return
        }
        onInvoke?(configuration)
    }

    private func register(
        id: Int,
        shortcut: HotkeyShortcut,
        configuration: GlobalShortcutConfiguration
    ) -> String? {
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: winTaskbarHotKeySignature, id: UInt32(id))
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else { return Self.registrationIssue(for: status) }
        hotKeys.append(reference)
        configurationByHotKeyID[id] = configuration
        return nil
    }

    private func unregisterAll() {
        cancelWindowsSpacePresentation()
        stopAltTabModifierPolling()
        if let action = windowsSpaceGesture.reset() {
            onWindowsSpaceGesture?(action)
        }
        if let action = altTabGesture.cancel() {
            onAltTabGesture?(action)
        }
        hotKeys.forEach { _ = UnregisterEventHotKey($0) }
        hotKeys.removeAll()
        configurationByHotKeyID.removeAll()
        reverseWindowsSpaceHotKeyIDs.removeAll()
        altTabHotKeyIDs.removeAll()
        windowsSpaceTrackingEnabled = false
        altTabTrackingEnabled = false
        removeWindowsKeyEventTap()
    }

    private func startAltTabModifierPolling() {
        altTabModifierPollingTask?.cancel()
        altTabModifierPollingGeneration &+= 1
        let generation = altTabModifierPollingGeneration
        altTabModifierPollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(16))
                } catch {
                    break
                }
                guard !Task.isCancelled,
                      let self,
                      self.altTabModifierPollingGeneration == generation,
                      self.altTabGesture.isActive else { break }
                let flags = CGEventSource.flagsState(.combinedSessionState)
                let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue))
                if let action = self.altTabGesture.flagsChanged(to: modifierFlags) {
                    AltTabDiagnostics.logger.notice(
                        "session=\(self.altTabSessionID, privacy: .public) modifier-release-detected source=poll elapsedMs=\(AltTabDiagnostics.milliseconds(since: self.altTabSessionStartedAt), privacy: .public)"
                    )
                    self.onAltTabGesture?(action)
                    break
                }
            }
            guard let self, self.altTabModifierPollingGeneration == generation else { return }
            self.altTabModifierPollingTask = nil
        }
    }

    private func commitAltTabIfModifierWasReleased() {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue))
        guard let action = altTabGesture.flagsChanged(to: modifierFlags) else { return }
        AltTabDiagnostics.logger.notice(
            "session=\(self.altTabSessionID, privacy: .public) modifier-release-detected source=post-present elapsedMs=\(AltTabDiagnostics.milliseconds(since: self.altTabSessionStartedAt), privacy: .public)"
        )
        stopAltTabModifierPolling()
        onAltTabGesture?(action)
    }

    private func stopAltTabModifierPolling() {
        altTabModifierPollingGeneration &+= 1
        altTabModifierPollingTask?.cancel()
        altTabModifierPollingTask = nil
    }

    private func registerAltTabHotKeys() -> String? {
        let shortcuts = [
            (Self.altTabForwardHotKeyID, HotkeyShortcut(
                keyCode: 48, modifiers: altTabModifier.carbonModifier, keyLabel: "Tab"
            )),
            (Self.altTabReverseHotKeyID, HotkeyShortcut(
                keyCode: 48,
                modifiers: altTabModifier.carbonModifier | UInt32(shiftKey),
                keyLabel: "Tab"
            )),
        ]
        var registered: [EventHotKeyRef] = []
        for (id, shortcut) in shortcuts {
            var reference: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: winTaskbarHotKeySignature, id: UInt32(id))
            let status = RegisterEventHotKey(
                shortcut.keyCode,
                shortcut.modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &reference
            )
            guard status == noErr, let reference else {
                registered.forEach { _ = UnregisterEventHotKey($0) }
                return "\(altTabModifier.shortcutLabel) is already in use by another application"
            }
            registered.append(reference)
        }
        hotKeys.append(contentsOf: registered)
        altTabHotKeyIDs = Set(shortcuts.map(\.0))
        return nil
    }

    private func scheduleWindowsSpacePresentation() {
        cancelWindowsSpacePresentation()
        let generation = windowsSpacePresentationGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.windowsSpacePresentationGeneration == generation,
                  let action = self.windowsSpaceGesture.presentationDelayElapsed() else { return }
            self.windowsSpacePresentationWorkItem = nil
            self.onWindowsSpaceGesture?(action)
        }
        windowsSpacePresentationWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(WindowsSpaceGestureState.presentationDelayMilliseconds),
            execute: workItem
        )
    }

    private func cancelWindowsSpacePresentation() {
        windowsSpacePresentationWorkItem?.cancel()
        windowsSpacePresentationWorkItem = nil
        windowsSpacePresentationGeneration += 1
    }

    private func installWindowsKeyEventTap() -> Bool {
        guard windowsKeyEventTap == nil else { return true }
        let eventMask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: windowsKeyEventTapHandler,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ),
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            return false
        }
        windowsKeyEventTap = eventTap
        windowsKeyEventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return true
    }

    private func removeWindowsKeyEventTap() {
        if let source = windowsKeyEventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let eventTap = windowsKeyEventTap {
            CFMachPortInvalidate(eventTap)
        }
        windowsKeyEventTapSource = nil
        windowsKeyEventTap = nil
    }

    private func retryUnavailableRegistrationsAfterApplicationExit() {
        guard !isCapturingShortcut,
              Self.shouldRetryRegistration(
                registrationIssues: registrationIssues,
                altTabIssue: altTabIssue
              ) else { return }
        registrationRetryTask?.cancel()
        registrationRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, !self.isCapturingShortcut else { return }
            self.applyConfiguration()
            self.registrationRetryTask = nil
        }
    }

    private func installShortcutCaptureEventTap() -> Bool {
        guard shortcutCaptureEventTap == nil else { return true }
        let eventMask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: shortcutCaptureEventTapHandler,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ),
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            return false
        }
        shortcutCaptureEventTap = eventTap
        shortcutCaptureEventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return true
    }

    private func removeShortcutCaptureEventTap() {
        if let source = shortcutCaptureEventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let eventTap = shortcutCaptureEventTap {
            CFMachPortInvalidate(eventTap)
        }
        shortcutCaptureEventTapSource = nil
        shortcutCaptureEventTap = nil
    }

    private func installShortcutCaptureLocalMonitor() {
        guard shortcutCaptureLocalMonitor == nil else { return }
        shortcutCaptureLocalMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged]
        ) { [weak self] event in
            let eventType: CGEventType
            switch event.type {
            case .keyDown: eventType = .keyDown
            case .keyUp: eventType = .keyUp
            case .flagsChanged: eventType = .flagsChanged
            default: return event
            }
            let rawFlags = event.modifierFlags.rawValue
            let keyCode = UInt32(event.keyCode)
            let keyLabel = event.charactersIgnoringModifiers?.uppercased()
            let shouldSuppress = MainActor.assumeIsolated {
                self?.handleShortcutCaptureEvent(
                    eventType,
                    modifiers: Self.carbonModifiers(
                        NSEvent.ModifierFlags(rawValue: rawFlags)
                    ),
                    keyCode: keyCode,
                    keyLabel: keyLabel
                ) ?? false
            }
            return shouldSuppress ? nil : event
        }
    }

    private func removeShortcutCaptureLocalMonitor() {
        if let shortcutCaptureLocalMonitor {
            NSEvent.removeMonitor(shortcutCaptureLocalMonitor)
        }
        shortcutCaptureLocalMonitor = nil
    }

    private func completeShortcutCapture(with shortcut: HotkeyShortcut?) {
        guard isCapturingShortcut else { return }
        removeShortcutCaptureEventTap()
        removeShortcutCaptureLocalMonitor()
        let completion = shortcutCaptureCompletion
        shortcutCaptureCompletion = nil
        shortcutCaptureOwner = nil
        isCapturingShortcut = false
        completion?(shortcut)
        applyConfiguration()
    }

    fileprivate func handleShortcutCaptureEvent(
        _ eventType: CGEventType,
        rawFlags: UInt64,
        keyCode: UInt32,
        keyLabel: String?
    ) -> Bool {
        handleShortcutCaptureEvent(
            eventType,
            modifiers: Self.carbonModifiers(CGEventFlags(rawValue: rawFlags)),
            keyCode: keyCode,
            keyLabel: keyLabel
        )
    }

    private func handleShortcutCaptureEvent(
        _ eventType: CGEventType,
        modifiers: UInt32,
        keyCode: UInt32,
        keyLabel: String?
    ) -> Bool {
        guard isCapturingShortcut else { return false }
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let eventTap = shortcutCaptureEventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return false
        }
        let action = Self.shortcutCaptureAction(
            eventType: eventType,
            keyCode: keyCode,
            modifiers: modifiers,
            keyLabel: keyLabel
        )
        switch action {
        case .passThrough:
            return false
        case .suppress:
            if eventType == .keyDown { NSSound.beep() }
            return true
        case .cancel:
            completeShortcutCapture(with: nil)
            return true
        case let .capture(shortcut):
            completeShortcutCapture(with: shortcut)
            return true
        }
    }

    private static func carbonModifiers(_ flags: CGEventFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.maskControl) { result |= UInt32(controlKey) }
        if flags.contains(.maskAlternate) { result |= UInt32(optionKey) }
        if flags.contains(.maskShift) { result |= UInt32(shiftKey) }
        if flags.contains(.maskCommand) { result |= UInt32(cmdKey) }
        return result
    }

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }

    private static func keyLabel(keyCode: UInt32, fallback: String?) -> String {
        switch keyCode {
        case 36: return "↩"
        case 48: return "⇥"
        case 49: return "Space"
        case 51: return "⌫"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return fallback ?? "?"
        }
    }

    fileprivate func handleWindowsKeyEvent(_ eventType: CGEventType, rawFlags: UInt64, keyCode: Int64) {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            cancelWindowsSpacePresentation()
            windowsKeyGesture.reset()
            if let action = windowsSpaceGesture.reset() {
                onWindowsSpaceGesture?(action)
            }
            if let action = altTabGesture.cancel() {
                onAltTabGesture?(action)
            }
            stopAltTabModifierPolling()
            if let eventTap = windowsKeyEventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }
        let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(rawFlags))
        if eventType == .keyDown, keyCode == 53, let action = altTabGesture.cancel() {
            stopAltTabModifierPolling()
            onAltTabGesture?(action)
        }
        if eventType == .flagsChanged,
           let action = windowsSpaceGesture.flagsChanged(to: modifierFlags) {
            cancelWindowsSpacePresentation()
            onWindowsSpaceGesture?(action)
        }
        if eventType == .flagsChanged,
           let action = altTabGesture.flagsChanged(to: modifierFlags) {
            AltTabDiagnostics.logger.notice(
                "session=\(self.altTabSessionID, privacy: .public) modifier-release-detected source=event-tap elapsedMs=\(AltTabDiagnostics.milliseconds(since: self.altTabSessionStartedAt), privacy: .public)"
            )
            stopAltTabModifierPolling()
            onAltTabGesture?(action)
        }
        if windowsKeyGesture.handle(eventType: eventType, modifierFlags: modifierFlags) {
            onInvoke?(GlobalShortcutConfiguration(
                id: GlobalShortcutCatalog.startMenuID,
                title: "Start Menu",
                windowsShortcutLabel: "Win",
                isEnabled: true,
                shortcut: HotkeyShortcut(keyCode: 0, modifiers: 0, keyLabel: ""),
                usesWindowsKey: true,
                action: .toggleStartMenu,
                pinnedIndex: nil,
                applicationTarget: nil
            ))
        }
    }
}
