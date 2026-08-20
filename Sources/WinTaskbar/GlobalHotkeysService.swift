import Carbon
import Foundation

private let winTaskbarHotKeySignature: OSType = 0x5754534B

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
    private(set) var isEnabled = false
    private var shortcuts: [HotkeyShortcut] = []

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
        if enabled {
            for (index, shortcut) in self.shortcuts.enumerated() {
                let id = index < 2 ? index + 1 : 100 + index - 2
                register(id: id, shortcut: shortcut)
            }
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
}
