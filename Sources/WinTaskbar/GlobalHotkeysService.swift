import AppKit
import Carbon
import Foundation

private let winTaskbarHotKeySignature: OSType = 0x5754534B

struct OptionKeyGestureState {
    private static let combinationModifiers: NSEvent.ModifierFlags = [.command, .control, .shift, .function]

    private var optionIsDown = false
    private var canTrigger = false

    mutating func flagsChanged(to rawFlags: NSEvent.ModifierFlags) -> Bool {
        let flags = rawFlags.intersection(.deviceIndependentFlagsMask)
        let optionIsNowDown = flags.contains(.option)

        if !optionIsDown, optionIsNowDown {
            optionIsDown = true
            canTrigger = flags.intersection(Self.combinationModifiers).isEmpty
            return false
        }

        if optionIsDown, optionIsNowDown {
            canTrigger = false
            return false
        }

        guard optionIsDown else { return false }
        let shouldTrigger = canTrigger && flags.intersection(Self.combinationModifiers).isEmpty
        reset()
        return shouldTrigger
    }

    mutating func keyDown() {
        if optionIsDown { canTrigger = false }
    }

    mutating func reset() {
        optionIsDown = false
        canTrigger = false
    }
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
final class GlobalHotkeysService {
    var onToggleStartMenu: (() -> Void)?
    var onShowDesktop: (() -> Void)?
    var onLaunchPinned: ((Int) -> Void)?

    private var handler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private(set) var isEnabled = false
    private var shortcuts: [HotkeyShortcut] = []
    private var optionKeyGesture = OptionKeyGestureState()

    init() {
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

    func setEnabled(_ enabled: Bool, shortcuts: [HotkeyShortcut]? = nil) {
        if let shortcuts { self.shortcuts = shortcuts }
        guard enabled != isEnabled || shortcuts != nil else { return }
        unregisterAll()
        optionKeyGesture.reset()
        if enabled {
            for (index, shortcut) in self.shortcuts.enumerated() {
                let id = index < 2 ? index + 1 : 100 + index - 2
                register(id: id, shortcut: shortcut)
            }
            installEventMonitors()
        } else {
            removeEventMonitors()
        }
        isEnabled = enabled
    }

    fileprivate func handle(id: Int) {
        switch id {
        case 1: onToggleStartMenu?()
        case 2: onShowDesktop?()
        case 100...108: onLaunchPinned?(id - 100)
        default: break
        }
    }

    private func register(id: Int, shortcut: HotkeyShortcut) {
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: winTaskbarHotKeySignature, id: UInt32(id))
        if RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        ) == noErr,
           let reference {
            hotKeys.append(reference)
        }
    }

    private func unregisterAll() {
        hotKeys.forEach { _ = UnregisterEventHotKey($0) }
        hotKeys.removeAll()
    }

    private func installEventMonitors() {
        guard globalEventMonitor == nil, localEventMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handleMonitoredEvent(event) }
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handleMonitoredEvent(event) }
            return event
        }
    }

    private func removeEventMonitors() {
        if let globalEventMonitor { NSEvent.removeMonitor(globalEventMonitor) }
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
        globalEventMonitor = nil
        localEventMonitor = nil
    }

    private func handleMonitoredEvent(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            if optionKeyGesture.flagsChanged(to: event.modifierFlags) {
                onToggleStartMenu?()
            }
        case .keyDown:
            optionKeyGesture.keyDown()
        default:
            break
        }
    }
}
