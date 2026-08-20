import AppKit
import Combine
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = PreferencesStore.shared
    private let apps = AppDiscoveryService()
    private let status = SystemStatusService()
    private let actions = AppActions()
    private let windowActivator = WindowActivationService()
    private let windowsService = WindowsService()
    private let recentDocuments = RecentDocumentsService()
    private let dockBadges = DockBadgeService()
    private let powerService = PowerService()
    private let showDesktopService = ShowDesktopService()
    private lazy var windowFittingService = WindowFittingService(preferences: preferences)
    private let dockToggleService = DockToggleService.shared
    private let loginItemService = LoginItemService.shared
    private let permissionsService = PermissionsService.shared
    private let globalHotkeysService = GlobalHotkeysService()
    private var cancellables = Set<AnyCancellable>()

    private var taskbarController: TaskbarWindowController?
    private var startMenuController: StartMenuController?
    private var settingsController: SettingsWindowController?
    private var onboardingController: OnboardingWindowController?
    private var screenObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildApplicationMenu()

        let taskbar = TaskbarWindowController(
            preferences: preferences,
            apps: apps,
            status: status,
            actions: actions,
            windowActivator: windowActivator,
            windowsService: windowsService,
            recentDocuments: recentDocuments,
            dockBadges: dockBadges
        )
        let startMenu = StartMenuController(
            preferences: preferences,
            apps: apps,
            actions: actions,
            taskbar: taskbar
        )
        let settings = SettingsWindowController(preferences: preferences)

        actions.toggleStartMenuHandler = { [weak startMenu] in startMenu?.toggle() }
        actions.closeStartMenuHandler = { [weak startMenu] in startMenu?.hide() }
        actions.openSettingsHandler = { [weak settings, weak startMenu] in
            startMenu?.hide()
            settings?.show()
        }
        actions.fitWindowsHandler = { [weak self] in
            self?.windowFittingService.fitAllWindowsToFreeSpace()
        }
        actions.showDesktopHandler = { [weak self] in self?.showDesktopService.toggle() }
        actions.powerHandler = { [weak self] action in self?.confirmAndPerform(action) }

        globalHotkeysService.onToggleStartMenu = { [weak startMenu] in
            startMenu?.toggle()
        }
        globalHotkeysService.onShowDesktop = { [weak self] in
            self?.showDesktopService.toggle()
        }
        globalHotkeysService.onLaunchPinned = { [weak self] index in
            guard let self, self.preferences.pinnedBundleIDs.indices.contains(index),
                  let app = self.apps.app(bundleIdentifier: self.preferences.pinnedBundleIDs[index]) else { return }
            self.apps.open(app)
        }
        globalHotkeysService.setEnabled(preferences.globalHotkeysEnabled)
        preferences.$globalHotkeysEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in self?.globalHotkeysService.setEnabled(enabled) }
            .store(in: &cancellables)
        preferences.$position
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] position in
                guard let self else { return }
                if self.dockToggleService.isDockHidden {
                    let orientation = position == .left ? "right" : position == .right ? "left" : "bottom"
                    self.dockToggleService.syncDock(orientation: orientation)
                }
                self.windowFittingService.fitAllWindowsToFreeSpace()
            }
            .store(in: &cancellables)

        taskbarController = taskbar
        startMenuController = startMenu
        settingsController = settings
        taskbar.show()
        windowFittingService.start()
        if !preferences.hasCompletedOnboarding {
            let onboarding = OnboardingWindowController(preferences: preferences)
            onboardingController = onboarding
            onboarding.present()
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.taskbarController?.rebuildPanels() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    @objc private func showSettings(_ sender: Any?) { settingsController?.show() }

    @objc private func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "WinTaskbar",
            .applicationVersion: "1.0.0",
            .credits: NSAttributedString(string: "A Windows-style taskbar for macOS.")
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    private func confirmAndPerform(_ action: PowerAction) {
        if action == .lockScreen || action == .sleep {
            powerService.perform(action)
            return
        }
        let alert = NSAlert()
        alert.messageText = action.rawValue
        alert.informativeText = "Are you sure you want to \(action.rawValue.lowercased())?"
        alert.addButton(withTitle: action.rawValue)
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { powerService.perform(action) }
    }

    private func buildApplicationMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About WinTaskbar", action: #selector(showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit WinTaskbar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu
    }
}

@MainActor
func runSelfTest() -> Int32 {
    let suiteName = "WinTaskbar.SelfTest.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        fputs("SELF-TEST FAILED: cannot create temporary defaults\n", stderr)
        return 1
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let preferences = PreferencesStore(defaults: defaults)
    guard preferences.position == .bottom,
          preferences.barHeight == 52,
          preferences.trayClockEnabled else {
        fputs("SELF-TEST FAILED: default values mismatch\n", stderr)
        return 1
    }

    preferences.position = .left
    preferences.barHeight = 64
    preferences.trayWifiEnabled = false
    preferences.pinnedBundleIDs = ["one", "two", "three"]
    preferences.reorderPinned("three", before: "one")
    preferences.appFolders = [AppFolder(name: "Work", bundleIDs: ["one"])]
    guard defaults.string(forKey: "wintaskbar.position") == "Left",
          defaults.double(forKey: "wintaskbar.barHeight") == 64,
          defaults.bool(forKey: "wintaskbar.feature.trayWifi") == false,
          preferences.pinnedBundleIDs == ["three", "one", "two"],
          PreferencesStore(defaults: defaults).appFolders.first?.bundleIDs == ["one"],
          DockBadgeService.parseStatusLabel("124 notifications") == "124" else {
        fputs("SELF-TEST FAILED: preference keys did not persist\n", stderr)
        return 1
    }
    print("SELF-TEST PASSED: defaults and preference persistence")
    return 0
}

if CommandLine.arguments.contains("--self-test") {
    exit(runSelfTest())
} else {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
