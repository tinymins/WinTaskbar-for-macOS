import AppKit
import Combine
import SwiftUI

final class TaskbarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class StartMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class TaskbarWindowController {
    private let preferences: PreferencesStore
    private let apps: AppDiscoveryService
    private let status: SystemStatusService
    private let actions: AppActions
    private let windowActivator: WindowActivationService
    private let windowsService: WindowsService
    private let recentDocuments: RecentDocumentsService
    private let dockBadges: DockBadgeService
    private var panels: [TaskbarPanel] = []
    private var cancellable: AnyCancellable?

    init(
        preferences: PreferencesStore,
        apps: AppDiscoveryService,
        status: SystemStatusService,
        actions: AppActions,
        windowActivator: WindowActivationService,
        windowsService: WindowsService,
        recentDocuments: RecentDocumentsService,
        dockBadges: DockBadgeService
    ) {
        self.preferences = preferences
        self.apps = apps
        self.status = status
        self.actions = actions
        self.windowActivator = windowActivator
        self.windowsService = windowsService
        self.recentDocuments = recentDocuments
        self.dockBadges = dockBadges
        cancellable = preferences.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.applyLayout()
            }
        }
    }

    func show() {
        rebuildPanels()
    }

    func rebuildPanels() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()

        let screens = preferences.displayMode == .primary ? Array(NSScreen.screens.prefix(1)) : NSScreen.screens
        for screen in screens {
            let panel = makePanel(for: screen)
            panels.append(panel)
            panel.orderFrontRegardless()
        }
    }

    func applyLayout() {
        let expectedCount = preferences.displayMode == .primary ? min(1, NSScreen.screens.count) : NSScreen.screens.count
        guard panels.count == expectedCount else {
            rebuildPanels()
            return
        }
        for (panel, screen) in zip(panels, NSScreen.screens) {
            panel.setFrame(frame(for: screen), display: true, animate: false)
        }
    }

    private func makePanel(for screen: NSScreen) -> TaskbarPanel {
        let panel = TaskbarPanel(
            contentRect: frame(for: screen),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.contentView = NSHostingView(rootView: TaskbarView(
            preferences: preferences,
            apps: apps,
            status: status,
            actions: actions,
            dockBadges: dockBadges,
            windowActivator: windowActivator,
            windowsService: windowsService,
            recentDocuments: recentDocuments
        ))
        return panel
    }

    private func frame(for screen: NSScreen) -> NSRect {
        let screenFrame = screen.frame
        let size = CGFloat(preferences.barHeight)
        switch preferences.position {
        case .bottom:
            return NSRect(x: screenFrame.minX, y: screenFrame.minY, width: screenFrame.width, height: size)
        case .top:
            return NSRect(x: screenFrame.minX, y: screen.visibleFrame.maxY - size, width: screenFrame.width, height: size)
        case .left:
            return NSRect(x: screenFrame.minX, y: screenFrame.minY, width: size, height: screenFrame.height)
        case .right:
            return NSRect(x: screenFrame.maxX - size, y: screenFrame.minY, width: size, height: screenFrame.height)
        }
    }

    var activeScreen: NSScreen { panels.first?.screen ?? NSScreen.main ?? NSScreen.screens[0] }
}

@MainActor
final class StartMenuController {
    private let preferences: PreferencesStore
    private let taskbar: TaskbarWindowController
    private let panel: NSPanel

    init(
        preferences: PreferencesStore,
        apps: AppDiscoveryService,
        actions: AppActions,
        taskbar: TaskbarWindowController
    ) {
        self.preferences = preferences
        self.taskbar = taskbar
        panel = StartMenuPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: StartMenuView(apps: apps, actions: actions, preferences: preferences))
    }

    func toggle() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            positionPanel()
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func hide() { panel.orderOut(nil) }

    private func positionPanel() {
        let screen = taskbar.activeScreen
        let targetHeight: CGFloat = preferences.menuHeightMode == .full
            ? max(480, screen.visibleFrame.height - CGFloat(preferences.barHeight))
            : 560
        panel.setContentSize(NSSize(width: 480, height: targetHeight))
        let size = panel.frame.size
        let barSize = CGFloat(preferences.barHeight)
        let frame: NSRect
        switch preferences.position {
        case .bottom:
            frame = NSRect(x: screen.frame.minX, y: screen.frame.minY + barSize, width: size.width, height: size.height)
        case .top:
            frame = NSRect(x: screen.frame.minX, y: screen.visibleFrame.maxY - barSize - size.height, width: size.width, height: size.height)
        case .left:
            frame = NSRect(x: screen.frame.minX + barSize, y: screen.frame.minY, width: size.width, height: min(size.height, screen.frame.height))
        case .right:
            frame = NSRect(x: screen.frame.maxX - barSize - size.width, y: screen.frame.minY, width: size.width, height: min(size.height, screen.frame.height))
        }
        panel.setFrame(frame, display: true)
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    init(preferences: PreferencesStore) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "WinTaskbar Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(preferences: preferences))
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
