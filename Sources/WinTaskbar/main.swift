import AppKit
import Carbon
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

        actions.toggleStartMenuHandler = { [weak startMenu] screen in startMenu?.toggle(on: screen) }
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
        globalHotkeysService.setEnabled(preferences.globalHotkeysEnabled, shortcuts: preferences.hotkeyShortcuts)
        Publishers.CombineLatest(preferences.$globalHotkeysEnabled, preferences.$hotkeyShortcuts)
            .sink { [weak self] enabled, shortcuts in
                self?.globalHotkeysService.setEnabled(enabled, shortcuts: shortcuts)
            }
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
            .applicationVersion: AppMetadata.version,
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
func runSelfTest() async -> Int32 {
    let suiteName = "WinTaskbar.SelfTest.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        fputs("SELF-TEST FAILED: cannot create temporary defaults\n", stderr)
        return 1
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let preferences = PreferencesStore(defaults: defaults)
    guard preferences.position == .bottom,
          preferences.barHeight == 48,
          preferences.iconScale == 1,
          preferences.iconPadding == 0.06,
          preferences.highlightStyle == .mac,
          preferences.transparencyEnabled,
          preferences.panelOpacity == 1,
          preferences.panelBlurRadius == 20,
          preferences.trayClockEnabled,
          preferences.menuButtonPlacement == .standard,
          preferences.hotkeyShortcuts.count == 11 else {
        fputs("SELF-TEST FAILED: default values mismatch\n", stderr)
        return 1
    }

    let rightMenuFrame = StartMenuGeometry.frame(
        screenFrame: NSRect(x: 0, y: 0, width: 1200, height: 800),
        visibleFrame: NSRect(x: 0, y: 0, width: 1200, height: 775),
        position: .right,
        barHeight: 52,
        heightMode: .standard,
        oppositeEnd: false
    )
    guard rightMenuFrame == NSRect(x: 748, y: 320, width: 400, height: 480) else {
        fputs("SELF-TEST FAILED: start menu corner anchoring mismatch\n", stderr)
        return 1
    }

    guard RunningIndicatorLayout.underline(
        position: .bottom,
        cellSize: 40,
        isActive: true,
        highlightStyle: .windows
    ) == RunningIndicatorLayout(width: 24, height: 2, opacity: 1, edgePadding: 3),
    RunningIndicatorLayout.underline(
        position: .left,
        cellSize: 40,
        isActive: false,
        highlightStyle: .mac
    ) == RunningIndicatorLayout(width: 2, height: 14, opacity: 0.7, edgePadding: -3),
    RunningIndicatorLayout.dot(highlightStyle: .windows)
        == RunningIndicatorLayout(width: 4, height: 4, opacity: 0.7, edgePadding: 3),
    RunningIndicatorLayout.dot(highlightStyle: .mac)
        == RunningIndicatorLayout(width: 4, height: 4, opacity: 0.7, edgePadding: -2) else {
        fputs("SELF-TEST FAILED: running indicator geometry mismatch\n", stderr)
        return 1
    }

    guard TaskbarItemGeometry.calculate(
        barHeight: 48,
        iconScale: 1,
        iconPadding: 0.06
    ) == TaskbarItemGeometry(cellSize: 40, iconSize: 35.2) else {
        fputs("SELF-TEST FAILED: taskbar item geometry mismatch\n", stderr)
        return 1
    }

    guard WindowPreviewPlacement.arrowEdge(for: .top) == .top,
          WindowPreviewPlacement.arrowEdge(for: .bottom) == .bottom,
          WindowPreviewPlacement.arrowEdge(for: .left) == .leading,
          WindowPreviewPlacement.arrowEdge(for: .right) == .trailing else {
        fputs("SELF-TEST FAILED: window preview placement mismatch\n", stderr)
        return 1
    }

    guard WindowPeekGeometry.localFrame(
        windowFrame: CGRect(x: 2000, y: 100, width: 800, height: 600),
        displayBounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080)
    ) == CGRect(x: 80, y: 380, width: 800, height: 600),
    WindowPeekGeometry.localFrame(
        windowFrame: CGRect(x: 120, y: -800, width: 900, height: 500),
        displayBounds: CGRect(x: 0, y: -900, width: 1440, height: 900)
    ) == CGRect(x: 120, y: 300, width: 900, height: 500) else {
        fputs("SELF-TEST FAILED: window peek display conversion mismatch\n", stderr)
        return 1
    }

    guard TaskbarAttentionPolicy.shouldFlash(previous: nil, current: "1"),
          TaskbarAttentionPolicy.shouldFlash(previous: "1", current: "2"),
          !TaskbarAttentionPolicy.shouldFlash(previous: "2", current: "1"),
          !TaskbarAttentionPolicy.shouldFlash(previous: "2", current: "2"),
          TaskbarAttentionPolicy.shouldFlash(previous: "new", current: "urgent"),
          !TaskbarAttentionPolicy.shouldFlash(previous: "new", current: "new"),
          !TaskbarAttentionPolicy.shouldFlash(previous: "1", current: nil) else {
        fputs("SELF-TEST FAILED: taskbar attention policy mismatch\n", stderr)
        return 1
    }

    let legacySuiteName = "WinTaskbar.SelfTest.LegacyGeometry.\(UUID().uuidString)"
    guard let legacyDefaults = UserDefaults(suiteName: legacySuiteName) else {
        fputs("SELF-TEST FAILED: cannot create legacy geometry defaults\n", stderr)
        return 1
    }
    defer { legacyDefaults.removePersistentDomain(forName: legacySuiteName) }
    legacyDefaults.set(52.0, forKey: "wintaskbar.barHeight")
    legacyDefaults.set(36.0, forKey: "wintaskbar.iconScale")
    legacyDefaults.set(5.0, forKey: "wintaskbar.iconPadding")
    let migratedPreferences = PreferencesStore(defaults: legacyDefaults)
    guard migratedPreferences.barHeight == 48,
          migratedPreferences.iconScale == 1,
          migratedPreferences.iconPadding == 0.06,
          legacyDefaults.double(forKey: "wintaskbar.iconScale") == 1,
          legacyDefaults.double(forKey: "wintaskbar.iconPadding") == 0.06 else {
        fputs("SELF-TEST FAILED: recovered geometry migration mismatch\n", stderr)
        return 1
    }

    preferences.position = .left
    preferences.barHeight = 64
    preferences.trayWifiEnabled = false
    preferences.pinnedBundleIDs = ["one", "two", "three"]
    preferences.reorderPinned("three", before: "one")
    preferences.appFolders = [AppFolder(name: "Work", bundleIDs: ["one"])]
    preferences.hotkeyShortcuts[0] = HotkeyShortcut(keyCode: 0, modifiers: UInt32(cmdKey), keyLabel: "A")
    guard defaults.string(forKey: "wintaskbar.position") == "Left",
          defaults.double(forKey: "wintaskbar.barHeight") == 64,
          defaults.bool(forKey: "wintaskbar.feature.trayWifi") == false,
          preferences.pinnedBundleIDs == ["three", "one", "two"],
          PreferencesStore(defaults: defaults).appFolders.first?.bundleIDs == ["one"],
          PreferencesStore(defaults: defaults).hotkeyShortcuts.first?.keyLabel == "A",
          DockBadgeService.parseStatusLabel("124 notifications") == "124" else {
        fputs("SELF-TEST FAILED: preference keys did not persist\n", stderr)
        return 1
    }

    let testAppURL = URL(fileURLWithPath: "/System/Applications/App Store.app")
    guard let itemProvider = NSItemProvider(contentsOf: testAppURL),
          FileURLDropLoader.matchingProviders(in: [itemProvider]).count == 1,
          let loadedURL = await FileURLDropLoader.loadFileURL(from: itemProvider),
          loadedURL.standardizedFileURL.path == testAppURL.standardizedFileURL.path else {
        fputs("SELF-TEST FAILED: app URL drag provider did not round-trip\n", stderr)
        return 1
    }
    print("SELF-TEST PASSED: defaults, taskbar geometry and attention, preference persistence, and app URL drag provider")
    return 0
}

if CommandLine.arguments.contains("--self-test") {
    let application = NSApplication.shared
    Task { @MainActor in exit(await runSelfTest()) }
    application.run()
} else {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
