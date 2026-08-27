import AppKit
import Combine

enum SystemQuickAccess {
    case applications
    case battery
    case console
    case aboutThisMac
    case systemInformation
    case networkSettings
    case diskUtility
    case loginItems
    case terminal
    case activityMonitor
    case systemSettings
    case finder
    case spotlight

    var title: String {
        switch self {
        case .applications: "Applications"
        case .battery: "Battery / Energy"
        case .console: "Console"
        case .aboutThisMac: "About This Mac"
        case .systemInformation: "System Information"
        case .networkSettings: "Network Settings"
        case .diskUtility: "Disk Utility"
        case .loginItems: "Login Items & Extensions"
        case .terminal: "Terminal"
        case .activityMonitor: "Activity Monitor"
        case .systemSettings: "System Settings…"
        case .finder: "Finder"
        case .spotlight: "Spotlight Search"
        }
    }

    fileprivate var destination: Destination {
        switch self {
        case .applications: .folder(URL(fileURLWithPath: "/Applications", isDirectory: true))
        case .battery: .settingsPane("com.apple.Battery-Settings.extension")
        case .console: .application("com.apple.Console")
        case .aboutThisMac: .settingsPane("com.apple.SystemProfiler.AboutExtension")
        case .systemInformation: .application("com.apple.SystemProfiler")
        case .networkSettings: .settingsPane("com.apple.Network-Settings.extension")
        case .diskUtility: .application("com.apple.DiskUtility")
        case .loginItems: .settingsPane("com.apple.LoginItems-Settings.extension")
        case .terminal: .application("com.apple.Terminal")
        case .activityMonitor: .application("com.apple.ActivityMonitor")
        case .systemSettings: .application("com.apple.systempreferences")
        case .finder: .application("com.apple.finder")
        case .spotlight: .application("com.apple.Spotlight")
        }
    }

    fileprivate enum Destination {
        case folder(URL)
        case application(String)
        case settingsPane(String)
    }
}

@MainActor
final class AppActions: ObservableObject {
    var toggleStartMenuHandler: ((NSScreen?) -> Void)?
    var toggleQuickLinkMenuHandler: ((NSScreen?) -> Void)?
    var openSettingsHandler: ((SettingsPage?) -> Void)?
    var closeStartMenuHandler: (() -> Void)?
    var fitWindowsHandler: (() -> Void)?
    var showDesktopHandler: (() -> Void)?
    var powerHandler: ((PowerAction) -> Void)?

    func toggleStartMenu(on screen: NSScreen? = nil) { toggleStartMenuHandler?(screen) }
    func toggleQuickLinkMenu(on screen: NSScreen? = nil) { toggleQuickLinkMenuHandler?(screen) }
    func openSettings(page: SettingsPage? = nil) { openSettingsHandler?(page) }
    func closeStartMenu() { closeStartMenuHandler?() }
    func fitWindows() { fitWindowsHandler?() }
    func showDesktop() { showDesktopHandler?() }
    func performPower(_ action: PowerAction) { powerHandler?(action) }

    func open(_ shortcut: SystemQuickAccess) {
        switch shortcut.destination {
        case let .folder(url):
            NSWorkspace.shared.open(url)
        case let .application(bundleIdentifier):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return }
            NSWorkspace.shared.open(url)
        case let .settingsPane(identifier):
            guard let url = URL(string: "x-apple.systempreferences:\(identifier)") else { return }
            NSWorkspace.shared.open(url)
        }
    }

    func openFolder(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func showForceQuitApplications() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let source = CGEventSource(stateID: .hidSystemState)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: false)
            down?.flags = [.maskCommand, .maskAlternate]
            up?.flags = [.maskCommand, .maskAlternate]
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    func quit() { NSApp.terminate(nil) }
}
