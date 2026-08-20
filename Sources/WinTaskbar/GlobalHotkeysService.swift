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

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        unregisterAll()
        if enabled {
            register(id: 1, keyCode: 49)
            register(id: 2, keyCode: 2)
            let numberKeyCodes: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
            for (index, keyCode) in numberKeyCodes.enumerated() {
                register(id: 100 + index, keyCode: keyCode)
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

    private func register(id: Int, keyCode: UInt32) {
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: winTaskbarHotKeySignature, id: UInt32(id))
        let modifiers = UInt32(cmdKey | optionKey)
        if RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &reference) == noErr,
           let reference {
            hotKeys.append(reference)
        }
    }

    private func unregisterAll() {
        hotKeys.forEach { _ = UnregisterEventHotKey($0) }
        hotKeys.removeAll()
    }
}
