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
#if DEBUG
        if CommandLine.arguments.contains("--attention-demo") {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.dockBadges.runAttentionDemo()
            }
        }
#endif
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
    RunningIndicatorLayout.underline(
        position: .bottom,
        cellSize: 40,
        isActive: false,
        highlightStyle: .windows,
        requestsAttention: true
    ) == RunningIndicatorLayout(width: 30, height: 2, opacity: 0.7, edgePadding: 3),
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

    let fittingScreen = WindowFittingScreenBox(
        frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
        visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 775)
    )
    guard WindowFittingGeometry.freeRect(
        on: fittingScreen,
        position: .bottom,
        barHeight: 48
    ) == CGRect(x: 0, y: 51, width: 1200, height: 724),
    WindowFittingGeometry.freeRect(
        on: fittingScreen,
        position: .top,
        barHeight: 48
    ) == CGRect(x: 0, y: 0, width: 1200, height: 724),
    WindowFittingGeometry.freeRect(
        on: fittingScreen,
        position: .left,
        barHeight: 48
    ) == CGRect(x: 51, y: 0, width: 1149, height: 775),
    WindowFittingGeometry.freeRect(
        on: fittingScreen,
        position: .right,
        barHeight: 48
    ) == CGRect(x: 0, y: 0, width: 1149, height: 775),
    WindowFittingGeometry.clampedRect(
        CGRect(x: 100, y: 20, width: 600, height: 500),
        on: fittingScreen,
        position: .bottom,
        barHeight: 48
    ) == CGRect(x: 100, y: 51, width: 600, height: 469),
    WindowFittingGeometry.clampedRect(
        CGRect(x: 900, y: 100, width: 300, height: 400),
        on: fittingScreen,
        position: .right,
        barHeight: 48
    ) == CGRect(x: 900, y: 100, width: 249, height: 400),
    WindowFittingGeometry.clampedRect(
        CGRect(x: 100, y: 100, width: 600, height: 500),
        on: fittingScreen,
        position: .bottom,
        barHeight: 48
    ) == nil,
    WindowFittingGeometry.cocoaFrame(
        axPosition: CGPoint(x: 80, y: 120),
        size: CGSize(width: 600, height: 400),
        primaryHeight: 800
    ) == CGRect(x: 80, y: 280, width: 600, height: 400),
    WindowFittingGeometry.axPosition(
        cocoaFrame: CGRect(x: 80, y: 280, width: 600, height: 400),
        primaryHeight: 800
    ) == CGPoint(x: 80, y: 120),
    WindowFittingGeometry.isFullScreen(fittingScreen.frame, in: [fittingScreen]) else {
        fputs("SELF-TEST FAILED: window fitting geometry mismatch\n", stderr)
        return 1
    }

    guard WindowPreviewPlacement.arrowEdge(for: .top) == .top,
          WindowPreviewPlacement.arrowEdge(for: .bottom) == .bottom,
          WindowPreviewPlacement.arrowEdge(for: .left) == .leading,
          WindowPreviewPlacement.arrowEdge(for: .right) == .trailing,
          WindowPreviewLayout.axis(for: .top) == .horizontal,
          WindowPreviewLayout.axis(for: .bottom) == .horizontal,
          WindowPreviewLayout.axis(for: .left) == .vertical,
          WindowPreviewLayout.axis(for: .right) == .vertical else {
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

    var optionGesture = OptionKeyGestureState()
    guard !optionGesture.flagsChanged(to: [.option]),
          optionGesture.flagsChanged(to: []) else {
        fputs("SELF-TEST FAILED: Option-only release did not trigger\n", stderr)
        return 1
    }
    optionGesture = OptionKeyGestureState()
    guard !optionGesture.flagsChanged(to: [.capsLock, .option]),
          optionGesture.flagsChanged(to: [.capsLock]) else {
        fputs("SELF-TEST FAILED: Caps Lock blocked Option-only release\n", stderr)
        return 1
    }
    optionGesture = OptionKeyGestureState()
    _ = optionGesture.handle(eventType: .flagsChanged, modifierFlags: [.option])
    _ = optionGesture.handle(eventType: .keyDown)
    guard !optionGesture.flagsChanged(to: []) else {
        fputs("SELF-TEST FAILED: Option key combination triggered\n", stderr)
        return 1
    }
    optionGesture = OptionKeyGestureState()
    guard !optionGesture.flagsChanged(to: [.command]),
          !optionGesture.flagsChanged(to: [.command, .option]),
          !optionGesture.flagsChanged(to: [.command]) else {
        fputs("SELF-TEST FAILED: pre-held modifier combination triggered\n", stderr)
        return 1
    }
    optionGesture = OptionKeyGestureState()
    guard !optionGesture.flagsChanged(to: [.option]),
          !optionGesture.flagsChanged(to: [.option, .shift]),
          !optionGesture.flagsChanged(to: [.shift]) else {
        fputs("SELF-TEST FAILED: modifier added after Option triggered\n", stderr)
        return 1
    }
    optionGesture = OptionKeyGestureState()
    guard !optionGesture.flagsChanged(to: [.option]),
          !optionGesture.flagsChanged(to: [.option]),
          !optionGesture.flagsChanged(to: []) else {
        fputs("SELF-TEST FAILED: dual Option gesture triggered\n", stderr)
        return 1
    }

    guard TaskbarAttentionPolicy.shouldRequest(previous: nil, current: "1"),
          TaskbarAttentionPolicy.shouldRequest(previous: "1", current: "2"),
          !TaskbarAttentionPolicy.shouldRequest(previous: "2", current: "1"),
          !TaskbarAttentionPolicy.shouldRequest(previous: "2", current: "2"),
          TaskbarAttentionPolicy.shouldRequest(previous: "new", current: "urgent"),
          !TaskbarAttentionPolicy.shouldRequest(previous: "new", current: "new"),
          !TaskbarAttentionPolicy.shouldRequest(previous: "1", current: nil) else {
        fputs("SELF-TEST FAILED: taskbar attention policy mismatch\n", stderr)
        return 1
    }

    var attentionTracker = TaskbarAttentionTracker()
    attentionTracker.apply(["chat": "4"], activeBundleID: nil)
    guard attentionTracker.states.isEmpty else {
        fputs("SELF-TEST FAILED: initial badge snapshot requested attention\n", stderr)
        return 1
    }
    attentionTracker.apply(["chat": "5"], activeBundleID: nil)
    guard attentionTracker.states["chat"]?.pulseGeneration == 1 else {
        fputs("SELF-TEST FAILED: badge increase did not request attention\n", stderr)
        return 1
    }
    attentionTracker.apply(["chat": "5"], activeBundleID: nil)
    attentionTracker.apply(["chat": "3"], activeBundleID: nil)
    guard attentionTracker.states["chat"]?.pulseGeneration == 1 else {
        fputs("SELF-TEST FAILED: unchanged or decreased badge retriggered attention\n", stderr)
        return 1
    }
    attentionTracker.acknowledge("chat")
    attentionTracker.apply(["chat": "6"], activeBundleID: "chat")
    guard attentionTracker.states.isEmpty else {
        fputs("SELF-TEST FAILED: active app retained attention\n", stderr)
        return 1
    }
    attentionTracker.apply(["chat": "7"], activeBundleID: nil)
    guard attentionTracker.states["chat"]?.pulseGeneration == 1 else {
        fputs("SELF-TEST FAILED: post-acknowledgement increase did not request attention\n", stderr)
        return 1
    }
    attentionTracker.apply([:], activeBundleID: nil)
    guard attentionTracker.states["chat"]?.pulseGeneration == 1 else {
        fputs("SELF-TEST FAILED: cleared badge removed unacknowledged attention\n", stderr)
        return 1
    }
    attentionTracker.apply([:], activeBundleID: "chat")
    guard attentionTracker.states["chat"]?.pulseGeneration == 1 else {
        fputs("SELF-TEST FAILED: polling cleared unacknowledged attention\n", stderr)
        return 1
    }
    attentionTracker.acknowledge("chat")
    guard attentionTracker.states.isEmpty else {
        fputs("SELF-TEST FAILED: explicit app activation retained attention\n", stderr)
        return 1
    }
    attentionTracker.apply(["chat": "1"], activeBundleID: nil)
    attentionTracker.retainRunning([])
    guard attentionTracker.states.isEmpty else {
        fputs("SELF-TEST FAILED: terminated app retained attention\n", stderr)
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
          DockBadgeService.parseStatusLabel("124 notifications") == "124",
          DockBadgeService.parseLSAppInfoOutput("\"StatusLabel\"={ \"label\"=\"124 notifications\" }") == "124",
          DockBadgeService.parseLSAppInfoOutput("\"StatusLabel\"=[ NULL ]") == nil else {
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
    print("SELF-TEST PASSED: defaults, taskbar and window fitting geometry, Option gesture, attention, preference persistence, and app URL drag provider")
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
