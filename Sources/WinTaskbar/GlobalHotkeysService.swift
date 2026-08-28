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
    MainActor.assumeIsolated {
        service.handleWindowsKeyEvent(eventType, rawFlags: rawFlags)
    }
    return Unmanaged.passUnretained(event)
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

    @Published private(set) var registrationIssues: [String: String] = [:]
    @Published private(set) var windowsKeyIssue: String?

    private var handler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []
    private var configurationByHotKeyID: [Int: GlobalShortcutConfiguration] = [:]
    private var windowsKeyEventTap: CFMachPort?
    private var windowsKeyEventTapSource: CFRunLoopSource?
    private(set) var isEnabled = false
    private var configurations: [GlobalShortcutConfiguration] = []
    private var reverseWindowsSpaceHotKeyIDs: Set<Int> = []
    private var windowsKeyMapping: WindowsKeyMapping = .option
    private var windowsKeyOpensStart = true
    private var windowsKeyGesture = WindowsKeyGestureState()
    private var windowsSpaceGesture = WindowsSpaceGestureState()
    private var windowsSpacePresentationWorkItem: DispatchWorkItem?
    private var windowsSpacePresentationGeneration = 0
    private var windowsSpaceTrackingEnabled = false

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
    }

    func setConfiguration(
        enabled: Bool,
        windowsKeyMapping: WindowsKeyMapping,
        windowsKeyOpensStart: Bool,
        configurations: [GlobalShortcutConfiguration]
    ) {
        self.configurations = configurations
        self.windowsKeyMapping = windowsKeyMapping
        self.windowsKeyOpensStart = windowsKeyOpensStart
        unregisterAll()
        windowsKeyGesture = WindowsKeyGestureState(windowsModifier: windowsKeyMapping.eventModifier)
        windowsSpaceGesture = WindowsSpaceGestureState(windowsModifier: windowsKeyMapping.eventModifier)
        var issues = Self.duplicateIssues(configurations: configurations, mapping: windowsKeyMapping)
        for configuration in configurations where configuration.isEnabled && issues[configuration.id] == nil {
            issues[configuration.id] = configuration.validationIssue
        }
        windowsKeyIssue = nil
        if enabled {
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
        } else {
            removeWindowsKeyEventTap()
        }
        registrationIssues = issues
        isEnabled = enabled
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

    fileprivate func handle(id: Int) {
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
        guard status == noErr, let reference else { return "Unavailable (\(status))" }
        hotKeys.append(reference)
        configurationByHotKeyID[id] = configuration
        return nil
    }

    private func unregisterAll() {
        cancelWindowsSpacePresentation()
        if let action = windowsSpaceGesture.reset() {
            onWindowsSpaceGesture?(action)
        }
        hotKeys.forEach { _ = UnregisterEventHotKey($0) }
        hotKeys.removeAll()
        configurationByHotKeyID.removeAll()
        reverseWindowsSpaceHotKeyIDs.removeAll()
        windowsSpaceTrackingEnabled = false
        removeWindowsKeyEventTap()
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

    fileprivate func handleWindowsKeyEvent(_ eventType: CGEventType, rawFlags: UInt64) {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            cancelWindowsSpacePresentation()
            windowsKeyGesture.reset()
            if let action = windowsSpaceGesture.reset() {
                onWindowsSpaceGesture?(action)
            }
            if let eventTap = windowsKeyEventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }
        let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(rawFlags))
        if eventType == .flagsChanged,
           let action = windowsSpaceGesture.flagsChanged(to: modifierFlags) {
            cancelWindowsSpacePresentation()
            onWindowsSpaceGesture?(action)
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
