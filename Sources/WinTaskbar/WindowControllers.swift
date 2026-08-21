import AppKit
import Combine
import Darwin
import SwiftUI

@MainActor
private enum WindowBlur {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SetBackgroundBlur = @convention(c) (Int32, Int32, Int32) -> Int32

    private static let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)
    private static let connectionID: Int32? = {
        guard let defaultHandle, let symbol = dlsym(defaultHandle, "CGSMainConnectionID") else { return nil }
        return unsafeBitCast(symbol, to: MainConnection.self)()
    }()
    private static let setBackgroundBlur: SetBackgroundBlur? = {
        guard let defaultHandle,
              let symbol = dlsym(defaultHandle, "CGSSetWindowBackgroundBlurRadius") else { return nil }
        return unsafeBitCast(symbol, to: SetBackgroundBlur.self)
    }()

    static func apply(radius: Int, to window: NSWindow) {
        let windowNumber = window.windowNumber
        guard windowNumber > 0,
              let connectionID,
              let setBackgroundBlur else { return }
        _ = setBackgroundBlur(connectionID, Int32(windowNumber), Int32(max(0, radius)))
    }
}

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
            applyAppearance(to: panel)
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
            recentDocuments: recentDocuments,
            screen: screen
        ))
        applyAppearance(to: panel)
        return panel
    }

    private func applyAppearance(to panel: NSPanel) {
        panel.appearance = appearance
        WindowBlur.apply(
            radius: preferences.transparencyEnabled ? Int(preferences.panelBlurRadius.rounded()) : 0,
            to: panel
        )
    }

    private var appearance: NSAppearance? {
        switch preferences.theme {
        case .automatic: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
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
    private let backdrop = NSView()
    private var cancellable: AnyCancellable?

    init(
        preferences: PreferencesStore,
        apps: AppDiscoveryService,
        actions: AppActions,
        taskbar: TaskbarWindowController
    ) {
        self.preferences = preferences
        self.taskbar = taskbar
        panel = StartMenuPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: StartMenuView(apps: apps, actions: actions, preferences: preferences))
        installContentView()
        applyAppearance()
        cancellable = preferences.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyAppearance() }
        }
    }

    func toggle(on screen: NSScreen? = nil) {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            positionPanel(on: screen ?? taskbar.activeScreen)
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            applyBlur()
        }
    }

    func hide() { panel.orderOut(nil) }

    private func applyAppearance() {
        switch preferences.theme {
        case .automatic: panel.appearance = nil
        case .light: panel.appearance = NSAppearance(named: .aqua)
        case .dark: panel.appearance = NSAppearance(named: .darkAqua)
        }
        backdrop.wantsLayer = true
        backdrop.alphaValue = preferences.transparencyEnabled ? preferences.panelOpacity : 1
        backdrop.layer?.backgroundColor = backdropColor.cgColor
        backdrop.layer?.cornerRadius = menuCornerRadius
        backdrop.layer?.masksToBounds = true
        panel.hasShadow = menuCornerRadius > 0
        applyBlur()
    }

    private func installContentView() {
        guard let hostingView = panel.contentView else { return }
        let container = NSView()
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(backdrop)
        container.addSubview(hostingView)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: container.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        panel.contentView = container
    }

    private var backdropColor: NSColor {
        if let tint = NSColor(hex: preferences.panelTintHex) {
            return preferences.transparencyEnabled ? tint : tint.withAlphaComponent(1)
        }
        return NSColor.windowBackgroundColor.withAlphaComponent(preferences.transparencyEnabled ? 0.4 : 1)
    }

    private var menuCornerRadius: CGFloat {
        preferences.menuWindowStyle == .windows ? 10 : 0
    }

    private func applyBlur() {
        WindowBlur.apply(
            radius: preferences.transparencyEnabled ? Int(preferences.panelBlurRadius.rounded()) : 0,
            to: panel
        )
    }

    private func positionPanel(on screen: NSScreen) {
        let frame = StartMenuGeometry.frame(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            position: preferences.position,
            barHeight: CGFloat(preferences.barHeight),
            heightMode: preferences.menuHeightMode,
            oppositeEnd: preferences.startButtonAtEnd || preferences.menuButtonPlacement != .standard
        )
        panel.setFrame(frame, display: true)
    }
}

enum StartMenuGeometry {
    static let width: CGFloat = 400
    static let standardHeight: CGFloat = 480

    static func frame(
        screenFrame: NSRect,
        visibleFrame: NSRect,
        position: TaskbarPosition,
        barHeight: CGFloat,
        heightMode: MenuHeightMode,
        oppositeEnd: Bool
    ) -> NSRect {
        let x: CGFloat
        let y: CGFloat
        let height: CGFloat

        switch position {
        case .bottom:
            x = oppositeEnd ? screenFrame.maxX - width : screenFrame.minX
            y = screenFrame.minY + barHeight
            height = heightMode == .full ? max(0, visibleFrame.maxY - y) : standardHeight
        case .top:
            x = oppositeEnd ? screenFrame.maxX - width : screenFrame.minX
            height = heightMode == .full
                ? max(0, visibleFrame.maxY - barHeight - visibleFrame.minY)
                : standardHeight
            y = visibleFrame.maxY - barHeight - height
        case .left:
            x = screenFrame.minX + barHeight
            height = heightMode == .full ? visibleFrame.height : standardHeight
            y = heightMode == .full
                ? visibleFrame.minY
                : (oppositeEnd ? screenFrame.minY : screenFrame.maxY - height)
        case .right:
            x = screenFrame.maxX - barHeight - width
            height = heightMode == .full ? visibleFrame.height : standardHeight
            y = heightMode == .full
                ? visibleFrame.minY
                : (oppositeEnd ? screenFrame.minY : screenFrame.maxY - height)
        }

        return NSRect(x: x, y: y, width: width, height: height)
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
