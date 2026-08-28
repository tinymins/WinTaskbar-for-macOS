import AppKit
import Carbon
import Combine
import EventKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = PreferencesStore.shared
    private let apps = AppDiscoveryService()
    private let status = SystemStatusService()
    private let externalStatusItems = ExternalStatusItemService()
    private let actions = AppActions()
    private let windowsService = WindowsService()
    private lazy var windowActivator = WindowActivationService(windowsService: windowsService)
    private let recentDocuments = RecentDocumentsService()
    private let dockBadges = DockBadgeService()
    private let powerService = PowerService()
    private let showDesktopService = ShowDesktopService()
    private lazy var activeWindowShortcutService = ActiveWindowShortcutService(preferences: preferences)
    private let systemShortcutService = SystemShortcutService()
    private let clipboardHistoryService = ClipboardHistoryService()
    private let runWindowController = RunWindowController()
    private lazy var windowFittingService = WindowFittingService(preferences: preferences)
    private lazy var windowArrangementService = WindowArrangementService(preferences: preferences)
    private let dockToggleService = DockToggleService.shared
    private let loginItemService = LoginItemService.shared
    private let permissionsService = PermissionsService.shared
    private let globalHotkeysService = GlobalHotkeysService.shared
    private var cancellables = Set<AnyCancellable>()

    private var taskbarController: TaskbarWindowController?
    private var startMenuController: StartMenuController?
    private var settingsController: SettingsWindowController?
    private var onboardingController: OnboardingWindowController?
    private var screenObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildApplicationMenu()
        dockToggleService.applyConfiguredStateOnLaunch()
        recentDocuments.start()
        clipboardHistoryService.start()

        let taskbar = TaskbarWindowController(
            preferences: preferences,
            apps: apps,
            status: status,
            externalStatusItems: externalStatusItems,
            actions: actions,
            windowActivator: windowActivator,
            windowsService: windowsService,
            recentDocuments: recentDocuments,
            dockBadges: dockBadges,
            activeWindowShortcuts: activeWindowShortcutService,
            clipboardHistory: clipboardHistoryService,
            systemShortcuts: systemShortcutService
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
        settings.onVisibilityChanged = { [weak startMenu, weak taskbar] visible in
            startMenu?.setSettingsObservationMode(visible)
            taskbar?.setSettingsObservationMode(visible)
        }
        actions.openSettingsHandler = { [weak settings] page in settings?.show(page: page) }
        actions.fitWindowsHandler = { [weak self] in
            self?.windowFittingService.fitAllWindowsToFreeSpace()
        }
        globalHotkeysService.onWindowsSpaceGesture = { [weak taskbar] action in
            taskbar?.handleWindowsSpaceGesture(action)
        }
        actions.showDesktopHandler = { [weak self] in self?.showDesktopService.toggle() }
        actions.powerHandler = { [weak self] action in self?.confirmAndPerform(action) }
        actions.showRunDialogHandler = { [weak self] in self?.runWindowController.show() }
        actions.arrangeWindowsHandler = { [weak self, weak taskbar] arrangement, requestedScreen in
            guard let self, let screen = requestedScreen ?? taskbar?.activeScreen else { return }
            self.windowArrangementService.arrange(arrangement, on: screen)
        }
        actions.minimizeAllWindowsHandler = { [weak self, weak taskbar] requestedScreen in
            guard let self, let screen = requestedScreen ?? taskbar?.activeScreen else { return }
            self.windowArrangementService.minimizeAll(on: screen)
        }
        actions.restoreAllWindowsHandler = { [weak self] in
            self?.windowArrangementService.restoreMinimized()
        }

        globalHotkeysService.onInvoke = { [weak self] configuration in
            self?.performGlobalShortcut(configuration)
        }
        let registeredShortcutConfigurations = preferences.$globalShortcutConfigurations
            .combineLatest(preferences.$customShortcutConfigurations)
            .map { builtIn, custom in
                builtIn + custom.compactMap { $0.registrationConfiguration() }
            }
        Publishers.CombineLatest4(
            preferences.$globalHotkeysEnabled,
            preferences.$windowsKeyMapping,
            preferences.$windowsKeyOpensStart,
            registeredShortcutConfigurations
        )
            .sink { [weak self] enabled, mapping, opensStart, configurations in
                self?.globalHotkeysService.setConfiguration(
                    enabled: enabled,
                    windowsKeyMapping: mapping,
                    windowsKeyOpensStart: opensStart,
                    configurations: configurations
                )
            }
            .store(in: &cancellables)
        preferences.$trayClockEnabled
            .combineLatest(preferences.$trayClockShowsSeconds)
            .removeDuplicates { previous, current in
                previous.0 == current.0 && previous.1 == current.1
            }
            .sink { [weak self] clockEnabled, showsSeconds in
                self?.status.setClockShowsSeconds(clockEnabled && showsSeconds)
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
        if CommandLine.arguments.contains("--run-demo") {
            runWindowController.show()
        }
        if CommandLine.arguments.contains("--settings-demo") {
            startMenu.toggle()
            settings.show()
        }
#endif
        windowFittingService.start()
        var shouldShowOnboarding = !preferences.hasCompletedOnboarding
#if DEBUG
        shouldShowOnboarding = shouldShowOnboarding
            && !CommandLine.arguments.contains("--run-demo")
            && !CommandLine.arguments.contains("--settings-demo")
#endif
        if shouldShowOnboarding {
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

    private func performGlobalShortcut(_ configuration: GlobalShortcutConfiguration) {
        switch configuration.action {
        case .toggleStartMenu:
            startMenuController?.toggle()
        case .toggleQuickLinkMenu:
            taskbarController?.toggleQuickLinkMenu()
        case .showDesktop:
            showDesktopService.toggle()
        case .openFileManager:
            openFileManager(configuration.applicationTarget)
        case .openSystemSettings:
            openApplication(bundleIdentifier: "com.apple.systempreferences")
        case .openSearch:
            if let target = configuration.applicationTarget {
                openApplication(target)
            } else {
                openApplication(bundleIdentifier: "com.apple.Spotlight")
            }
        case .openApplication:
            guard let target = configuration.applicationTarget else { return }
            openApplication(target)
        case .showRunDialog:
            runWindowController.show()
        case .lockScreen:
            powerService.perform(.lockScreen)
        case .toggleQuickSettings:
            taskbarController?.toggleQuickSettings()
        case .toggleCalendar:
            taskbarController?.toggleCalendar()
        case .toggleInputSources:
            taskbarController?.toggleInputSources()
        case .snapWindowLeft:
            activeWindowShortcutService.place(.leftHalf)
        case .snapWindowRight:
            activeWindowShortcutService.place(.rightHalf)
        case .maximizeWindow:
            activeWindowShortcutService.place(.maximized)
        case .restoreOrMinimizeWindow:
            activeWindowShortcutService.restoreOrMinimize()
        case .toggleSnapLayouts:
            taskbarController?.toggleSnapLayouts()
        case .showTaskView:
            systemShortcutService.showTaskView()
        case .moveWindowToPreviousDisplay:
            activeWindowShortcutService.moveToAdjacentDisplay(step: -1)
        case .moveWindowToNextDisplay:
            activeWindowShortcutService.moveToAdjacentDisplay(step: 1)
        case .minimizeAllWindows:
            showDesktopService.minimizeAll()
        case .restoreMinimizedWindows:
            showDesktopService.restoreMinimized()
        case .cycleTaskbarApps:
            taskbarController?.cycleTaskbarApps()
        case .focusSystemTray:
            taskbarController?.focusSystemTray()
        case .showClipboardHistory:
            taskbarController?.toggleClipboardHistory()
        case .captureScreenRegion:
            systemShortcutService.captureScreenRegion()
        case .showCharacterPalette:
            systemShortcutService.showCharacterPalette()
        case .openAccessibilitySettings:
            systemShortcutService.openAccessibilitySettings()
        case .openDisplaySettings, .openWirelessDisplaySettings:
            systemShortcutService.openDisplaySettings()
        case .minimizeOtherWindows:
            showDesktopService.toggleOtherWindows()
        case .createDesktop:
            systemShortcutService.createDesktop()
        case .switchDesktopLeft:
            systemShortcutService.switchDesktop(.left)
        case .switchDesktopRight:
            systemShortcutService.switchDesktop(.right)
        case .closeDesktop:
            systemShortcutService.closeDesktop()
        case .launchPinned:
            guard let index = configuration.pinnedIndex,
                  preferences.pinnedBundleIDs.indices.contains(index),
                  let app = apps.app(bundleIdentifier: preferences.pinnedBundleIDs[index]) else { return }
            apps.open(app)
        }
    }

    private func openFileManager(_ target: ShortcutApplicationTarget?) {
        let homeURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        guard let target else {
            NSWorkspace.shared.open(homeURL)
            return
        }
        guard let applicationURL = target.resolvedURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [homeURL],
            withApplicationAt: applicationURL,
            configuration: configuration
        )
    }

    private func openApplication(_ target: ShortcutApplicationTarget) {
        guard let url = target.resolvedURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    private func openApplication(bundleIdentifier: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        dockToggleService.restoreDockOnExit()
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
        if !action.requiresConfirmation {
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
    var trayLayout = ExternalStatusItemLayout(orderedIDs: ["one", "two"])
    trayLayout.reconcile(discoveredIDs: ["two", "three", "three"])
    trayLayout.setHidden(true, itemID: "two")
    trayLayout.move(itemID: "three", relativeTo: "one", after: false, hidden: true)
    trayLayout.move(itemID: "two", relativeTo: "one", after: true, hidden: false)
    var unifiedTrayLayout = ExternalStatusItemLayout(
        orderedIDs: ["external-one"] + SystemTrayItemID.allCases.map(\.rawValue)
    )
    unifiedTrayLayout.reconcile(
        discoveredIDs: ["external-two"],
        beforeIDs: Set(SystemTrayItemID.allCases.map(\.rawValue))
    )
    unifiedTrayLayout.move(
        itemID: SystemTrayItemID.inputSource.rawValue,
        relativeTo: SystemTrayItemID.wifi.rawValue,
        after: false,
        hidden: false
    )
    let trayLayoutStore = ExternalStatusItemLayoutStore(defaults: defaults)
    trayLayoutStore.save(trayLayout)
    let restoredTrayLayout = trayLayoutStore.load()
    let unchangedTrayImage = ExternalStatusItemImageFingerprint.make(
        width: 1,
        height: 1,
        rgbaBytes: [0, 0, 0, 255]
    )
    let changedTrayImage = ExternalStatusItemImageFingerprint.make(
        width: 1,
        height: 1,
        rgbaBytes: [255, 255, 255, 255]
    )
    let unchangedTrayPresentation = ExternalStatusItemRefreshState(
        id: "com.example.StatusApp|status-item",
        processIdentifier: 101,
        accessibilityLabel: "Status App",
        sourceFrame: CGRect(x: 100, y: 2, width: 24, height: 24),
        imageFingerprint: unchangedTrayImage,
        fallbackPath: nil
    )
    let changedTrayPresentation = ExternalStatusItemRefreshState(
        id: unchangedTrayPresentation.id,
        processIdentifier: unchangedTrayPresentation.processIdentifier,
        accessibilityLabel: unchangedTrayPresentation.accessibilityLabel,
        sourceFrame: unchangedTrayPresentation.sourceFrame,
        imageFingerprint: changedTrayImage,
        fallbackPath: nil
    )
    guard SettingsPage.allCases.map(\.rawValue) == [
        "General",
        "Appearance",
        "Start Menu",
        "Taskbar & Tray",
        "Date & time",
        "Hotkeys",
        "Shortcut Mappings",
        "About"
    ],
          TransientSurfaceDismissalPolicy.shouldDismissForOutsideInteraction(
              keepsVisibleForSettings: false
          ),
          !TransientSurfaceDismissalPolicy.shouldDismissForOutsideInteraction(
              keepsVisibleForSettings: true
          ),
          preferences.position == .bottom,
          !preferences.autoHideTaskbar,
          preferences.showBadgesOnTaskbarApps,
          preferences.showFlashingOnTaskbarApps,
          preferences.barHeight == 48,
          preferences.iconScale == 1,
          preferences.iconPadding == 0.06,
          preferences.highlightStyle == .mac,
          preferences.transparencyEnabled,
          preferences.panelOpacity == 1,
          preferences.panelBlurRadius == 20,
          preferences.trayClockEnabled,
          preferences.trayClockShowsSeconds,
          preferences.dateTimeCalendarKind == .gregorian,
          preferences.dateTimeFirstDayOfWeek == .sunday,
          preferences.dateTimeShortDatePattern == "M/d/yyyy",
          preferences.dateTimeLongDateStyle == .windowsFull,
          preferences.dateTimeFormatConfiguration.longDatePattern == "EEEE, MMMM d, yyyy",
          !preferences.dateTimeFormatConfiguration.longDateIncludesLunar,
          preferences.dateTimeShortTimePattern == "HH:mm",
          preferences.dateTimeLongTimePattern == "HH:mm:ss",
          preferences.additionalClocks == AdditionalClockConfiguration.defaults,
          ExternalStatusItemPolicy.shouldInclude(
              processIdentifier: 101,
              bundleIdentifier: "com.example.StatusApp",
              role: kAXMenuBarItemRole as String,
              frame: CGRect(x: 100, y: 2, width: 24, height: 24),
              ownProcessIdentifier: 202
          ),
          !ExternalStatusItemPolicy.shouldInclude(
              processIdentifier: 101,
              bundleIdentifier: "com.apple.controlcenter",
              role: kAXMenuBarItemRole as String,
              frame: CGRect(x: 100, y: 2, width: 24, height: 24),
              ownProcessIdentifier: 202
          ),
          ExternalStatusItemPolicy.shouldInspectApplication(
              processIdentifier: 101,
              bundleIdentifier: "com.example.StatusApp",
              ownProcessIdentifier: 202
          ),
          !ExternalStatusItemPolicy.shouldInspectApplication(
              processIdentifier: 101,
              bundleIdentifier: "com.apple.WebKit.WebContent",
              ownProcessIdentifier: 202
          ),
          !ExternalStatusItemPolicy.shouldInspectApplication(
              processIdentifier: 202,
              bundleIdentifier: "com.example.StatusApp",
              ownProcessIdentifier: 202
          ),
          trayLayout.orderedIDs == ["three", "one", "two"],
          trayLayout.hiddenIDs == ["three"],
          unifiedTrayLayout.orderedIDs == [
              "external-one",
              "external-two",
              SystemTrayItemID.inputSource.rawValue,
              SystemTrayItemID.wifi.rawValue,
              SystemTrayItemID.volume.rawValue,
              SystemTrayItemID.battery.rawValue,
          ],
          restoredTrayLayout == trayLayout,
          ExternalStatusItemIdentity.make(
              ownerIdentifier: "com.example.StatusApp",
              accessibilityIdentifier: "status-item",
              childIndex: 0
          ) == ExternalStatusItemIdentity.make(
              ownerIdentifier: "com.example.StatusApp",
              accessibilityIdentifier: "status-item",
              childIndex: 4
          ),
          ExternalStatusItemIdentity.make(
              ownerIdentifier: "com.example.StatusApp",
              accessibilityIdentifier: nil,
              childIndex: 0
          ) != ExternalStatusItemIdentity.make(
              ownerIdentifier: "com.example.StatusApp",
              accessibilityIdentifier: nil,
              childIndex: 1
          ),
          unchangedTrayImage == ExternalStatusItemImageFingerprint.make(
              width: 1,
              height: 1,
              rgbaBytes: [0, 0, 0, 255]
          ),
          unchangedTrayImage != changedTrayImage,
          [unchangedTrayPresentation] != [changedTrayPresentation],
          ExternalStatusOverflowMetrics.contentSize(itemCount: 11) == CGSize(width: 208, height: 128),
          !ExternalStatusOverflowVisibilityPolicy.shouldShowButton(hiddenItemCount: 0, isDragging: false),
          ExternalStatusOverflowVisibilityPolicy.shouldShowButton(hiddenItemCount: 1, isDragging: false),
          ExternalStatusOverflowVisibilityPolicy.shouldShowButton(hiddenItemCount: 0, isDragging: true),
          ExternalStatusItemsView.controlWidth(for: NSImage(size: NSSize(width: 18, height: 18))) == 32,
          ExternalStatusItemsView.controlWidth(for: NSImage(size: NSSize(width: 90, height: 18))) == 104,
          ExternalStatusItemsView.controlWidth(for: NSImage(size: NSSize(width: 180, height: 18))) == 134,
          ExternalStatusItemsView.controlWidth(
              for: NSImage(size: NSSize(width: 90, height: 18)),
              horizontal: false
          ) == 32,
          ClockTrayView.controlWidth(time: "14:35:55", date: "8/27/2026") < 80,
          WindowsTrayIconMetrics.clockRowHeight == 18,
          WindowsTrayIconMetrics.showDesktopVisibleThickness < WindowsTrayIconMetrics.showDesktopHitThickness,
          WindowsTrayIconMetrics.showDesktopIndicatorLength < WindowsTrayIconMetrics.controlHeight,
          WindowsTrayIconMetrics.pressedFillOpacity > WindowsTrayIconMetrics.hoverFillOpacity,
          WindowsTrayIconControl.trackingAreaOptions.contains(.inVisibleRect),
          WindowsTrayTooltipMetrics.size(for: "QQ音乐").height == 32,
          WindowsTrayTooltipMetrics.size(for: "Thursday, August 27, 2026\n\nThu 14:35:49 (Local time)").height > 32,
          preferences.menuButtonPlacement == .standard,
          preferences.windowsKeyMapping == .option,
          preferences.windowsKeyOpensStart,
          preferences.globalShortcutConfigurations.count == 43,
          preferences.customShortcutConfigurations.isEmpty,
          preferences.globalShortcutConfigurations.first(where: {
              $0.id == GlobalShortcutCatalog.fileManagerID
          })?.isEnabled == true,
          preferences.globalShortcutConfigurations.first(where: {
              $0.id == GlobalShortcutCatalog.quickLinkMenuID
          })?.action == .toggleQuickLinkMenu,
          preferences.globalShortcutConfigurations.first(where: {
              $0.id == GlobalShortcutCatalog.quickLinkMenuID
          })?.isEnabled == true,
          preferences.globalShortcutConfigurations.first(where: {
              $0.id == GlobalShortcutCatalog.showDesktopID
          })?.usesWindowsKey == true,
          preferences.globalShortcutConfigurations.first(where: {
              $0.id == GlobalShortcutCatalog.runID
          })?.action == .showRunDialog,
          preferences.globalShortcutConfigurations.first(where: {
              $0.id == GlobalShortcutCatalog.snapLayoutsID
          })?.isEnabled == true,
          Set(preferences.globalShortcutConfigurations.map(\.id)).count == 43,
          GlobalHotkeysService.duplicateIssues(
              configurations: preferences.globalShortcutConfigurations,
              mapping: preferences.windowsKeyMapping
          ).isEmpty,
          Set(GlobalShortcutAction.allCases).subtracting(
              preferences.globalShortcutConfigurations.map(\.action)
          ) == [.openApplication] else {
        fputs("SELF-TEST FAILED: default values mismatch\n", stderr)
        return 1
    }
    guard let fileManagerShortcut = preferences.globalShortcutConfigurations.first(where: {
        $0.id == GlobalShortcutCatalog.fileManagerID
    }),
    fileManagerShortcut.displayValue(mapping: .option) == "⌥E",
    fileManagerShortcut.resolvedShortcut(mapping: .option).modifiers == UInt32(optionKey),
    fileManagerShortcut.resolvedShortcut(mapping: .command).modifiers == UInt32(cmdKey) else {
        fputs("SELF-TEST FAILED: Windows shortcut mapping mismatch\n", stderr)
        return 1
    }
    var duplicateShortcuts = preferences.globalShortcutConfigurations
    duplicateShortcuts[1].shortcut = duplicateShortcuts[0].shortcut
    duplicateShortcuts[1].usesWindowsKey = duplicateShortcuts[0].usesWindowsKey
    let duplicateIssues = GlobalHotkeysService.duplicateIssues(
        configurations: duplicateShortcuts,
        mapping: preferences.windowsKeyMapping
    )
    guard duplicateIssues[duplicateShortcuts[0].id]?.contains(duplicateShortcuts[1].title) == true,
          duplicateIssues[duplicateShortcuts[1].id]?.contains(duplicateShortcuts[0].title) == true else {
        fputs("SELF-TEST FAILED: duplicate global shortcut was not detected\n", stderr)
        return 1
    }
    var customShortcut = CustomShortcutConfiguration.makeNew()
    guard customShortcut.registrationConfiguration() == nil else {
        fputs("SELF-TEST FAILED: incomplete custom shortcut was registered\n", stderr)
        return 1
    }
    customShortcut.shortcut = HotkeyShortcut(
        keyCode: 0,
        modifiers: UInt32(controlKey | optionKey),
        keyLabel: "A"
    )
    customShortcut.action = .openApplication
    guard let customRegistration = customShortcut.registrationConfiguration(),
          customRegistration.validationIssue == "Choose an application" else {
        fputs("SELF-TEST FAILED: custom shortcut extra validation mismatch\n", stderr)
        return 1
    }
    customShortcut.shortcut = fileManagerShortcut.resolvedShortcut(mapping: .option)
    guard let conflictingCustomRegistration = customShortcut.registrationConfiguration() else {
        fputs("SELF-TEST FAILED: custom shortcut registration conversion mismatch\n", stderr)
        return 1
    }
    let customConflictIssues = GlobalHotkeysService.duplicateIssues(
        configurations: preferences.globalShortcutConfigurations + [conflictingCustomRegistration],
        mapping: .option
    )
    guard customConflictIssues[fileManagerShortcut.id]?.contains(conflictingCustomRegistration.title) == true,
          customConflictIssues[customShortcut.id]?.contains(fileManagerShortcut.title) == true else {
        fputs("SELF-TEST FAILED: custom shortcut conflict was not reported on both bindings\n", stderr)
        return 1
    }

    guard !PowerAction.lockScreen.requiresConfirmation,
          PowerAction.sleep.requiresConfirmation,
          PowerAction.logOut.requiresConfirmation,
          PowerAction.restart.requiresConfirmation,
          PowerAction.shutDown.requiresConfirmation else {
        fputs("SELF-TEST FAILED: power confirmation policy mismatch\n", stderr)
        return 1
    }

    let placementArea = CGRect(x: 10, y: 20, width: 1000, height: 700)
    guard WindowPlacementGeometry.frame(for: .leftHalf, in: placementArea)
            == CGRect(x: 10, y: 20, width: 500, height: 700),
          WindowPlacementGeometry.frame(for: .topRight, in: placementArea)
            == CGRect(x: 510, y: 370, width: 500, height: 350),
          ClipboardHistoryService.recording(" second ", in: ["first", "second"])
            == ["second", "first"],
          ClipboardHistoryService.recording("", in: ["first"]) == ["first"] else {
        fputs("SELF-TEST FAILED: Windows shortcut service policy mismatch\n", stderr)
        return 1
    }

    guard InputSourcePresentation.abbreviation(languageCode: "en-US", fallbackName: "ABC") == "ENG",
          InputSourcePresentation.abbreviation(languageCode: "zh-Hans", fallbackName: "Pinyin") == "中",
          InputSourcePresentation.abbreviation(languageCode: nil, fallbackName: "ABC") == "ABC",
          InputSourceTrayPresentation.fontSize(for: "ENG") == 12,
          InputSourceTrayPresentation.fontSize(for: "中") == 15,
          InputSourceCycling.nextID(sourceIDs: [], currentID: "missing") == nil,
          InputSourceCycling.nextID(sourceIDs: ["abc", "pinyin"], currentID: "missing") == "abc",
          InputSourceCycling.nextID(sourceIDs: ["abc", "pinyin"], currentID: "abc") == "pinyin",
          InputSourceCycling.nextID(sourceIDs: ["abc", "pinyin"], currentID: "pinyin") == "abc",
          InputSourceCycling.previousID(sourceIDs: [], currentID: "missing") == nil,
          InputSourceCycling.previousID(sourceIDs: ["abc", "pinyin"], currentID: "missing") == "pinyin",
          InputSourceCycling.previousID(sourceIDs: ["abc", "pinyin"], currentID: "abc") == "pinyin",
          InputSourceCycling.previousID(sourceIDs: ["abc", "pinyin"], currentID: "pinyin") == "abc",
          InputSourcePanelMetrics.contentSize(inputSourceCount: 2) == CGSize(width: 360, height: 215),
          InputSourcePanelMetrics.contentSize(inputSourceCount: 8)
            == InputSourcePanelMetrics.contentSize(inputSourceCount: 5),
          InputSourcePanelGeometry.frame(
              screenFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
              visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 775),
              position: .bottom,
              barHeight: 48,
              contentSize: CGSize(width: 360, height: 215)
          ) == CGRect(x: 828, y: 56, width: 360, height: 215),
          InputSourcePanelGeometry.frame(
              screenFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
              visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 775),
              position: .top,
              barHeight: 48,
              contentSize: CGSize(width: 360, height: 215)
          ) == CGRect(x: 828, y: 504, width: 360, height: 215),
          InputSourcePanelGeometry.frame(
              screenFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
              visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 775),
              position: .left,
              barHeight: 48,
              contentSize: CGSize(width: 360, height: 215)
          ) == CGRect(x: 56, y: 12, width: 360, height: 215),
          InputSourcePanelGeometry.frame(
              screenFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
              visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 775),
              position: .right,
              barHeight: 48,
              contentSize: CGSize(width: 360, height: 215)
          ) == CGRect(x: 784, y: 12, width: 360, height: 215) else {
        fputs("SELF-TEST FAILED: input source presentation mismatch\n", stderr)
        return 1
    }

    let clockReferenceDate = Date(timeIntervalSince1970: 1_787_835_075)
    let clockReferenceTimeZone = TimeZone(secondsFromGMT: 0)!
    guard ClockTrayPresentation.time(
        clockReferenceDate,
        showsSeconds: true,
        configuration: preferences.dateTimeFormatConfiguration,
        timeZone: clockReferenceTimeZone
    ) == "12:51:15",
    ClockTrayPresentation.time(
        clockReferenceDate,
        showsSeconds: false,
        configuration: preferences.dateTimeFormatConfiguration,
        timeZone: clockReferenceTimeZone
    ) == "12:51",
    ClockTrayPresentation.date(
        clockReferenceDate,
        configuration: preferences.dateTimeFormatConfiguration,
        timeZone: clockReferenceTimeZone
    ) == "8/27/2026",
    AdditionalClockPresentation.relativeDay(
        for: Date(timeIntervalSince1970: 3_600),
        targetTimeZone: TimeZone(secondsFromGMT: -21_600)!,
        localTimeZone: clockReferenceTimeZone
    ) == .yesterday else {
        fputs("SELF-TEST FAILED: Windows tray clock presentation mismatch\n", stderr)
        return 1
    }

    var dateFormatReferenceComponents = DateComponents()
    dateFormatReferenceComponents.calendar = Calendar(identifier: .gregorian)
    dateFormatReferenceComponents.timeZone = clockReferenceTimeZone
    dateFormatReferenceComponents.year = 2026
    dateFormatReferenceComponents.month = 7
    dateFormatReferenceComponents.day = 1
    let dateFormatReferenceDate = dateFormatReferenceComponents.date!
    let lunarDateConfiguration = DateTimeFormatConfiguration(
        calendarKind: .gregorian,
        firstDayOfWeek: .sunday,
        shortDatePattern: "yyyy/M/d",
        longDatePattern: "yyyy年M月d日",
        longDateIncludesLunar: true,
        shortTimePattern: "HH:mm",
        longTimePattern: "HH:mm:ss",
        amSymbol: "AM",
        pmSymbol: "PM"
    )
    let lunarDateExample = DateTimeFormatter.longDateString(
        from: dateFormatReferenceDate,
        configuration: lunarDateConfiguration,
        timeZone: clockReferenceTimeZone
    )
    guard DateTimeFormatCatalog.shortDatePatterns.contains("yyyy/M/d"),
          DateTimeFormatCatalog.shortDatePatterns.contains("yyyy/MM/dd"),
          DateTimeFormatter.string(
              from: dateFormatReferenceDate,
              pattern: "yyyy/M/d",
              configuration: preferences.dateTimeFormatConfiguration,
              timeZone: clockReferenceTimeZone
          ) == "2026/7/1",
          DateTimeFormatter.string(
              from: dateFormatReferenceDate,
              pattern: "yyyy/MM/dd",
              configuration: preferences.dateTimeFormatConfiguration,
              timeZone: clockReferenceTimeZone
          ) == "2026/07/01",
          DateTimeFormatter.string(
              from: dateFormatReferenceDate,
              pattern: "yyyy年M月d日",
              configuration: preferences.dateTimeFormatConfiguration,
              timeZone: clockReferenceTimeZone
          ) == "2026年7月1日",
          DateTimeFormatter.string(
              from: dateFormatReferenceDate,
              pattern: "yyyy年MM月dd日",
              configuration: preferences.dateTimeFormatConfiguration,
              timeZone: clockReferenceTimeZone
          ) == "2026年07月01日",
          lunarDateExample.hasPrefix("2026年7月1日"),
          lunarDateExample.contains("农历") else {
        fputs("SELF-TEST FAILED: date format catalog mismatch\n", stderr)
        return 1
    }

    guard BatteryPresentationState.resolve(level: 82, isCharging: false, isLowPowerModeEnabled: false) == .normal,
          BatteryPresentationState.resolve(level: 82, isCharging: true, isLowPowerModeEnabled: false) == .charging,
          BatteryPresentationState.resolve(level: 20, isCharging: false, isLowPowerModeEnabled: false) == .saver,
          BatteryPresentationState.resolve(level: 82, isCharging: false, isLowPowerModeEnabled: true) == .saver,
          BatteryPresentationState.resolve(level: 6, isCharging: false, isLowPowerModeEnabled: false) == .critical,
          VolumeAdjustmentPolicy.shouldUnmute(targetVolume: 0.5),
          VolumeAdjustmentPolicy.shouldUnmute(targetVolume: 1),
          !VolumeAdjustmentPolicy.shouldUnmute(targetVolume: 0),
          !VolumeAdjustmentPolicy.shouldUnmute(targetVolume: -0.1),
          QuickSettingsPanelMetrics.contentSize == CGSize(width: 360, height: 335),
          QuickSettingsPanelMetrics.settingsGridHeight == 213,
          QuickSettingsPanelMetrics.settingsPageCount == 2,
          QuickSettingsPanelMetrics.tileSize == CGSize(width: 96, height: 47),
          QuickSettingsPanelMetrics.splitSegmentWidth == 47.5,
          QuickSettingsPanelMetrics.splitDividerOpacity == 0.08,
          QuickSettingsPanelMetrics.volumeHeight == 72,
          QuickSettingsPanelMetrics.footerHeight == 48,
          QuickSettingsPanelMetrics.footerLeadingPadding == 24,
          QuickSettingsPanelMetrics.footerTrailingPadding == 16,
          QuickSettingsPanelMetrics.detailHeaderHeight == 52,
          QuickSettingsPanelMetrics.detailContentHeight == 233,
          QuickSettingsPanelMetrics.detailBackButtonSize == 40,
          QuickSettingsPanelMetrics.detailBackButtonCornerRadius == 4,
          QuickSettingsPanelMetrics.accessibilityRowHeight == 55,
          QuickSettingsPanelMetrics.accessibilityIconColumnWidth == 22,
          QuickSettingsPanelMetrics.accessibilityStatusColumnWidth == 24,
          QuickSettingsPanelMetrics.accessibilityToggleSize == CGSize(width: 40, height: 20),
          QuickSettingsPanelOpeningPolicy.shouldPresent(isVisible: false),
          !QuickSettingsPanelOpeningPolicy.shouldPresent(isVisible: true),
          WindowsVolumeSliderMetrics.trackHeight == 4,
          WindowsVolumeSliderMetrics.thumbDiameter == 20,
          WindowsVolumeSliderMetrics.normalIndicatorDiameter == 10,
          WindowsVolumeSliderMetrics.pressedIndicatorDiameter == 8,
          WindowsVolumeSliderGeometry.thumbCenter(value: 0, width: 200) == 10,
          WindowsVolumeSliderGeometry.thumbCenter(value: 0.5, width: 200) == 100,
          WindowsVolumeSliderGeometry.thumbCenter(value: 1, width: 200) == 190,
          WindowsVolumeSliderGeometry.value(at: 0, width: 200) == 0,
          WindowsVolumeSliderGeometry.value(at: 100, width: 200) == 0.5,
          WindowsVolumeSliderGeometry.value(at: 200, width: 200) == 1,
          QuickSettingsPageNavigation.targetPage(currentPage: 0, deltaY: -1, pageCount: 2) == 1,
          QuickSettingsPageNavigation.targetPage(currentPage: 1, deltaY: -1, pageCount: 2) == 1,
          QuickSettingsPageNavigation.targetPage(currentPage: 1, deltaY: 1, pageCount: 2) == 0,
          QuickSettingsPageNavigation.targetPage(currentPage: 0, deltaY: 1, pageCount: 2) == 0,
          WiFiScanIssue.locationAuthorizationRequired != .locationPermissionDenied,
          WiFiScanIssue.locationPermissionDenied != .scanFailed,
          QuickSettingsPanelGeometry.frame(
              screenFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
              visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 775),
              position: .bottom,
              barHeight: 48
          ) == CGRect(x: 828, y: 56, width: 360, height: 335),
          QuickSettingsPanelGeometry.frame(
              screenFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
              visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 775),
              position: .top,
              barHeight: 48
          ) == CGRect(x: 828, y: 384, width: 360, height: 335),
          QuickSettingsPanelGeometry.frame(
              screenFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
              visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 775),
              position: .left,
              barHeight: 48
          ) == CGRect(x: 56, y: 12, width: 360, height: 335),
          QuickSettingsPanelGeometry.frame(
              screenFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
              visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 775),
              position: .right,
              barHeight: 48
          ) == CGRect(x: 784, y: 12, width: 360, height: 335) else {
        fputs("SELF-TEST FAILED: quick settings presentation mismatch\n", stderr)
        return 1
    }

    guard DockExitPolicy.shouldRestoreDock(configuration: DockConfiguration(
        autohide: true,
        autohideDelay: 1000,
        autohideTimeModifier: 0
    )),
    !DockExitPolicy.shouldRestoreDock(configuration: DockConfiguration(
        autohide: false,
        autohideDelay: 1000,
        autohideTimeModifier: 0
    )),
    !DockExitPolicy.shouldRestoreDock(configuration: DockConfiguration(
        autohide: true,
        autohideDelay: nil,
        autohideTimeModifier: nil
    )) else {
        fputs("SELF-TEST FAILED: Dock exit policy mismatch\n", stderr)
        return 1
    }

    defaults.set(true, forKey: "wintaskbar.dockHidden")
    guard DockToggleService(defaults: defaults).isDockHidden else {
        fputs("SELF-TEST FAILED: Dock launch preference was not restored\n", stderr)
        return 1
    }
    defaults.set(false, forKey: "wintaskbar.dockHidden")
    guard !DockToggleService(defaults: defaults).isDockHidden else {
        fputs("SELF-TEST FAILED: disabled Dock launch preference was ignored\n", stderr)
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
    guard rightMenuFrame == NSRect(x: 740, y: 308, width: 400, height: 480) else {
        fputs("SELF-TEST FAILED: start menu corner anchoring mismatch\n", stderr)
        return 1
    }

    let bottomMenuFrame = StartMenuGeometry.frame(
        screenFrame: NSRect(x: 0, y: 0, width: 1200, height: 800),
        visibleFrame: NSRect(x: 0, y: 0, width: 1200, height: 775),
        position: .bottom,
        barHeight: 52,
        heightMode: .standard,
        oppositeEnd: false
    )
    let bottomContextFrame = StartMenuGeometry.anchoredFrame(
        screenFrame: NSRect(x: 0, y: 0, width: 1200, height: 800),
        visibleFrame: NSRect(x: 0, y: 0, width: 1200, height: 775),
        position: .bottom,
        barHeight: 52,
        contentSize: StartButtonContextMenuMetrics.rootSize,
        oppositeEnd: false
    )
    guard bottomMenuFrame.origin == CGPoint(x: 12, y: 60),
          bottomContextFrame.origin == bottomMenuFrame.origin,
          StartButtonPowerMenuGeometry.frame(
              parentFrame: bottomContextFrame,
              contentSize: StartButtonContextMenuMetrics.powerSize,
              screenFrame: NSRect(x: 0, y: 0, width: 1200, height: 800)
          ).origin == CGPoint(x: 260, y: 60) else {
        fputs("SELF-TEST FAILED: start surface spacing mismatch\n", stderr)
        return 1
    }

    guard StartMenuMotion.dismissedFrame(from: bottomMenuFrame, position: .bottom).origin
        == CGPoint(x: 12, y: 44),
        StartMenuMotion.dismissedFrame(from: bottomMenuFrame, position: .top).origin
        == CGPoint(x: 12, y: 76),
        StartMenuMotion.dismissedFrame(from: bottomMenuFrame, position: .left).origin
        == CGPoint(x: -4, y: 60),
        StartMenuMotion.dismissedFrame(from: bottomMenuFrame, position: .right).origin
        == CGPoint(x: 28, y: 60),
        StartMenuMotion.entranceDuration == 0.25,
        StartMenuMotion.exitDuration == 0.167,
        StartMenuMotion.fadeDuration == 0.083 else {
        fputs("SELF-TEST FAILED: start menu motion mismatch\n", stderr)
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
    WindowFittingGeometry.freeRect(
        on: fittingScreen,
        position: .bottom,
        barHeight: 0
    ) == fittingScreen.visibleFrame,
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

    let shownBottomTaskbar = CGRect(x: 0, y: 0, width: 1200, height: 48)
    let shownTopTaskbar = CGRect(x: 0, y: 727, width: 1200, height: 48)
    let shownLeftTaskbar = CGRect(x: 0, y: 0, width: 48, height: 800)
    let shownRightTaskbar = CGRect(x: 1152, y: 0, width: 48, height: 800)
    guard TaskbarAutoHideGeometry.hiddenFrame(
        from: shownBottomTaskbar,
        position: .bottom
    ) == CGRect(x: 0, y: -48, width: 1200, height: 48),
    TaskbarAutoHideGeometry.hiddenFrame(
        from: shownTopTaskbar,
        position: .top
    ) == CGRect(x: 0, y: 775, width: 1200, height: 48),
    TaskbarAutoHideGeometry.hiddenFrame(
        from: shownLeftTaskbar,
        position: .left
    ) == CGRect(x: -48, y: 0, width: 48, height: 800),
    TaskbarAutoHideGeometry.hiddenFrame(
        from: shownRightTaskbar,
        position: .right
    ) == CGRect(x: 1200, y: 0, width: 48, height: 800),
    TaskbarAutoHideGeometry.revealZone(
        screenFrame: fittingScreen.frame,
        visibleFrame: fittingScreen.visibleFrame,
        position: .bottom
    ) == CGRect(x: 0, y: 0, width: 1200, height: 2),
    TaskbarAutoHideGeometry.revealZone(
        screenFrame: fittingScreen.frame,
        visibleFrame: fittingScreen.visibleFrame,
        position: .top
    ) == CGRect(x: 0, y: 773, width: 1200, height: 2),
    TaskbarAutoHideGeometry.revealZone(
        screenFrame: fittingScreen.frame,
        visibleFrame: fittingScreen.visibleFrame,
        position: .left
    ) == CGRect(x: 0, y: 0, width: 2, height: 800),
    TaskbarAutoHideGeometry.revealZone(
        screenFrame: fittingScreen.frame,
        visibleFrame: fittingScreen.visibleFrame,
        position: .right
    ) == CGRect(x: 1198, y: 0, width: 2, height: 800),
    TaskbarAutoHidePolicy.shouldHide(
        isEnabled: true,
        pointerIsInsideTaskbar: false,
        hasVisibleSurface: false,
        hasPendingAttention: false,
        isMouseButtonPressed: false
    ),
    !TaskbarAutoHidePolicy.shouldHide(
        isEnabled: true,
        pointerIsInsideTaskbar: true,
        hasVisibleSurface: false,
        hasPendingAttention: false,
        isMouseButtonPressed: false
    ),
    !TaskbarAutoHidePolicy.shouldHide(
        isEnabled: true,
        pointerIsInsideTaskbar: false,
        hasVisibleSurface: true,
        hasPendingAttention: false,
        isMouseButtonPressed: false
    ),
    !TaskbarAutoHidePolicy.shouldHide(
        isEnabled: true,
        pointerIsInsideTaskbar: false,
        hasVisibleSurface: false,
        hasPendingAttention: true,
        isMouseButtonPressed: false
    ),
    !TaskbarAutoHidePolicy.shouldHide(
        isEnabled: true,
        pointerIsInsideTaskbar: false,
        hasVisibleSurface: false,
        hasPendingAttention: false,
        isMouseButtonPressed: true
    ) else {
        fputs("SELF-TEST FAILED: taskbar auto-hide geometry or policy mismatch\n", stderr)
        return 1
    }

    let previewScreen = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let previewSize = CGSize(width: 340, height: 130)
    let firstPreviewOwner = WindowPreviewOwnerID(displayID: 1, bundleIdentifier: "com.example.first")
    let secondPreviewOwner = WindowPreviewOwnerID(displayID: 1, bundleIdentifier: "com.example.second")
    let immediatePreviewController = WindowPreviewPanelController()
    immediatePreviewController.pin(ownerID: firstPreviewOwner)
    immediatePreviewController.activate(ownerID: secondPreviewOwner)
    var pinnedPreviewDismissed = false
    immediatePreviewController.scheduleDismissal(ownerID: firstPreviewOwner) {
        pinnedPreviewDismissed = true
    }
    guard immediatePreviewController.activeOwnerID == firstPreviewOwner,
          immediatePreviewController.isPinned,
          !pinnedPreviewDismissed else {
        fputs("SELF-TEST FAILED: pinned window preview activation mismatch\n", stderr)
        return 1
    }
    immediatePreviewController.pin(ownerID: secondPreviewOwner)
    guard immediatePreviewController.activeOwnerID == secondPreviewOwner,
          immediatePreviewController.isPinned else {
        fputs("SELF-TEST FAILED: pinned window preview replacement mismatch\n", stderr)
        return 1
    }
    immediatePreviewController.dismissAll()
    guard immediatePreviewController.activeOwnerID == nil,
          !immediatePreviewController.isPinned else {
        fputs("SELF-TEST FAILED: pinned window preview dismissal mismatch\n", stderr)
        return 1
    }
    let landscapePreviewWindow = WindowInfo(
        windowID: 1,
        title: "Landscape",
        ownerPID: 1,
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        isMinimized: false
    )
    let portraitPreviewWindow = WindowInfo(
        windowID: 2,
        title: "Portrait",
        ownerPID: 1,
        frame: CGRect(x: 0, y: 0, width: 1080, height: 1920),
        isMinimized: false
    )
    let minimizedPreviewWindow = WindowInfo(
        windowID: 3,
        title: "Minimized",
        ownerPID: 1,
        frame: CGRect(x: 100, y: 100, width: 900, height: 600),
        isMinimized: true
    )
    let jumpListScreen = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let jumpListSize = TaskbarJumpListMetrics.contentSize(
        shortcutCount: 0,
        recentCount: 0,
        isRunning: false
    )
    let jumpListShortcuts = (0..<9).map {
        PinnedShortcut(id: "shortcut-\($0)", name: "Shortcut \($0)", target: "/tmp/shortcut-\($0)")
    }
    let jumpListRecent = (0..<7).map {
        RecentDocument(
            url: URL(fileURLWithPath: "/tmp/recent-\($0)", isDirectory: true),
            label: "Recent \($0)"
        )
    }
    let jumpListModel = TaskbarJumpListModel(
        shortcuts: jumpListShortcuts,
        recentDocuments: jumpListRecent,
        isPinned: true,
        windowCount: 2
    )
    let recentHistory = RecentDocumentsHistory.recording(
        bundleID: "test.app",
        folder: "file:///tmp/new/",
        in: ["test.app": ["file:///tmp/old/", "file:///tmp/new/"]],
        limit: 10
    )
    defaults.set(["test.app": ["file:///tmp/project/"]], forKey: "winbar.recentProjects")
    let recentDocuments = RecentDocumentsService(defaults: defaults)
    var taskbarItemOrder = TaskbarItemOrder()
    let initialTaskbarOrder = taskbarItemOrder.reconcile(
        pinnedBundleIDs: ["finder"],
        runningBundleIDs: ["finder", "safari", "terminal"]
    )
    let pinnedInPlaceTaskbarOrder = taskbarItemOrder.reconcile(
        pinnedBundleIDs: ["finder", "terminal"],
        runningBundleIDs: ["finder", "safari", "terminal"]
    )
    let unpinnedExitTaskbarOrder = taskbarItemOrder.reconcile(
        pinnedBundleIDs: ["finder", "terminal"],
        runningBundleIDs: ["finder", "terminal"]
    )
    let pinnedExitTaskbarOrder = taskbarItemOrder.reconcile(
        pinnedBundleIDs: ["finder", "terminal"],
        runningBundleIDs: ["finder"]
    )
    let movedTaskbarItem = taskbarItemOrder.move("terminal", relativeTo: "finder", after: false)
    let liveReorderedTaskbarOrder = taskbarItemOrder.bundleIDs
    var previewSelection = WindowPreviewSelection()
    previewSelection.activate(firstPreviewOwner)
    previewSelection.activate(secondPreviewOwner)
    let staleDismissalChangedSelection = previewSelection.dismiss(firstPreviewOwner)
    var previewUpdateSequence = WindowPreviewPanelUpdateSequence()
    let stalePreviewUpdate = previewUpdateSequence.schedule()
    let currentPreviewUpdate = previewUpdateSequence.schedule()
    guard WindowPreviewLayout.axis(for: .top) == .horizontal,
          WindowPreviewLayout.axis(for: .bottom) == .horizontal,
          WindowPreviewLayout.axis(for: .left) == .vertical,
          WindowPreviewLayout.axis(for: .right) == .vertical,
          !staleDismissalChangedSelection,
          previewSelection.activeOwnerID == secondPreviewOwner,
          previewSelection.dismiss(secondPreviewOwner),
          previewSelection.activeOwnerID == nil,
          WindowPreviewPanelTransitionPolicy.shouldAnimate(
              isVisible: true,
              displayedOwnerID: firstPreviewOwner,
              targetOwnerID: secondPreviewOwner
          ),
          !WindowPreviewPanelTransitionPolicy.shouldAnimate(
              isVisible: true,
              displayedOwnerID: secondPreviewOwner,
              targetOwnerID: secondPreviewOwner
          ),
          !WindowPreviewPanelTransitionPolicy.shouldAnimate(
              isVisible: false,
              displayedOwnerID: firstPreviewOwner,
              targetOwnerID: secondPreviewOwner
          ),
          !previewUpdateSequence.isCurrent(stalePreviewUpdate),
          previewUpdateSequence.isCurrent(currentPreviewUpdate),
          WindowPreviewHostingPolicy.sizingOptions.isEmpty,
          WindowPreviewPanelMotion.duration == 0.28,
          WindowPreviewPanelMotion.firstControlPoint == CGPoint(x: 0.8, y: 0),
          WindowPreviewPanelMotion.secondControlPoint == CGPoint(x: 0.2, y: 1),
          TaskbarButtonMotion.pressedScale == 0.82,
          TaskbarButtonMotion.pressDuration == 0.06,
          TaskbarButtonMotion.releaseDuration == 0.08,
          jumpListSize == CGSize(width: 292, height: 195),
          TaskbarJumpListMetrics.contentSize(shortcutCount: 0, recentCount: 0, isRunning: true)
              == CGSize(width: 292, height: 238),
          TaskbarJumpListMetrics.contentSize(shortcutCount: 1, recentCount: 0, isRunning: false)
              == CGSize(width: 292, height: 260),
          TaskbarJumpListMetrics.contentSize(shortcutCount: 9, recentCount: 0, isRunning: false)
              == CGSize(width: 292, height: 498),
          TaskbarJumpListMetrics.contentSize(shortcutCount: 9, recentCount: 7, isRunning: false)
              == CGSize(width: 292, height: 733),
          jumpListModel.displayedShortcuts.count == 8,
          jumpListModel.displayedRecentDocuments.count == 6,
          jumpListModel.closeTitle == "Close all windows",
          jumpListModel.canClose,
          TaskbarJumpListModel(shortcuts: [], recentDocuments: [], isPinned: false, windowCount: 0).closeTitle == "Close",
          !TaskbarJumpListModel(shortcuts: [], recentDocuments: [], isPinned: false, windowCount: 0).canClose,
          TaskbarJumpListModel(shortcuts: [], recentDocuments: [], isPinned: false, windowCount: 1).closeTitle == "Close window",
          recentHistory["test.app"] == ["file:///tmp/new/", "file:///tmp/old/"],
          recentDocuments.recentDocuments(forBundleID: "test.app").map(\.label) == ["project"],
          initialTaskbarOrder == ["finder", "safari", "terminal"],
          pinnedInPlaceTaskbarOrder == ["finder", "safari", "terminal"],
          unpinnedExitTaskbarOrder == ["finder", "terminal"],
          pinnedExitTaskbarOrder == ["finder", "terminal"],
          movedTaskbarItem,
          liveReorderedTaskbarOrder == ["terminal", "finder"],
          TaskbarDragMotion.duration == 0.167,
          TaskbarDragMotion.reorderFirstControlPoint == CGPoint(x: 0.55, y: 0.55),
          TaskbarDragMotion.reorderSecondControlPoint == CGPoint(x: 0, y: 1),
          TaskbarDragReorderPolicy.iconCenter(
              pointerLocation: CGPoint(x: 100, y: 20),
              grabOffset: CGSize(width: 12, height: -4),
              horizontal: true,
              fixedCrossAxisPosition: 24
          ) == CGPoint(x: 112, y: 24),
          TaskbarDragReorderPolicy.iconCenter(
              pointerLocation: CGPoint(x: 100, y: 20),
              grabOffset: CGSize(width: 12, height: -4),
              horizontal: false,
              fixedCrossAxisPosition: 36
          ) == CGPoint(x: 36, y: 16),
          RecentDocumentsService.documentURL(from: "file:///tmp/project/")
              == URL(string: "file:///tmp/project/"),
          RecentDocumentsService.documentURL(from: "https://example.com/project/")?.isFileURL == true,
          TaskbarJumpListGeometry.frame(
              anchorFrame: CGRect(x: 500, y: 0, width: 40, height: 48),
              contentSize: jumpListSize,
              position: .bottom,
              screenFrame: jumpListScreen
          ) == CGRect(x: 374, y: 56, width: 292, height: 195),
          TaskbarJumpListGeometry.frame(
              anchorFrame: CGRect(x: 500, y: 752, width: 40, height: 48),
              contentSize: jumpListSize,
              position: .top,
              screenFrame: jumpListScreen
          ) == CGRect(x: 374, y: 549, width: 292, height: 195),
          TaskbarJumpListGeometry.frame(
              anchorFrame: CGRect(x: 0, y: 300, width: 48, height: 40),
              contentSize: jumpListSize,
              position: .left,
              screenFrame: jumpListScreen
          ) == CGRect(x: 56, y: 222.5, width: 292, height: 195),
          TaskbarJumpListGeometry.frame(
              anchorFrame: CGRect(x: 1152, y: 300, width: 48, height: 40),
              contentSize: jumpListSize,
              position: .right,
              screenFrame: jumpListScreen
          ) == CGRect(x: 852, y: 222.5, width: 292, height: 195),
          TaskbarJumpListGeometry.frame(
              anchorFrame: CGRect(x: 0, y: 0, width: 40, height: 48),
              contentSize: jumpListSize,
              position: .bottom,
              screenFrame: jumpListScreen
          ).minX == 8,
          TaskbarContextMenuMetrics.rootSize == CGSize(width: 164, height: 268),
          TaskbarContextMenuMetrics.rootRowCount
              == CGFloat(TaskbarContextMenuSection.allCases.count + 4),
          TaskbarContextMenuSection.allCases.map(\.title) == [
              "Terminal", "Go To", "Apps", "Windows"
          ],
          TaskbarContextMenuSection.goTo.submenuTitles(terminals: []) == [
              "Folder", "Go to Folder…", "Connect to Server…", "Run…", "Settings"
          ],
          TaskbarContextMenuSection.windows.submenuDividerCount == 1,
          TaskbarContextNestedSection.folders.titles.count == 15,
          TaskbarContextNestedSection.folders.dividerCount == 2,
          TaskbarContextNestedSection.settings.titles.count == 8,
          TaskbarContextMenuGeometry.rootFrame(
              clickPoint: CGPoint(x: 700, y: 24),
              taskbarFrame: CGRect(x: 0, y: 0, width: 1200, height: 48),
              contentSize: TaskbarContextMenuMetrics.rootSize,
              position: .bottom,
              screenFrame: jumpListScreen
          ) == CGRect(x: 618, y: 56, width: 164, height: 268),
          TaskbarContextMenuGeometry.rootFrame(
              clickPoint: CGPoint(x: 700, y: 776),
              taskbarFrame: CGRect(x: 0, y: 752, width: 1200, height: 48),
              contentSize: TaskbarContextMenuMetrics.rootSize,
              position: .top,
              screenFrame: jumpListScreen
          ) == CGRect(x: 618, y: 476, width: 164, height: 268),
          TaskbarContextMenuGeometry.rootFrame(
              clickPoint: CGPoint(x: 24, y: 400),
              taskbarFrame: CGRect(x: 0, y: 0, width: 48, height: 800),
              contentSize: TaskbarContextMenuMetrics.rootSize,
              position: .left,
              screenFrame: jumpListScreen
          ) == CGRect(x: 56, y: 266, width: 164, height: 268),
          TaskbarContextMenuGeometry.rootFrame(
              clickPoint: CGPoint(x: 1176, y: 400),
              taskbarFrame: CGRect(x: 1152, y: 0, width: 48, height: 800),
              contentSize: TaskbarContextMenuMetrics.rootSize,
              position: .right,
              screenFrame: jumpListScreen
          ) == CGRect(x: 980, y: 266, width: 164, height: 268),
          TaskbarContextMenuGeometry.submenuFrame(
              parentFrame: CGRect(x: 618, y: 56, width: 164, height: 268),
              rowIndex: 0,
              contentSize: TaskbarContextMenuMetrics.submenuSize(titles: ["Terminal", "Console"]),
              screenFrame: jumpListScreen
          ) == CGRect(x: 787, y: 269, width: 164, height: 70),
          TaskbarContextMenuGeometry.submenuFrame(
              parentFrame: CGRect(x: 1028, y: 56, width: 164, height: 268),
              rowIndex: 0,
              contentSize: TaskbarContextMenuMetrics.submenuSize(titles: ["Terminal", "Console"]),
              screenFrame: jumpListScreen
          ) == CGRect(x: 859, y: 269, width: 164, height: 70),
          TaskbarContextMenuMetrics.submenuSize(
              titles: ["Connect to Server…"],
              hasTrailingChevron: true
          ).width > 164,
          TaskbarContextMenuMetrics.submenuSize(
              titles: [String(repeating: "W", count: 80)]
          ).width == 220,
          TaskbarSubmenuPointerIntent.isMovingTowardSubmenu(
              previous: CGPoint(x: 740, y: 250),
              current: CGPoint(x: 760, y: 245),
              submenuFrame: CGRect(x: 787, y: 150, width: 180, height: 300)
          ),
          !TaskbarSubmenuPointerIntent.isMovingTowardSubmenu(
              previous: CGPoint(x: 760, y: 245),
              current: CGPoint(x: 740, y: 240),
              submenuFrame: CGRect(x: 787, y: 150, width: 180, height: 300)
          ),
          WindowArrangementGeometry.frames(
              for: .sideBySide,
              count: 2,
              in: CGRect(x: 0, y: 48, width: 1200, height: 752)
          ) == [
              CGRect(x: 0, y: 48, width: 600, height: 752),
              CGRect(x: 600, y: 48, width: 600, height: 752),
          ],
          WindowArrangementGeometry.frames(
              for: .stacked,
              count: 2,
              in: CGRect(x: 0, y: 48, width: 1200, height: 752)
          ) == [
              CGRect(x: 0, y: 424, width: 1200, height: 376),
              CGRect(x: 0, y: 48, width: 1200, height: 376),
          ],
          TaskbarJumpListInteractionPolicy.shouldDismissMenuOnAppHover(hovering: true),
          !TaskbarJumpListInteractionPolicy.shouldDismissMenuOnAppHover(hovering: false),
          ShortcutEditorMetrics.contentSize(shortcutCount: 0) == CGSize(width: 540, height: 206),
          ShortcutEditorMetrics.contentSize(shortcutCount: 1) == CGSize(width: 540, height: 360),
          ShortcutEditorValidation.canAdd(name: "Project", target: "/tmp/project"),
          !ShortcutEditorValidation.canAdd(name: "   ", target: "/tmp/project"),
          !ShortcutEditorValidation.canAdd(name: "Project", target: "\n"),
          TaskbarAppClickPolicy.action(
              windows: [],
              isApplicationActive: true,
              isSingleWindowFocused: false
          ) == .activateApplication,
          TaskbarAppClickPolicy.action(
              windows: [landscapePreviewWindow, portraitPreviewWindow],
              isApplicationActive: true,
              isSingleWindowFocused: true
          ) == .doNothing,
          TaskbarAppPrimaryClickPolicy.showsPreviewsImmediately(windowCount: 2, previewsEnabled: true),
          !TaskbarAppPrimaryClickPolicy.showsPreviewsImmediately(windowCount: 1, previewsEnabled: true),
          !TaskbarAppPrimaryClickPolicy.showsPreviewsImmediately(windowCount: 2, previewsEnabled: false),
          TaskbarAppClickPolicy.action(
              windows: [minimizedPreviewWindow],
              isApplicationActive: false,
              isSingleWindowFocused: false
          ) == .restoreWindow,
          TaskbarAppClickPolicy.action(
              windows: [landscapePreviewWindow],
              isApplicationActive: true,
              isSingleWindowFocused: true
          ) == .minimizeWindow,
          TaskbarAppClickPolicy.action(
              windows: [landscapePreviewWindow],
              isApplicationActive: true,
              isSingleWindowFocused: false
          ) == .bringWindowToFront,
          TaskbarAppClickPolicy.action(
              windows: [landscapePreviewWindow],
              isApplicationActive: false,
              isSingleWindowFocused: true
          ) == .bringWindowToFront,
          WindowPreviewHoverPolicy.action(
              hovering: true,
              previewsEnabled: true,
              hasProcess: true
          ) == .present,
          WindowPreviewHoverPolicy.action(
              hovering: false,
              previewsEnabled: true,
              hasProcess: true
          ) == .scheduleDismissal,
          WindowPreviewHoverPolicy.action(
              hovering: true,
              previewsEnabled: false,
              hasProcess: true
          ) == .dismiss,
          WindowPreviewHoverPolicy.action(
              hovering: true,
              previewsEnabled: true,
              hasProcess: false
          ) == .dismiss,
          WindowPreviewThumbnailGeometry.thumbnailSize(
              for: CGSize(width: 1920, height: 1080)
          ) == CGSize(width: 177, height: 100),
          WindowPreviewThumbnailGeometry.thumbnailSize(
              for: CGSize(width: 1200, height: 900)
          ) == CGSize(width: 133, height: 100),
          WindowPreviewThumbnailGeometry.thumbnailSize(
              for: CGSize(width: 1080, height: 1920)
          ) == CGSize(width: 56, height: 100),
          WindowPreviewThumbnailGeometry.thumbnailSize(
              for: CGSize(width: 3200, height: 900)
          ) == CGSize(width: 355, height: 100),
          WindowPreviewThumbnailGeometry.contentWidth(
              for: CGSize(width: 1080, height: 1920)
          ) == 120,
          WindowPreviewThumbnailGeometry.horizontalInset(
              for: CGSize(width: 1080, height: 1920)
          ) == 32,
          WindowPreviewThumbnailGeometry.horizontalInset(
              for: CGSize(width: 1920, height: 1080)
          ) == 0,
          WindowPreviewContentGeometry.itemSize(for: landscapePreviewWindow) == CGSize(width: 193, height: 141),
          WindowPreviewContentGeometry.itemSize(for: portraitPreviewWindow) == CGSize(width: 136, height: 141),
          WindowPreviewContentGeometry.contentSize(
              windows: [landscapePreviewWindow, portraitPreviewWindow],
              position: .bottom
          ) == CGSize(width: 329, height: 141),
          WindowPreviewContentGeometry.contentSize(
              windows: [landscapePreviewWindow, portraitPreviewWindow],
              position: .left
          ) == CGSize(width: 193, height: 282),
          WindowPreviewContentGeometry.contentSize(windows: [], position: .bottom)
              == WindowPreviewMetrics.emptySize,
          WindowPreviewPanelGeometry.frame(
              anchorFrame: CGRect(x: 500, y: 0, width: 40, height: 48),
              contentSize: previewSize,
              position: .bottom,
              screenFrame: previewScreen
          ) == CGRect(x: 350, y: 54, width: 340, height: 130),
          WindowPreviewPanelGeometry.frame(
              anchorFrame: CGRect(x: 500, y: 752, width: 40, height: 48),
              contentSize: previewSize,
              position: .top,
              screenFrame: previewScreen
          ) == CGRect(x: 350, y: 616, width: 340, height: 130),
          WindowPreviewPanelGeometry.frame(
              anchorFrame: CGRect(x: 0, y: 300, width: 48, height: 40),
              contentSize: previewSize,
              position: .left,
              screenFrame: previewScreen
          ) == CGRect(x: 54, y: 255, width: 340, height: 130),
          WindowPreviewPanelGeometry.frame(
              anchorFrame: CGRect(x: 1152, y: 300, width: 48, height: 40),
              contentSize: previewSize,
              position: .right,
              screenFrame: previewScreen
          ) == CGRect(x: 806, y: 255, width: 340, height: 130),
          WindowPreviewPanelGeometry.frame(
              anchorFrame: CGRect(x: 0, y: 0, width: 40, height: 48),
              contentSize: previewSize,
              position: .bottom,
              screenFrame: previewScreen
          ).minX == 8 else {
        fputs("SELF-TEST FAILED: window preview placement mismatch\n", stderr)
        return 1
    }

    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US")
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    calendar.firstWeekday = 1
    let february2024 = calendar.date(from: DateComponents(year: 2024, month: 2, day: 15))!
    let calendarDays = ClockCalendarGrid.days(displayedMonth: february2024, calendar: calendar)
    guard calendarDays.count == 42,
          calendarDays.filter(\.isInDisplayedMonth).count == 29,
          calendarDays.first?.day == 28,
          calendarDays.first?.isInDisplayedMonth == false,
          calendarDays[4].day == 1,
          calendarDays[4].isInDisplayedMonth,
          calendarDays.last?.day == 9,
          ClockCalendarGrid.weekdaySymbols(calendar: calendar) == ["S", "M", "T", "W", "T", "F", "S"],
          ClockCalendarMetrics.headerHeight + 1 + ClockCalendarMetrics.calendarHeight + 1
              + ClockCalendarMetrics.focusHeight == ClockCalendarMetrics.expandedHeight else {
        fputs("SELF-TEST FAILED: clock calendar grid mismatch\n", stderr)
        return 1
    }

    let rollingCalendarState = ClockCalendarState(now: february2024)
    let initialVisibleStartDate = rollingCalendarState.visibleStartDate
    for _ in 0..<260 { rollingCalendarState.scrollWeeks(by: -1) }
    let expectedFiveYearStartDate = ClockCalendarState.calendar.date(
        byAdding: .day,
        value: -(260 * 7),
        to: initialVisibleStartDate
    )!
    guard ClockCalendarState.calendar.isDate(
        rollingCalendarState.visibleStartDate,
        inSameDayAs: expectedFiveYearStartDate
    ), rollingCalendarState.renderedDays.count == 56 else {
        fputs("SELF-TEST FAILED: clock calendar week scrolling range mismatch\n", stderr)
        return 1
    }

    let virtualCalendarState = ClockCalendarState(now: february2024)
    let virtualStartDate = virtualCalendarState.visibleStartDate
    virtualCalendarState.scrollCalendar(by: -15)
    guard virtualCalendarState.visibleStartDate == virtualStartDate,
          virtualCalendarState.gridOffset == -57 else {
        fputs("SELF-TEST FAILED: clock calendar pixel scrolling mismatch\n", stderr)
        return 1
    }
    virtualCalendarState.scrollCalendar(by: -30)
    let expectedVirtualStartDate = ClockCalendarState.calendar.date(
        byAdding: .day,
        value: 7,
        to: virtualStartDate
    )!
    guard ClockCalendarState.calendar.isDate(
        virtualCalendarState.visibleStartDate,
        inSameDayAs: expectedVirtualStartDate
    ), virtualCalendarState.gridOffset == -45,
       virtualCalendarState.renderedDays.count == 56,
       Set(virtualCalendarState.renderedDays.map(\.id)).count == 56 else {
        fputs("SELF-TEST FAILED: clock calendar virtual recycling mismatch\n", stderr)
        return 1
    }
    virtualCalendarState.scheduleCalendarScrollSettling()
    try? await Task.sleep(nanoseconds: 220_000_000)
    guard virtualCalendarState.gridOffset == -42 else {
        fputs("SELF-TEST FAILED: clock calendar scroll settling mismatch\n", stderr)
        return 1
    }

    let wheelCalendarState = ClockCalendarState(now: february2024)
    let wheelStartDate = wheelCalendarState.visibleStartDate
    for _ in 0..<5 { wheelCalendarState.scrollCalendarByWheel(direction: -1) }
    try? await Task.sleep(nanoseconds: 350_000_000)
    let expectedWheelStartDate = ClockCalendarState.calendar.date(
        byAdding: .day,
        value: 35,
        to: wheelStartDate
    )!
    guard ClockCalendarState.calendar.isDate(
        wheelCalendarState.visibleStartDate,
        inSameDayAs: expectedWheelStartDate
    ), wheelCalendarState.gridOffset == -42 else {
        fputs("SELF-TEST FAILED: clock calendar wheel target mismatch\n", stderr)
        return 1
    }

    let resetCalendarState = ClockCalendarState(now: february2024)
    resetCalendarState.scrollWeeks(by: -260)
    let resetDate = calendar.date(from: DateComponents(year: 2024, month: 9, day: 17))!
    resetCalendarState.resetToToday(now: resetDate)
    let resetMonth = ClockCalendarState.calendar.dateInterval(of: .month, for: resetDate)!.start
    let resetVisibleStart = ClockCalendarGrid.startDate(
        displayedMonth: resetMonth,
        calendar: ClockCalendarState.calendar
    )!
    guard ClockCalendarState.calendar.isDate(resetCalendarState.selectedDate, inSameDayAs: resetDate),
          ClockCalendarState.calendar.isDate(resetCalendarState.displayedMonth, inSameDayAs: resetMonth),
          ClockCalendarState.calendar.isDate(resetCalendarState.visibleStartDate, inSameDayAs: resetVisibleStart),
          resetCalendarState.gridOffset == -42,
          resetCalendarState.renderedDays.count == 56 else {
        fputs("SELF-TEST FAILED: clock calendar reset-to-today mismatch\n", stderr)
        return 1
    }

    let selectionCalendarState = ClockCalendarState(now: february2024)
    let selectionMonth = selectionCalendarState.displayedMonth
    let selectionVisibleStart = selectionCalendarState.visibleStartDate
    let selectionRenderedStart = selectionCalendarState.renderedStartDate
    let adjacentMonthDate = selectionCalendarState.renderedDays.first { day in
        !day.isInDisplayedMonth
    }!.date
    selectionCalendarState.select(adjacentMonthDate)
    guard ClockCalendarState.calendar.isDate(
        selectionCalendarState.selectedDate,
        inSameDayAs: adjacentMonthDate
    ), selectionCalendarState.displayedMonth == selectionMonth,
       selectionCalendarState.visibleStartDate == selectionVisibleStart,
       selectionCalendarState.renderedStartDate == selectionRenderedStart,
       selectionCalendarState.gridOffset == -42 else {
        fputs("SELF-TEST FAILED: selecting an adjacent-month date changed the calendar page\n", stderr)
        return 1
    }

    let shanghaiTimeZone = TimeZone(identifier: "Asia/Shanghai")!
    let lunarNewYear = ClockCalendarLunarCalendar.lunarDate(
        for: calendar.date(from: DateComponents(year: 2024, month: 2, day: 10))!,
        timeZone: shanghaiTimeZone
    )
    let leapMonth = ClockCalendarLunarCalendar.lunarDate(
        for: calendar.date(from: DateComponents(year: 2023, month: 3, day: 22))!,
        timeZone: shanghaiTimeZone
    )
    guard lunarNewYear == ClockCalendarLunarDate(month: 1, day: 1, isLeapMonth: false),
          lunarNewYear.compactLabel == "正月",
          lunarNewYear.fullLabel == "农历正月初一",
          leapMonth == ClockCalendarLunarDate(month: 2, day: 1, isLeapMonth: true),
          leapMonth.compactLabel == "闰二月" else {
        fputs("SELF-TEST FAILED: Chinese lunar calendar conversion mismatch\n", stderr)
        return 1
    }

    var chinaCalendar = Calendar(identifier: .gregorian)
    chinaCalendar.locale = Locale(identifier: "zh_CN")
    chinaCalendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
    func calendarAnnotation(year: Int = 2026, month: Int, day: Int) -> ClockCalendarAnnotation {
        let date = chinaCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
        let lunar = ClockCalendarLunarCalendar.lunarDate(for: date, timeZone: chinaCalendar.timeZone)
        return ClockCalendarAnnotationStore.annotation(for: date, lunarDate: lunar, calendar: chinaCalendar)
    }
    let armyDay = calendarAnnotation(month: 8, day: 1)
    let startOfAutumn = calendarAnnotation(month: 8, day: 7)
    let qixi = calendarAnnotation(month: 8, day: 19)
    let newYearMakeupDay = calendarAnnotation(month: 1, day: 4)
    let laborDayHoliday = calendarAnnotation(month: 5, day: 4)
    let midnightBoundaryJingzhe = calendarAnnotation(year: 2014, month: 3, day: 6)
    let midnightBoundaryChunfen = calendarAnnotation(year: 2051, month: 3, day: 20)
    guard armyDay.secondaryLabel == "建军节",
          armyDay.secondaryLabelKind == .festival,
          armyDay.isRestDay,
          startOfAutumn.secondaryLabel == "立秋",
          startOfAutumn.secondaryLabelKind == .solarTerm,
          qixi.secondaryLabel == "七夕节",
          qixi.secondaryLabelKind == .festival,
          newYearMakeupDay.workState == .makeupWorkday(name: "元旦"),
          newYearMakeupDay.isWeekend,
          !newYearMakeupDay.isRestDay,
          laborDayHoliday.workState == .holiday(name: "劳动节"),
          laborDayHoliday.isRestDay,
          midnightBoundaryJingzhe.secondaryLabel == "惊蛰",
          midnightBoundaryChunfen.secondaryLabel == "春分" else {
        fputs("SELF-TEST FAILED: Chinese calendar annotation mismatch\n", stderr)
        return 1
    }

    let eventStart = chinaCalendar.date(from: DateComponents(
        year: 2026, month: 8, day: 26, hour: 23, minute: 30
    ))!
    let eventEnd = chinaCalendar.date(from: DateComponents(
        year: 2026, month: 8, day: 27, hour: 0, minute: 30
    ))!
    let groupedEvent = SystemCalendarEvent(
        identity: SystemCalendarEventIdentity(
            eventIdentifier: "event",
            calendarItemIdentifier: "item",
            occurrenceStartDate: eventStart
        ),
        title: "Overnight",
        startDate: eventStart,
        endDate: eventEnd,
        isAllDay: false,
        location: nil,
        notes: nil,
        url: nil,
        timeZoneIdentifier: chinaCalendar.timeZone.identifier,
        recurrenceOption: .never,
        alertOption: .none,
        calendarID: "calendar",
        calendarTitle: "Test",
        calendarColor: .accent,
        isEditable: true,
        isRecurring: false
    )
    let groupedInterval = DateInterval(
        start: chinaCalendar.startOfDay(for: eventStart),
        end: chinaCalendar.date(byAdding: .day, value: 2, to: chinaCalendar.startOfDay(for: eventStart))!
    )
    let groupedEvents = SystemCalendarEventGrouping.group(
        [groupedEvent],
        in: groupedInterval,
        calendar: chinaCalendar
    )
    let firstEventDay = ClockCalendarDateKey(year: 2026, month: 8, day: 26)
    let secondEventDay = ClockCalendarDateKey(year: 2026, month: 8, day: 27)
    guard groupedEvents[firstEventDay]?.first?.title == "Overnight",
          groupedEvents[secondEventDay]?.first?.title == "Overnight" else {
        fputs("SELF-TEST FAILED: system calendar event day grouping mismatch\n", stderr)
        return 1
    }

    let weeklyRule = EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)
    let fifteenMinuteAlarm = EKAlarm(relativeOffset: -15 * 60)
    let eventDraft = SystemCalendarEventDraft(
        startDate: eventStart,
        endDate: eventEnd,
        calendarID: "calendar",
        timeZoneIdentifier: chinaCalendar.timeZone.identifier
    )
    guard SystemCalendarRecurrenceOption.option(for: [weeklyRule]) == .weekly,
          SystemCalendarRecurrenceOption.monthly.eventKitRule?.frequency == .monthly,
          SystemCalendarAlertOption.option(for: [fifteenMinuteAlarm]) == .fifteenMinutesBefore,
          SystemCalendarAlertOption.oneDayBefore.relativeOffset == -86_400,
          eventDraft.recurrenceOption == .never,
          eventDraft.alertOption == .fifteenMinutesBefore,
          !eventDraft.isRecurring,
          SystemCalendarService.normalizedEventURL("example.com/event")?.absoluteString
              == "https://example.com/event",
          SystemCalendarService.normalizedEventURL("mailto:calendar@example.com")?.scheme == "mailto",
          SystemCalendarService.normalizedEventURL("not a url") == nil else {
        fputs("SELF-TEST FAILED: system calendar event metadata mismatch\n", stderr)
        return 1
    }

    var calendarTransitionSequence = ClockCalendarPanelTransitionSequence()
    let firstCalendarPresentation = calendarTransitionSequence.begin()
    let calendarDismissal = calendarTransitionSequence.begin()
    let secondCalendarPresentation = calendarTransitionSequence.begin()
    guard !calendarTransitionSequence.isCurrent(firstCalendarPresentation),
          !calendarTransitionSequence.isCurrent(calendarDismissal),
          calendarTransitionSequence.isCurrent(secondCalendarPresentation) else {
        fputs("SELF-TEST FAILED: clock calendar transition sequence mismatch\n", stderr)
        return 1
    }

    guard ClockCalendarDismissalPolicy.shouldDismissForFocusLoss(
        isEditingCalendarEvent: false,
        isRequestingCalendarAccess: false
    ),
    !ClockCalendarDismissalPolicy.shouldDismissForFocusLoss(
        isEditingCalendarEvent: true,
        isRequestingCalendarAccess: false
    ),
    !ClockCalendarDismissalPolicy.shouldDismissForFocusLoss(
        isEditingCalendarEvent: false,
        isRequestingCalendarAccess: true
    ),
    !ClockCalendarDismissalPolicy.shouldDismissForFocusLoss(
        isEditingCalendarEvent: true,
        isRequestingCalendarAccess: true
    ) else {
        fputs("SELF-TEST FAILED: clock calendar focus-loss dismissal policy mismatch\n", stderr)
        return 1
    }

    let thirdPreviewOwner = WindowPreviewOwnerID(displayID: 1, bundleIdentifier: "com.example.third")
    var previewHoverIntent = WindowPreviewHoverIntent()
    guard WindowPreviewHoverIntent.initialDelayNanoseconds == 400_000_000,
          WindowPreviewHoverIntent.switchDelayNanoseconds == 180_000_000,
          previewHoverIntent.hover(
              activeOwnerID: nil,
              candidateOwnerID: firstPreviewOwner
          ) == .scheduleInitial,
          previewHoverIntent.pendingOwnerID == firstPreviewOwner,
          previewHoverIntent.resolve(firstPreviewOwner),
          previewHoverIntent.hover(
              activeOwnerID: firstPreviewOwner,
              candidateOwnerID: firstPreviewOwner
          ) == .keepCurrent,
          previewHoverIntent.hover(
              activeOwnerID: firstPreviewOwner,
              candidateOwnerID: secondPreviewOwner
          ) == .scheduleSwitch,
          previewHoverIntent.pendingOwnerID == secondPreviewOwner,
          previewHoverIntent.hover(
              activeOwnerID: firstPreviewOwner,
              candidateOwnerID: thirdPreviewOwner
          ) == .scheduleSwitch,
          !previewHoverIntent.resolve(secondPreviewOwner),
          previewHoverIntent.resolve(thirdPreviewOwner),
          previewHoverIntent.pendingOwnerID == nil else {
        fputs("SELF-TEST FAILED: window preview hover intent mismatch\n", stderr)
        return 1
    }
    _ = previewHoverIntent.hover(
        activeOwnerID: firstPreviewOwner,
        candidateOwnerID: secondPreviewOwner
    )
    previewHoverIntent.cancel(secondPreviewOwner)
    guard !previewHoverIntent.resolve(secondPreviewOwner) else {
        fputs("SELF-TEST FAILED: cancelled window preview switch resolved\n", stderr)
        return 1
    }

    let minimizedWindowFrame = CGRect(x: 40, y: 80, width: 900, height: 600)
    guard !WindowPreviewWindowPolicy.listOptions.contains(.optionOnScreenOnly),
          WindowPreviewWindowPolicy.shouldInclude(
              isOnScreen: true,
              frame: CGRect(x: 10, y: 20, width: 800, height: 500),
              minimizedWindowFrames: []
          ),
          WindowPreviewWindowPolicy.shouldInclude(
              isOnScreen: false,
              frame: minimizedWindowFrame,
              minimizedWindowFrames: [minimizedWindowFrame]
          ),
          !WindowPreviewWindowPolicy.shouldInclude(
              isOnScreen: false,
              frame: minimizedWindowFrame,
              minimizedWindowFrames: []
          ) else {
        fputs("SELF-TEST FAILED: minimized window preview policy mismatch\n", stderr)
        return 1
    }

    let thumbnailCache = WindowThumbnailCache()
    let capturedThumbnail = NSImage(size: NSSize(width: 320, height: 180))
    let refreshedThumbnail = NSImage(size: NSSize(width: 640, height: 360))
    var thumbnailCaptureCount = 0
    guard thumbnailCache.image(for: 101, capture: {
        thumbnailCaptureCount += 1
        return capturedThumbnail
    }) === capturedThumbnail,
          thumbnailCache.image(for: 101, capture: {
              thumbnailCaptureCount += 1
              return refreshedThumbnail
          }) === capturedThumbnail,
          thumbnailCaptureCount == 1,
          thumbnailCache.refreshImage(for: 101, capture: {
              thumbnailCaptureCount += 1
              return refreshedThumbnail
          }) === refreshedThumbnail,
          thumbnailCaptureCount == 2,
          thumbnailCache.image(for: 202, capture: { nil }) == nil else {
        fputs("SELF-TEST FAILED: window thumbnail cache mismatch\n", stderr)
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

    var peekHoverSession = WindowPeekHoverSession()
    let firstPeekWindowID: CGWindowID = 101
    let secondPeekWindowID: CGWindowID = 202
    guard WindowPeekHoverSession.initialDelayNanoseconds == 300_000_000,
          peekHoverSession.hover(windowID: firstPeekWindowID) == .delay,
          !peekHoverSession.activatePending(windowID: secondPeekWindowID),
          peekHoverSession.activatePending(windowID: firstPeekWindowID),
          peekHoverSession.isActive,
          peekHoverSession.hover(windowID: secondPeekWindowID) == .present else {
        fputs("SELF-TEST FAILED: initial window peek hover session mismatch\n", stderr)
        return 1
    }
    peekHoverSession.end()
    guard !peekHoverSession.isActive,
          peekHoverSession.hover(windowID: secondPeekWindowID) == .delay else {
        fputs("SELF-TEST FAILED: window peek hover session did not reset\n", stderr)
        return 1
    }
    peekHoverSession.cancelPending()
    guard !peekHoverSession.activatePending(windowID: secondPeekWindowID) else {
        fputs("SELF-TEST FAILED: cancelled window peek hover activated\n", stderr)
        return 1
    }

    var optionGesture = WindowsKeyGestureState()
    guard !optionGesture.flagsChanged(to: [.option]),
          optionGesture.flagsChanged(to: []) else {
        fputs("SELF-TEST FAILED: Option-only release did not trigger\n", stderr)
        return 1
    }
    optionGesture = WindowsKeyGestureState()
    guard !optionGesture.flagsChanged(to: [.capsLock, .option]),
          optionGesture.flagsChanged(to: [.capsLock]) else {
        fputs("SELF-TEST FAILED: Caps Lock blocked Option-only release\n", stderr)
        return 1
    }
    optionGesture = WindowsKeyGestureState()
    _ = optionGesture.handle(eventType: .flagsChanged, modifierFlags: [.option])
    _ = optionGesture.handle(eventType: .keyDown)
    guard !optionGesture.flagsChanged(to: []) else {
        fputs("SELF-TEST FAILED: Option key combination triggered\n", stderr)
        return 1
    }
    optionGesture = WindowsKeyGestureState()
    guard !optionGesture.flagsChanged(to: [.command]),
          !optionGesture.flagsChanged(to: [.command, .option]),
          !optionGesture.flagsChanged(to: [.command]) else {
        fputs("SELF-TEST FAILED: pre-held modifier combination triggered\n", stderr)
        return 1
    }
    optionGesture = WindowsKeyGestureState()
    guard !optionGesture.flagsChanged(to: [.option]),
          !optionGesture.flagsChanged(to: [.option, .shift]),
          !optionGesture.flagsChanged(to: [.shift]) else {
        fputs("SELF-TEST FAILED: modifier added after Option triggered\n", stderr)
        return 1
    }
    optionGesture = WindowsKeyGestureState()
    guard !optionGesture.flagsChanged(to: [.option]),
          !optionGesture.flagsChanged(to: [.option]),
          !optionGesture.flagsChanged(to: []) else {
        fputs("SELF-TEST FAILED: dual Option gesture triggered\n", stderr)
        return 1
    }
    var commandGesture = WindowsKeyGestureState(windowsModifier: .command)
    guard !commandGesture.flagsChanged(to: [.command]),
          commandGesture.flagsChanged(to: []),
          !commandGesture.flagsChanged(to: [.option]),
          !commandGesture.flagsChanged(to: [.option, .command]),
          !commandGesture.flagsChanged(to: [.option]) else {
        fputs("SELF-TEST FAILED: configurable Windows modifier gesture mismatch\n", stderr)
        return 1
    }

    let forwardWindowsSpaceShortcut = HotkeyShortcut(
        keyCode: 49,
        modifiers: UInt32(optionKey),
        keyLabel: "Space"
    )
    let reverseWindowsSpaceShortcut = GlobalHotkeysService.reverseWindowsSpaceShortcut(
        for: forwardWindowsSpaceShortcut
    )
    var quickWindowsSpaceGesture = WindowsSpaceGestureState()
    var quickReverseWindowsSpaceGesture = WindowsSpaceGestureState()
    var heldWindowsSpaceGesture = WindowsSpaceGestureState()
    var interruptedWindowsSpaceGesture = WindowsSpaceGestureState()
    guard let reverseWindowsSpaceShortcut,
          reverseWindowsSpaceShortcut.keyCode == forwardWindowsSpaceShortcut.keyCode,
          reverseWindowsSpaceShortcut.modifiers == UInt32(optionKey | shiftKey),
          GlobalHotkeysService.reverseWindowsSpaceShortcut(for: reverseWindowsSpaceShortcut) == nil,
          WindowsSpaceGestureState.presentationDelayMilliseconds == 300,
          quickWindowsSpaceGesture.press() == nil,
          quickWindowsSpaceGesture.flagsChanged(to: [.option]) == nil,
          quickWindowsSpaceGesture.flagsChanged(to: []) == .advance,
          quickWindowsSpaceGesture.presentationDelayElapsed() == nil,
          quickReverseWindowsSpaceGesture.press(reverse: true) == nil,
          quickReverseWindowsSpaceGesture.flagsChanged(to: []) == .retreat,
          heldWindowsSpaceGesture.press() == nil,
          heldWindowsSpaceGesture.presentationDelayElapsed() == .present,
          heldWindowsSpaceGesture.press() == .advance,
          heldWindowsSpaceGesture.press(reverse: true) == .retreat,
          heldWindowsSpaceGesture.flagsChanged(to: []) == .dismiss,
          heldWindowsSpaceGesture.flagsChanged(to: []) == nil,
          heldWindowsSpaceGesture.press() == nil,
          heldWindowsSpaceGesture.reset() == nil,
          interruptedWindowsSpaceGesture.press() == nil,
          interruptedWindowsSpaceGesture.presentationDelayElapsed() == .present,
          interruptedWindowsSpaceGesture.reset() == .dismiss else {
        fputs("SELF-TEST FAILED: Win+Space gesture lifecycle mismatch\n", stderr)
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

    let legacyHotkeySuiteName = "WinTaskbar.SelfTest.LegacyHotkeys.\(UUID().uuidString)"
    guard let legacyHotkeyDefaults = UserDefaults(suiteName: legacyHotkeySuiteName) else {
        fputs("SELF-TEST FAILED: cannot create legacy hotkey defaults\n", stderr)
        return 1
    }
    defer { legacyHotkeyDefaults.removePersistentDomain(forName: legacyHotkeySuiteName) }
    var legacyHotkeys = GlobalShortcutCatalog.defaultLegacyShortcuts
    legacyHotkeys[0] = HotkeyShortcut(keyCode: 0, modifiers: UInt32(cmdKey), keyLabel: "A")
    legacyHotkeyDefaults.set(try? JSONEncoder().encode(legacyHotkeys), forKey: "wintaskbar.hotkeyShortcuts")
    let migratedHotkeyPreferences = PreferencesStore(defaults: legacyHotkeyDefaults)
    guard migratedHotkeyPreferences.globalShortcutConfigurations.first?.shortcut.keyLabel == "A",
          migratedHotkeyPreferences.globalShortcutConfigurations.contains(where: {
              $0.id == GlobalShortcutCatalog.fileManagerID && $0.isEnabled
          }),
          migratedHotkeyPreferences.globalShortcutConfigurations.contains(where: {
              $0.id == GlobalShortcutCatalog.quickLinkMenuID
          }) else {
        fputs("SELF-TEST FAILED: legacy hotkey migration mismatch\n", stderr)
        return 1
    }

    var storedShortcutConfigurations = GlobalShortcutCatalog.defaults(
        legacyShortcuts: GlobalShortcutCatalog.defaultLegacyShortcuts
    )
    guard let storedShowDesktopIndex = storedShortcutConfigurations.firstIndex(where: {
        $0.id == GlobalShortcutCatalog.showDesktopID
    }),
    let storedPinnedIndex = storedShortcutConfigurations.firstIndex(where: { $0.id == "pinned-1" }),
    let storedRunIndex = storedShortcutConfigurations.firstIndex(where: {
        $0.id == GlobalShortcutCatalog.runID
    }) else {
        fputs("SELF-TEST FAILED: Windows shortcut migration fixture mismatch\n", stderr)
        return 1
    }
    storedShortcutConfigurations[storedShowDesktopIndex].shortcut = GlobalShortcutCatalog.defaultLegacyShortcuts[1]
    storedShortcutConfigurations[storedShowDesktopIndex].usesWindowsKey = false
    storedShortcutConfigurations[storedShowDesktopIndex].action = .toggleCalendar
    storedShortcutConfigurations[storedPinnedIndex].shortcut = GlobalShortcutCatalog.defaultLegacyShortcuts[2]
    storedShortcutConfigurations[storedPinnedIndex].usesWindowsKey = false
    storedShortcutConfigurations[storedRunIndex].action = .openApplication
    let mergedShortcutConfigurations = GlobalShortcutCatalog.merged(
        stored: storedShortcutConfigurations,
        legacyShortcuts: GlobalShortcutCatalog.defaultLegacyShortcuts
    )
    guard mergedShortcutConfigurations[storedShowDesktopIndex].usesWindowsKey,
          mergedShortcutConfigurations[storedShowDesktopIndex].action == .showDesktop,
          mergedShortcutConfigurations[storedPinnedIndex].usesWindowsKey,
          mergedShortcutConfigurations[storedRunIndex].action == .showRunDialog else {
        fputs("SELF-TEST FAILED: Windows shortcut trigger migration mismatch\n", stderr)
        return 1
    }

    preferences.position = .left
    preferences.autoHideTaskbar = true
    preferences.showBadgesOnTaskbarApps = false
    preferences.showFlashingOnTaskbarApps = false
    preferences.barHeight = 64
    preferences.trayWifiEnabled = false
    preferences.trayClockShowsSeconds = false
    preferences.dateTimeFirstDayOfWeek = .monday
    preferences.dateTimeShortDatePattern = "yyyy-MM-dd"
    preferences.dateTimeLongDateStyle = .custom
    preferences.dateTimeCustomLongDatePattern = "yyyy.MM.dd"
    preferences.dateTimeCustomLongDateIncludesLunar = true
    preferences.additionalClocks[0] = AdditionalClockConfiguration(
        slot: 1,
        isEnabled: true,
        timeZoneIdentifier: "America/Chicago",
        displayName: "Chicago"
    )
    preferences.pinnedBundleIDs = ["one", "two", "three"]
    preferences.reorderPinned("three", relativeTo: "one", after: false)
    let reorderedPinnedBundleIDs = preferences.pinnedBundleIDs
    preferences.alignPinnedOrder(to: ["two", "three", "one"])
    preferences.appFolders = [AppFolder(name: "Work", bundleIDs: ["one"])]
    preferences.globalShortcutConfigurations[0].shortcut = HotkeyShortcut(
        keyCode: 0,
        modifiers: UInt32(cmdKey),
        keyLabel: "A"
    )
    customShortcut.action = .showDesktop
    preferences.customShortcutConfigurations = [customShortcut]
    guard defaults.string(forKey: "wintaskbar.position") == "Left",
          defaults.bool(forKey: "wintaskbar.autoHideTaskbar"),
          defaults.bool(forKey: "wintaskbar.showBadgesOnTaskbarApps") == false,
          defaults.bool(forKey: "wintaskbar.showFlashingOnTaskbarApps") == false,
          defaults.double(forKey: "wintaskbar.barHeight") == 64,
          defaults.bool(forKey: "wintaskbar.feature.trayWifi") == false,
          !PreferencesStore(defaults: defaults).trayClockShowsSeconds,
          PreferencesStore(defaults: defaults).dateTimeFirstDayOfWeek == .monday,
          PreferencesStore(defaults: defaults).dateTimeShortDatePattern == "yyyy-MM-dd",
          PreferencesStore(defaults: defaults).dateTimeLongDateStyle == .custom,
          PreferencesStore(defaults: defaults).dateTimeFormatConfiguration.longDatePattern == "yyyy.MM.dd",
          PreferencesStore(defaults: defaults).dateTimeFormatConfiguration.longDateIncludesLunar,
          PreferencesStore(defaults: defaults).additionalClocks[0].displayName == "Chicago",
          reorderedPinnedBundleIDs == ["three", "one", "two"],
          preferences.pinnedBundleIDs == ["two", "three", "one"],
          PreferencesStore(defaults: defaults).appFolders.first?.bundleIDs == ["one"],
          PreferencesStore(defaults: defaults).globalShortcutConfigurations.first?.shortcut.keyLabel == "A",
          PreferencesStore(defaults: defaults).customShortcutConfigurations.first?.action == .showDesktop,
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
    print("SELF-TEST PASSED: defaults, taskbar and window fitting geometry, configurable Windows key gesture, global shortcut migration, attention, preference persistence, and app URL drag provider")
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
