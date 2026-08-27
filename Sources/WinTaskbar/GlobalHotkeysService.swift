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

    @Published private(set) var registrationIssues: [String: String] = [:]
    @Published private(set) var windowsKeyIssue: String?

    private var handler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []
    private var configurationByHotKeyID: [Int: GlobalShortcutConfiguration] = [:]
    private var windowsKeyEventTap: CFMachPort?
    private var windowsKeyEventTapSource: CFRunLoopSource?
    private(set) var isEnabled = false
    private var configurations: [GlobalShortcutConfiguration] = []
    private var windowsKeyMapping: WindowsKeyMapping = .option
    private var windowsKeyOpensStart = true
    private var windowsKeyGesture = WindowsKeyGestureState()

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
        var issues = Self.duplicateIssues(configurations: configurations, mapping: windowsKeyMapping)
        windowsKeyIssue = nil
        if enabled {
            for (index, configuration) in configurations.enumerated() where configuration.isEnabled {
                guard issues[configuration.id] == nil else { continue }
                let shortcut = configuration.resolvedShortcut(mapping: windowsKeyMapping)
                if let issue = register(id: index + 1, shortcut: shortcut, configuration: configuration) {
                    issues[configuration.id] = issue
                }
            }
            if windowsKeyOpensStart, !installWindowsKeyEventTap() {
                windowsKeyIssue = "Event monitoring unavailable"
            }
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
        var registeredShortcuts: [String: String] = [:]
        for configuration in configurations where configuration.isEnabled {
            let shortcut = configuration.resolvedShortcut(mapping: mapping)
            let shortcutKey = "\(shortcut.keyCode):\(shortcut.modifiers)"
            if let duplicateTitle = registeredShortcuts[shortcutKey] {
                issues[configuration.id] = "Duplicates \(duplicateTitle)"
            } else {
                registeredShortcuts[shortcutKey] = configuration.title
            }
        }
        return issues
    }

    fileprivate func handle(id: Int) {
        guard let configuration = configurationByHotKeyID[id] else { return }
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
        hotKeys.forEach { _ = UnregisterEventHotKey($0) }
        hotKeys.removeAll()
        configurationByHotKeyID.removeAll()
        removeWindowsKeyEventTap()
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
            windowsKeyGesture.reset()
            if let eventTap = windowsKeyEventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }
        let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(rawFlags))
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
