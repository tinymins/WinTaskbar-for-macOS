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

final class WindowPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct WindowPreviewPanelGeometry {
    static let gap: CGFloat = 6
    static let screenInset: CGFloat = 8

    static func frame(
        anchorFrame: CGRect,
        contentSize: CGSize,
        position: TaskbarPosition,
        screenFrame: CGRect
    ) -> CGRect {
        let origin: CGPoint
        switch position {
        case .bottom:
            origin = CGPoint(
                x: anchorFrame.midX - contentSize.width / 2,
                y: anchorFrame.maxY + gap
            )
        case .top:
            origin = CGPoint(
                x: anchorFrame.midX - contentSize.width / 2,
                y: anchorFrame.minY - contentSize.height - gap
            )
        case .left:
            origin = CGPoint(
                x: anchorFrame.maxX + gap,
                y: anchorFrame.midY - contentSize.height / 2
            )
        case .right:
            origin = CGPoint(
                x: anchorFrame.minX - contentSize.width - gap,
                y: anchorFrame.midY - contentSize.height / 2
            )
        }

        let minX = screenFrame.minX + screenInset
        let maxX = max(minX, screenFrame.maxX - screenInset - contentSize.width)
        let minY = screenFrame.minY + screenInset
        let maxY = max(minY, screenFrame.maxY - screenInset - contentSize.height)
        return CGRect(
            origin: CGPoint(
                x: min(max(origin.x, minX), maxX),
                y: min(max(origin.y, minY), maxY)
            ),
            size: contentSize
        )
    }
}

struct WindowPreviewOwnerID: Hashable {
    let displayID: CGDirectDisplayID
    let bundleIdentifier: String
}

struct WindowPreviewSelection: Equatable {
    private(set) var activeOwnerID: WindowPreviewOwnerID?

    mutating func activate(_ ownerID: WindowPreviewOwnerID) {
        activeOwnerID = ownerID
    }

    @discardableResult
    mutating func dismiss(_ ownerID: WindowPreviewOwnerID) -> Bool {
        guard activeOwnerID == ownerID else { return false }
        activeOwnerID = nil
        return true
    }

    mutating func dismissAll() {
        activeOwnerID = nil
    }
}

enum WindowPreviewHoverIntentDecision: Equatable {
    case activateImmediately
    case keepCurrent
    case scheduleSwitch
}

struct WindowPreviewHoverIntent {
    static let switchDelayNanoseconds: UInt64 = 180_000_000

    private(set) var pendingOwnerID: WindowPreviewOwnerID?

    mutating func hover(
        activeOwnerID: WindowPreviewOwnerID?,
        candidateOwnerID: WindowPreviewOwnerID
    ) -> WindowPreviewHoverIntentDecision {
        if activeOwnerID == nil {
            pendingOwnerID = nil
            return .activateImmediately
        }
        if activeOwnerID == candidateOwnerID {
            pendingOwnerID = nil
            return .keepCurrent
        }
        pendingOwnerID = candidateOwnerID
        return .scheduleSwitch
    }

    mutating func resolve(_ ownerID: WindowPreviewOwnerID) -> Bool {
        guard pendingOwnerID == ownerID else { return false }
        pendingOwnerID = nil
        return true
    }

    mutating func cancel(_ ownerID: WindowPreviewOwnerID) {
        if pendingOwnerID == ownerID { pendingOwnerID = nil }
    }

    mutating func reset() {
        pendingOwnerID = nil
    }
}

struct WindowPreviewPanelTransitionPolicy {
    static func shouldAnimate(
        isVisible: Bool,
        displayedOwnerID: WindowPreviewOwnerID?,
        targetOwnerID: WindowPreviewOwnerID
    ) -> Bool {
        isVisible && displayedOwnerID != targetOwnerID
    }
}

struct WindowPreviewPanelMotion {
    static let duration: TimeInterval = 0.28
    static let firstControlPoint = CGPoint(x: 0.8, y: 0)
    static let secondControlPoint = CGPoint(x: 0.2, y: 1)

    static func timingFunction() -> CAMediaTimingFunction {
        CAMediaTimingFunction(
            controlPoints: Float(firstControlPoint.x),
            Float(firstControlPoint.y),
            Float(secondControlPoint.x),
            Float(secondControlPoint.y)
        )
    }
}

@MainActor
final class WindowPreviewPanelController: ObservableObject {
    @Published private var selection = WindowPreviewSelection()
    private var hoverIntent = WindowPreviewHoverIntent()
    private var displayedOwnerID: WindowPreviewOwnerID?
    private var activationTask: Task<Void, Never>?
    private var dismissalTask: Task<Void, Never>?
    private var panel: WindowPreviewPanel?
    private let backdrop = NSVisualEffectView()
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))

    var activeOwnerID: WindowPreviewOwnerID? { selection.activeOwnerID }

    init() {
        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 8
        backdrop.layer?.masksToBounds = true
        backdrop.layer?.borderWidth = 0.5
        backdrop.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: backdrop.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
        ])
    }

    func activate(ownerID: WindowPreviewOwnerID) {
        cancelDismissal()
        activationTask?.cancel()
        activationTask = nil

        switch hoverIntent.hover(activeOwnerID: selection.activeOwnerID, candidateOwnerID: ownerID) {
        case .activateImmediately:
            activateImmediately(ownerID: ownerID)
        case .keepCurrent:
            break
        case .scheduleSwitch:
            activationTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: WindowPreviewHoverIntent.switchDelayNanoseconds)
                guard !Task.isCancelled, self?.hoverIntent.resolve(ownerID) == true else { return }
                self?.activationTask = nil
                self?.activateImmediately(ownerID: ownerID)
            }
        }
    }

    private func activateImmediately(ownerID: WindowPreviewOwnerID) {
        var updatedSelection = selection
        updatedSelection.activate(ownerID)
        selection = updatedSelection
    }

    func cancelDismissal(ownerID: WindowPreviewOwnerID) {
        guard selection.activeOwnerID == ownerID || hoverIntent.pendingOwnerID == ownerID else { return }
        cancelDismissal()
    }

    func scheduleDismissal(
        ownerID: WindowPreviewOwnerID,
        onDismiss: @escaping @MainActor () -> Void
    ) {
        guard let activeOwnerID = selection.activeOwnerID,
              activeOwnerID == ownerID || hoverIntent.pendingOwnerID == ownerID else { return }
        activationTask?.cancel()
        activationTask = nil
        hoverIntent.cancel(ownerID)
        cancelDismissal()
        dismissalTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled,
                  self?.selection.activeOwnerID == activeOwnerID,
                  self?.hoverIntent.pendingOwnerID == nil else { return }
            self?.dismiss(ownerID: activeOwnerID)
            onDismiss()
        }
    }

    func dismiss(ownerID: WindowPreviewOwnerID) {
        activationTask?.cancel()
        activationTask = nil
        hoverIntent.reset()
        guard selection.activeOwnerID == ownerID else { return }
        cancelDismissal()
        var updatedSelection = selection
        guard updatedSelection.dismiss(ownerID) else { return }
        selection = updatedSelection
        hidePanel()
    }

    func dismissAll() {
        activationTask?.cancel()
        activationTask = nil
        hoverIntent.reset()
        cancelDismissal()
        if selection.activeOwnerID != nil {
            var updatedSelection = selection
            updatedSelection.dismissAll()
            selection = updatedSelection
        }
        hidePanel()
    }

    func show(
        ownerID: WindowPreviewOwnerID,
        rootView: AnyView,
        relativeTo anchorView: NSView,
        position: TaskbarPosition,
        contentSize: CGSize,
        animatesTransition: Bool
    ) {
        guard selection.activeOwnerID == ownerID, let anchorWindow = anchorView.window else { return }
        let panel = panel ?? makePanel()
        hostingView.rootView = rootView
        guard contentSize.width > 0, contentSize.height > 0 else { return }

        let windowRect = anchorView.convert(anchorView.bounds, to: nil)
        let anchorFrame = anchorWindow.convertToScreen(windowRect)
        let screenFrame = anchorWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? anchorFrame
        let targetFrame = WindowPreviewPanelGeometry.frame(
            anchorFrame: anchorFrame,
            contentSize: contentSize,
            position: position,
            screenFrame: screenFrame
        )
        let shouldAnimate = animatesTransition && WindowPreviewPanelTransitionPolicy.shouldAnimate(
            isVisible: panel.isVisible,
            displayedOwnerID: displayedOwnerID,
            targetOwnerID: ownerID
        )

        panel.appearance = anchorWindow.appearance
        displayedOwnerID = ownerID
        if shouldAnimate {
            hostingView.alphaValue = 0.72
            NSAnimationContext.runAnimationGroup { context in
                context.duration = WindowPreviewPanelMotion.duration
                context.timingFunction = WindowPreviewPanelMotion.timingFunction()
                panel.animator().setFrame(targetFrame, display: true)
                hostingView.animator().alphaValue = 1
            }
        } else {
            hostingView.alphaValue = 1
            panel.setFrame(targetFrame, display: true)
        }
        panel.orderFrontRegardless()
    }

    private func cancelDismissal() {
        dismissalTask?.cancel()
        dismissalTask = nil
    }

    private func hidePanel() {
        displayedOwnerID = nil
        panel?.orderOut(nil)
        hostingView.alphaValue = 1
    }

    private func makePanel() -> WindowPreviewPanel {
        let panel = WindowPreviewPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.contentView = backdrop
        self.panel = panel
        return panel
    }
}

struct WindowPreviewPanelPresenter<Content: View>: NSViewRepresentable {
    private let isPresented: Bool
    private let ownerID: WindowPreviewOwnerID
    private let position: TaskbarPosition
    private let contentSize: CGSize
    private let animatesTransition: Bool
    @ObservedObject private var controller: WindowPreviewPanelController
    private let content: () -> Content

    init(
        isPresented: Bool,
        ownerID: WindowPreviewOwnerID,
        position: TaskbarPosition,
        contentSize: CGSize,
        animatesTransition: Bool,
        controller: WindowPreviewPanelController,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.isPresented = isPresented
        self.ownerID = ownerID
        self.position = position
        self.contentSize = contentSize
        self.animatesTransition = animatesTransition
        self.controller = controller
        self.content = content
    }

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let rootView = AnyView(content())
        DispatchQueue.main.async {
            if isPresented {
                controller.show(
                    ownerID: ownerID,
                    rootView: rootView,
                    relativeTo: nsView,
                    position: position,
                    contentSize: contentSize,
                    animatesTransition: animatesTransition
                )
            }
        }
    }
}

@MainActor
final class TaskbarWindowController {
    private let preferences: PreferencesStore
    private let apps: AppDiscoveryService
    private let status: SystemStatusService
    private let actions: AppActions
    private let windowActivator: WindowActivationService
    private let windowsService: WindowsService
    private let windowPeekController: WindowPeekController
    private let windowPreviewPanelController = WindowPreviewPanelController()
    private let taskbarJumpListController = TaskbarJumpListController()
    private let startButtonContextMenuController = TaskbarJumpListController()
    private let startButtonPowerMenuController = TaskbarJumpListController()
    private let shortcutEditorController: ShortcutEditorController
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
        shortcutEditorController = ShortcutEditorController(preferences: preferences)
        self.recentDocuments = recentDocuments
        windowPeekController = WindowPeekController(windowsService: windowsService)
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
        windowPeekController.hideImmediately()
        windowPreviewPanelController.dismissAll()
        taskbarJumpListController.dismiss()
        startButtonContextMenuController.dismiss()
        startButtonPowerMenuController.dismiss()
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
        taskbarJumpListController.dismiss()
        startButtonContextMenuController.dismiss()
        startButtonPowerMenuController.dismiss()
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
            windowPeekController: windowPeekController,
            windowPreviewPanelController: windowPreviewPanelController,
            taskbarJumpListController: taskbarJumpListController,
            startButtonContextMenuController: startButtonContextMenuController,
            startButtonPowerMenuController: startButtonPowerMenuController,
            shortcutEditorController: shortcutEditorController,
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
final class StartMenuController: NSObject, NSWindowDelegate {
    private let preferences: PreferencesStore
    private let taskbar: TaskbarWindowController
    private let panel: NSPanel
    private let backdrop = NSView()
    private var cancellable: AnyCancellable?
    private var lastResignDate = Date.distantPast

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
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: StartMenuView(apps: apps, actions: actions, preferences: preferences))
        installContentView()
        applyAppearance()
        cancellable = preferences.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyAppearance() }
        }
    }

    func toggle(on screen: NSScreen? = nil) {
        if panel.isVisible {
            hide()
        } else {
            guard Date().timeIntervalSince(lastResignDate) >= 0.3 else { return }
            positionPanel(on: screen ?? taskbar.activeScreen)
            panel.makeKeyAndOrderFront(nil)
            applyBlur()
        }
    }

    func hide() { panel.orderOut(nil) }

    func windowDidResignKey(_ notification: Notification) {
        lastResignDate = Date()
        hide()
    }

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
    static let screenEdgeInset: CGFloat = 12
    static let taskbarGap: CGFloat = 8

    static func frame(
        screenFrame: NSRect,
        visibleFrame: NSRect,
        position: TaskbarPosition,
        barHeight: CGFloat,
        heightMode: MenuHeightMode,
        oppositeEnd: Bool
    ) -> NSRect {
        let height: CGFloat

        switch position {
        case .bottom:
            let y = screenFrame.minY + barHeight + taskbarGap
            height = heightMode == .full ? max(0, visibleFrame.maxY - y) : standardHeight
        case .top:
            height = heightMode == .full
                ? max(0, visibleFrame.maxY - barHeight - taskbarGap - visibleFrame.minY)
                : standardHeight
        case .left:
            height = heightMode == .full ? visibleFrame.height : standardHeight
        case .right:
            height = heightMode == .full ? visibleFrame.height : standardHeight
        }

        var frame = anchoredFrame(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            position: position,
            barHeight: barHeight,
            contentSize: CGSize(width: width, height: height),
            oppositeEnd: oppositeEnd,
            edgeInset: heightMode == .full ? 0 : screenEdgeInset
        )
        if heightMode == .full, !position.isHorizontal {
            frame.origin.y = visibleFrame.minY
        }
        return frame
    }

    static func anchoredFrame(
        screenFrame: NSRect,
        visibleFrame: NSRect,
        position: TaskbarPosition,
        barHeight: CGFloat,
        contentSize: CGSize,
        oppositeEnd: Bool,
        edgeInset: CGFloat = screenEdgeInset
    ) -> NSRect {
        let origin: CGPoint

        switch position {
        case .bottom:
            origin = CGPoint(
                x: oppositeEnd
                    ? screenFrame.maxX - edgeInset - contentSize.width
                    : screenFrame.minX + edgeInset,
                y: screenFrame.minY + barHeight + taskbarGap
            )
        case .top:
            origin = CGPoint(
                x: oppositeEnd
                    ? screenFrame.maxX - edgeInset - contentSize.width
                    : screenFrame.minX + edgeInset,
                y: visibleFrame.maxY - barHeight - taskbarGap - contentSize.height
            )
        case .left:
            origin = CGPoint(
                x: screenFrame.minX + barHeight + taskbarGap,
                y: oppositeEnd
                    ? screenFrame.minY + edgeInset
                    : screenFrame.maxY - edgeInset - contentSize.height
            )
        case .right:
            origin = CGPoint(
                x: screenFrame.maxX - barHeight - taskbarGap - contentSize.width,
                y: oppositeEnd
                    ? screenFrame.minY + edgeInset
                    : screenFrame.maxY - edgeInset - contentSize.height
            )
        }

        return NSRect(origin: origin, size: contentSize)
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
