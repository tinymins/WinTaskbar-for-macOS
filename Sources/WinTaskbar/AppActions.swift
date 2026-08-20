import AppKit
import Combine

@MainActor
final class AppActions: ObservableObject {
    var toggleStartMenuHandler: (() -> Void)?
    var openSettingsHandler: (() -> Void)?
    var closeStartMenuHandler: (() -> Void)?
    var fitWindowsHandler: (() -> Void)?
    var showDesktopHandler: (() -> Void)?
    var powerHandler: ((PowerAction) -> Void)?

    func toggleStartMenu() { toggleStartMenuHandler?() }
    func openSettings() { openSettingsHandler?() }
    func closeStartMenu() { closeStartMenuHandler?() }
    func fitWindows() { fitWindowsHandler?() }
    func showDesktop() { showDesktopHandler?() }
    func performPower(_ action: PowerAction) { powerHandler?(action) }

    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") else { return }
        NSWorkspace.shared.open(url)
    }

    func quit() { NSApp.terminate(nil) }
}
