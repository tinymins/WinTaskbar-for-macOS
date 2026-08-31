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
    var isAutoHidden = false
    var autoHideTask: Task<Void, Never>?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

enum TaskbarAutoHideGeometry {
    static let revealThickness: CGFloat = 2

    static func hiddenFrame(from shownFrame: CGRect, position: TaskbarPosition) -> CGRect {
        var frame = shownFrame
        switch position {
        case .bottom: frame.origin.y -= frame.height
        case .top: frame.origin.y += frame.height
        case .left: frame.origin.x -= frame.width
        case .right: frame.origin.x += frame.width
        }
        return frame
    }

    static func revealZone(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        position: TaskbarPosition,
        thickness: CGFloat = revealThickness
    ) -> CGRect {
        switch position {
        case .bottom:
            CGRect(x: screenFrame.minX, y: screenFrame.minY, width: screenFrame.width, height: thickness)
        case .top:
            CGRect(x: screenFrame.minX, y: visibleFrame.maxY - thickness, width: screenFrame.width, height: thickness)
        case .left:
            CGRect(x: screenFrame.minX, y: screenFrame.minY, width: thickness, height: screenFrame.height)
        case .right:
            CGRect(x: screenFrame.maxX - thickness, y: screenFrame.minY, width: thickness, height: screenFrame.height)
        }
    }
}

enum TaskbarAutoHidePolicy {
    static func shouldHide(
        isEnabled: Bool,
        pointerIsInsideTaskbar: Bool,
        hasVisibleSurface: Bool,
        hasPendingAttention: Bool,
        isMouseButtonPressed: Bool
    ) -> Bool {
        isEnabled
            && !pointerIsInsideTaskbar
            && !hasVisibleSurface
            && !hasPendingAttention
            && !isMouseButtonPressed
    }
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
    case scheduleInitial
    case keepCurrent
    case scheduleSwitch
}

struct WindowPreviewHoverIntent {
    static let initialDelayNanoseconds: UInt64 = 400_000_000
    static let switchDelayNanoseconds: UInt64 = 180_000_000

    private(set) var pendingOwnerID: WindowPreviewOwnerID?

    mutating func hover(
        activeOwnerID: WindowPreviewOwnerID?,
        candidateOwnerID: WindowPreviewOwnerID
    ) -> WindowPreviewHoverIntentDecision {
        if activeOwnerID == nil {
            pendingOwnerID = candidateOwnerID
            return .scheduleInitial
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
        targetOwnerID: WindowPreviewOwnerID,
        currentFrame: CGRect,
        targetFrame: CGRect
    ) -> Bool {
        isVisible && (displayedOwnerID != targetOwnerID || currentFrame != targetFrame)
    }
}

struct WindowPreviewPanelUpdateSequence {
    private(set) var revision: UInt = 0

    mutating func schedule() -> UInt {
        revision &+= 1
        return revision
    }

    func isCurrent(_ scheduledRevision: UInt) -> Bool {
        revision == scheduledRevision
    }

    mutating func cancel() {
        revision &+= 1
    }
}

enum WindowPreviewHostingPolicy {
    static let sizingOptions: NSHostingSizingOptions = []
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
    private var pinnedOwnerID: WindowPreviewOwnerID?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var workspaceObserver: NSObjectProtocol?
    private var panel: WindowPreviewPanel?
    private let backdrop = NSVisualEffectView()
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))

    var activeOwnerID: WindowPreviewOwnerID? { selection.activeOwnerID }
    var isPinned: Bool { pinnedOwnerID != nil }

    init() {
        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 8
        backdrop.layer?.masksToBounds = true
        backdrop.layer?.borderWidth = 0.5
        backdrop.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor

        hostingView.sizingOptions = WindowPreviewHostingPolicy.sizingOptions
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
        guard pinnedOwnerID == nil else { return }
        cancelDismissal()
        activationTask?.cancel()
        activationTask = nil

        switch hoverIntent.hover(activeOwnerID: selection.activeOwnerID, candidateOwnerID: ownerID) {
        case .scheduleInitial:
            scheduleActivation(
                ownerID: ownerID,
                delayNanoseconds: WindowPreviewHoverIntent.initialDelayNanoseconds
            )
        case .keepCurrent:
            break
        case .scheduleSwitch:
            scheduleActivation(
                ownerID: ownerID,
                delayNanoseconds: WindowPreviewHoverIntent.switchDelayNanoseconds
            )
        }
    }

    private func scheduleActivation(ownerID: WindowPreviewOwnerID, delayNanoseconds: UInt64) {
        activationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled, self?.hoverIntent.resolve(ownerID) == true else { return }
            self?.activationTask = nil
            self?.activateTransientImmediately(ownerID: ownerID)
        }
    }

    func pin(ownerID: WindowPreviewOwnerID) {
        cancelDismissal()
        activationTask?.cancel()
        activationTask = nil
        hoverIntent.reset()
        pinnedOwnerID = ownerID
        installPinnedDismissalObservers()
        activateSelection(ownerID: ownerID)
    }

    private func activateTransientImmediately(ownerID: WindowPreviewOwnerID) {
        guard pinnedOwnerID == nil else { return }
        activateSelection(ownerID: ownerID)
    }

    private func activateSelection(ownerID: WindowPreviewOwnerID) {
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
        guard pinnedOwnerID == nil else { return }
        if selection.activeOwnerID == nil {
            activationTask?.cancel()
            activationTask = nil
            hoverIntent.cancel(ownerID)
            return
        }
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
        clearPinnedState()
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
        clearPinnedState()
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
            targetOwnerID: ownerID,
            currentFrame: panel.frame,
            targetFrame: targetFrame
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

    private func installPinnedDismissalObservers() {
        removePinnedDismissalObservers()
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, self.pinnedOwnerID != nil else { return event }
            if let panel = self.panel, panel.frame.contains(NSEvent.mouseLocation) { return event }
            self.dismissAll()
            return event
        }
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.dismissAll() }
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissAll() }
        }
    }

    private func clearPinnedState() {
        pinnedOwnerID = nil
        removePinnedDismissalObservers()
    }

    private func removePinnedDismissalObservers() {
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
        if let globalEventMonitor { NSEvent.removeMonitor(globalEventMonitor) }
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        localEventMonitor = nil
        globalEventMonitor = nil
        workspaceObserver = nil
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

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let rootView = AnyView(content())
        context.coordinator.schedule {
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

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.cancel()
    }

    @MainActor
    final class Coordinator {
        private var updateSequence = WindowPreviewPanelUpdateSequence()

        func schedule(_ update: @escaping @MainActor () -> Void) {
            let scheduledRevision = updateSequence.schedule()
            DispatchQueue.main.async { [weak self] in
                guard self?.updateSequence.isCurrent(scheduledRevision) == true else { return }
                update()
            }
        }

        func cancel() {
            updateSequence.cancel()
        }
    }
}

@MainActor
final class TaskbarWindowController {
    private let preferences: PreferencesStore
    private let apps: AppDiscoveryService
    private let status: SystemStatusService
    private let externalStatusItems: ExternalStatusItemService
    private let actions: AppActions
    private let windowActivator: WindowActivationService
    private let windowsService: WindowsService
    private let windowPeekController: WindowPeekController
    private let windowPreviewPanelController = WindowPreviewPanelController()
    private let taskbarJumpListController = TaskbarJumpListController()
    private let startButtonContextMenuController = TaskbarJumpListController()
    private let startButtonPowerMenuController = TaskbarJumpListController()
    private let taskbarContextMenuController = TaskbarJumpListController()
    private let taskbarContextSubmenuController = TaskbarJumpListController()
    private let taskbarContextNestedMenuController = TaskbarJumpListController()
    private let quickSettingsPanelController = QuickSettingsPanelController()
    private let inputSourcePanelController = InputSourcePanelController()
    private let clockCalendarPanelController = ClockCalendarPanelController()
    private let externalStatusOverflowPanelController = ExternalStatusOverflowPanelController()
    private let snapLayoutsPanelController = TaskbarJumpListController()
    private let clipboardHistoryPanelController = TaskbarJumpListController()
    private let shortcutEditorController: ShortcutEditorController
    private let recentDocuments: RecentDocumentsService
    private let dockBadges: DockBadgeService
    private let activeWindowShortcuts: ActiveWindowShortcutService
    private let clipboardHistory: ClipboardHistoryService
    private let systemShortcuts: SystemShortcutService
    private var panels: [TaskbarPanel] = []
    private var cancellable: AnyCancellable?
    private var attentionCancellable: AnyCancellable?
    private var taskbarCycleIndex: Int?
    private var keepsTransientSurfacesVisibleForSettings = false
    private var isStartMenuPresented = false
    private var activeTaskbarContextSection: TaskbarContextMenuSection?
    private var activeTaskbarContextNestedSection: TaskbarContextNestedSection?
    private var taskbarTerminalEntries: [TaskbarTerminalMenuEntry] = []
    private var taskbarContextScreen: NSScreen?
    private var taskbarContextNestedFrame: CGRect?
    private var previousPointerLocation: CGPoint?
    private var currentPointerLocation: CGPoint?
    private var nestedMenuIntentTask: Task<Void, Never>?
    private var localPointerMonitor: Any?
    private var globalPointerMonitor: Any?
    private var menuTrackingObservers: [NSObjectProtocol] = []
    private var isMenuTracking = false

    private static let autoHideDelayNanoseconds: UInt64 = 400_000_000
    private static let autoHideAnimationDuration: TimeInterval = 0.18

    init(
        preferences: PreferencesStore,
        apps: AppDiscoveryService,
        status: SystemStatusService,
        externalStatusItems: ExternalStatusItemService,
        actions: AppActions,
        windowActivator: WindowActivationService,
        windowsService: WindowsService,
        recentDocuments: RecentDocumentsService,
        dockBadges: DockBadgeService,
        activeWindowShortcuts: ActiveWindowShortcutService,
        clipboardHistory: ClipboardHistoryService,
        systemShortcuts: SystemShortcutService
    ) {
        self.preferences = preferences
        self.apps = apps
        self.status = status
        self.externalStatusItems = externalStatusItems
        self.actions = actions
        self.windowActivator = windowActivator
        self.windowsService = windowsService
        shortcutEditorController = ShortcutEditorController(preferences: preferences)
        self.recentDocuments = recentDocuments
        windowPeekController = WindowPeekController(windowsService: windowsService)
        self.dockBadges = dockBadges
        self.activeWindowShortcuts = activeWindowShortcuts
        self.clipboardHistory = clipboardHistory
        self.systemShortcuts = systemShortcuts
        cancellable = preferences.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.applyLayout()
            }
        }
        attentionCancellable = dockBadges.$attentionStates
            .map { !$0.isEmpty }
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateAutoHideState()
                }
            }
        actions.toggleQuickLinkMenuHandler = { [weak self] screen in
            self?.toggleQuickLinkMenu(on: screen)
        }
        taskbarContextMenuController.onDismiss = { [weak self] in
            self?.taskbarContextSubmenuController.dismiss()
            self?.dismissTaskbarContextNestedMenu()
            self?.activeTaskbarContextSection = nil
            self?.taskbarTerminalEntries = []
            self?.taskbarContextScreen = nil
        }
        taskbarContextMenuController.preservesOutsideMouseDown = { [weak self] in
            self?.taskbarContextSubmenuController.containsMouseLocation == true
                || self?.taskbarContextNestedMenuController.containsMouseLocation == true
        }
        taskbarContextSubmenuController.onDismiss = { [weak self] in
            self?.dismissTaskbarContextNestedMenu()
            self?.activeTaskbarContextSection = nil
        }
        taskbarContextSubmenuController.preservesOutsideMouseDown = { [weak self] in
            self?.taskbarContextNestedMenuController.containsMouseLocation == true
        }
        taskbarContextNestedMenuController.onDismiss = { [weak self] in
            self?.nestedMenuIntentTask?.cancel()
            self?.nestedMenuIntentTask = nil
            self?.activeTaskbarContextNestedSection = nil
            self?.taskbarContextNestedFrame = nil
        }
        installPointerMonitors()
        installMenuTrackingObservers()
    }

    func show() {
        rebuildPanels()
    }

    func dismissTransientSurfaces() {
        windowPeekController.hideImmediately()
        windowPreviewPanelController.dismissAll()
        taskbarJumpListController.dismiss()
        startButtonContextMenuController.dismiss()
        startButtonPowerMenuController.dismiss()
        taskbarContextMenuController.dismiss()
        taskbarContextSubmenuController.dismiss()
        taskbarContextNestedMenuController.dismiss()
        quickSettingsPanelController.dismiss()
        inputSourcePanelController.dismiss()
        clockCalendarPanelController.dismiss(animated: false)
        externalStatusOverflowPanelController.dismiss()
        snapLayoutsPanelController.dismiss()
        clipboardHistoryPanelController.dismiss()
    }

    func setSettingsObservationMode(_ enabled: Bool) {
        keepsTransientSurfacesVisibleForSettings = enabled
        taskbarJumpListController.setKeepsVisibleForSettings(enabled)
        startButtonContextMenuController.setKeepsVisibleForSettings(enabled)
        startButtonPowerMenuController.setKeepsVisibleForSettings(enabled)
        taskbarContextMenuController.setKeepsVisibleForSettings(enabled)
        taskbarContextSubmenuController.setKeepsVisibleForSettings(enabled)
        taskbarContextNestedMenuController.setKeepsVisibleForSettings(enabled)
        quickSettingsPanelController.setKeepsVisibleForSettings(enabled)
        inputSourcePanelController.setKeepsVisibleForSettings(enabled)
        clockCalendarPanelController.setKeepsVisibleForSettings(enabled)
        externalStatusOverflowPanelController.setKeepsVisibleForSettings(enabled)
        snapLayoutsPanelController.setKeepsVisibleForSettings(enabled)
        clipboardHistoryPanelController.setKeepsVisibleForSettings(enabled)
    }

    func toggleQuickSettings() {
        revealTaskbar(on: activeScreen)
        quickSettingsPanelController.toggle(
            service: status,
            actions: actions,
            position: preferences.position,
            barHeight: CGFloat(preferences.barHeight),
            screen: activeScreen
        )
    }

    func toggleTaskbarContextMenu(at clickPoint: CGPoint, in taskbarWindow: NSWindow) {
        if taskbarContextMenuController.isVisible {
            dismissTaskbarContextMenus()
            return
        }

        let screen = taskbarWindow.screen ?? activeScreen
        actions.closeStartMenu()
        dismissTransientSurfaces()
        taskbarContextScreen = screen
        taskbarTerminalEntries = TaskbarTerminalCatalog.installed()
        revealTaskbar(on: screen)

        let frame = TaskbarContextMenuGeometry.rootFrame(
            clickPoint: clickPoint,
            taskbarFrame: taskbarWindow.frame,
            contentSize: TaskbarContextMenuMetrics.rootSize,
            position: preferences.position,
            screenFrame: screen.frame
        )
        let rootView = TaskbarContextMenuView(
            onShowSection: { [weak self] section in
                self?.showTaskbarContextSubmenu(
                    section,
                    parentFrame: frame,
                    screenFrame: screen.frame
                )
            },
            onCommand: { [weak self] command in
                self?.performTaskbarContextCommand(command)
            },
            onDismissSubmenu: { [weak self] in
                self?.dismissTaskbarContextSubmenu()
            }
        )
        .frame(width: frame.width, height: frame.height)
        taskbarContextMenuController.show(
            rootView: AnyView(rootView),
            frame: frame,
            appearance: taskbarWindow.appearance,
            cornerRadius: TaskbarContextMenuMetrics.cornerRadius,
            showsBorder: false
        )
    }

    func toggleQuickLinkMenu(on requestedScreen: NSScreen? = nil) {
        if startButtonContextMenuController.isVisible {
            dismissStartButtonContextMenus()
            return
        }

        actions.closeStartMenu()
        windowPreviewPanelController.dismissAll()
        windowPeekController.hideImmediately()
        taskbarJumpListController.dismiss()
        startButtonPowerMenuController.dismiss()

        let screen = requestedScreen ?? activeScreen
        revealTaskbar(on: screen)
        let frame = StartMenuGeometry.anchoredFrame(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            position: preferences.position,
            barHeight: CGFloat(preferences.barHeight),
            contentSize: StartButtonContextMenuMetrics.rootSize,
            oppositeEnd: preferences.startButtonAtEnd || preferences.menuButtonPlacement != .standard
        )
        let rootView = StartButtonContextMenuView(
            actions: actions,
            onDismiss: { [weak self] in self?.dismissStartButtonContextMenus() },
            onShowPower: { [weak self] in
                self?.showStartButtonPowerMenu(parentFrame: frame, screenFrame: screen.frame)
            }
        )
        .frame(width: frame.width, height: frame.height)

        startButtonContextMenuController.show(
            rootView: AnyView(rootView),
            frame: frame,
            appearance: appearance
        )
    }

    func toggleInputSources() {
        revealTaskbar(on: activeScreen)
        inputSourcePanelController.toggle(
            service: status,
            position: preferences.position,
            barHeight: CGFloat(preferences.barHeight),
            screen: activeScreen,
            appearance: appearance
        )
    }

    func handleWindowsSpaceGesture(_ action: WindowsSpaceGestureAction) {
        switch action {
        case .present:
            revealTaskbar(on: activeScreen)
            inputSourcePanelController.show(
                service: status,
                position: preferences.position,
                barHeight: CGFloat(preferences.barHeight),
                screen: activeScreen,
                appearance: appearance
            )
        case .advance:
            inputSourcePanelController.advance(service: status)
        case .retreat:
            inputSourcePanelController.retreat(service: status)
        case .dismiss:
            inputSourcePanelController.dismiss()
        }
    }

    func toggleCalendar() {
        revealTaskbar(on: activeScreen)
        clockCalendarPanelController.toggle(
            screen: activeScreen,
            position: preferences.position,
            barHeight: CGFloat(preferences.barHeight),
            theme: preferences.theme
        )
    }

    func toggleSnapLayouts() {
        if snapLayoutsPanelController.isVisible {
            snapLayoutsPanelController.dismiss()
            return
        }
        revealTaskbar(on: activeScreen)
        dismissTransientSurfaces()
        let size = CGSize(width: 330, height: 190)
        let frame = utilityPanelFrame(contentSize: size)
        let view = SnapLayoutsView { [weak self] placement in
            self?.snapLayoutsPanelController.dismiss()
            self?.activeWindowShortcuts.place(placement)
        }
        .frame(width: size.width, height: size.height)
        snapLayoutsPanelController.show(rootView: AnyView(view), frame: frame, appearance: appearance)
    }

    func toggleClipboardHistory() {
        if clipboardHistoryPanelController.isVisible {
            clipboardHistoryPanelController.dismiss()
            return
        }
        revealTaskbar(on: activeScreen)
        let targetApplication = NSWorkspace.shared.frontmostApplication
        dismissTransientSurfaces()
        let size = CGSize(width: 360, height: 360)
        let frame = utilityPanelFrame(contentSize: size)
        let view = ClipboardHistoryView(service: clipboardHistory) { [weak self] entry in
            guard let self else { return }
            clipboardHistory.copy(entry)
            clipboardHistoryPanelController.dismiss()
            targetApplication?.activate(options: [.activateIgnoringOtherApps])
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80)) {
                self.systemShortcuts.postPaste()
            }
        }
        .frame(width: size.width, height: size.height)
        clipboardHistoryPanelController.show(rootView: AnyView(view), frame: frame, appearance: appearance)
    }

    func cycleTaskbarApps() {
        let items = apps.taskbarItems(
            pinnedBundleIDs: preferences.pinnedBundleIDs,
            badges: dockBadges.badges,
            showFinder: preferences.showFinder
        )
        guard !items.isEmpty else { return }
        let nextIndex = ((taskbarCycleIndex ?? -1) + 1) % items.count
        taskbarCycleIndex = nextIndex
        apps.open(items[nextIndex])
    }

    func focusSystemTray() {
        toggleQuickSettings()
    }

    func rebuildPanels() {
        dismissTransientSurfaces()
        panels.forEach {
            $0.autoHideTask?.cancel()
            $0.orderOut(nil)
        }
        panels.removeAll()

        let screens = preferences.displayMode == .primary ? Array(NSScreen.screens.prefix(1)) : NSScreen.screens
        for screen in screens {
            let panel = makePanel(for: screen)
            panels.append(panel)
            panel.orderFrontRegardless()
        }
        updateAutoHideState()
    }

    func applyLayout() {
        if !keepsTransientSurfacesVisibleForSettings {
            taskbarJumpListController.dismiss()
            startButtonContextMenuController.dismiss()
            startButtonPowerMenuController.dismiss()
            taskbarContextMenuController.dismiss()
            taskbarContextSubmenuController.dismiss()
            taskbarContextNestedMenuController.dismiss()
        }
        let expectedCount = preferences.displayMode == .primary ? min(1, NSScreen.screens.count) : NSScreen.screens.count
        guard panels.count == expectedCount else {
            rebuildPanels()
            return
        }
        for (panel, screen) in zip(panels, NSScreen.screens) {
            let remainsHidden = preferences.autoHideTaskbar && panel.isAutoHidden
            panel.autoHideTask?.cancel()
            panel.autoHideTask = nil
            let targetFrame = frame(for: screen)
            if remainsHidden {
                panel.setFrame(
                    TaskbarAutoHideGeometry.hiddenFrame(
                        from: targetFrame,
                        position: preferences.position
                    ),
                    display: false
                )
                panel.orderOut(nil)
            } else {
                panel.isAutoHidden = false
                panel.orderFrontRegardless()
                panel.setFrame(targetFrame, display: true, animate: false)
            }
            applyAppearance(to: panel)
        }
        updateAutoHideState()
    }

    func setStartMenuPresented(_ isPresented: Bool, on screen: NSScreen? = nil) {
        isStartMenuPresented = isPresented
        if isPresented {
            revealTaskbar(on: screen ?? activeScreen)
        } else {
            updateAutoHideState()
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
            externalStatusItems: externalStatusItems,
            actions: actions,
            dockBadges: dockBadges,
            windowActivator: windowActivator,
            windowsService: windowsService,
            windowPeekController: windowPeekController,
            windowPreviewPanelController: windowPreviewPanelController,
            taskbarJumpListController: taskbarJumpListController,
            startButtonContextMenuController: startButtonContextMenuController,
            startButtonPowerMenuController: startButtonPowerMenuController,
            quickSettingsPanelController: quickSettingsPanelController,
            inputSourcePanelController: inputSourcePanelController,
            clockCalendarPanelController: clockCalendarPanelController,
            externalStatusOverflowPanelController: externalStatusOverflowPanelController,
            shortcutEditorController: shortcutEditorController,
            recentDocuments: recentDocuments,
            screen: screen,
            showTaskbarContextMenu: { [weak self] point, window in
                self?.toggleTaskbarContextMenu(at: point, in: window)
            }
        ))
        applyAppearance(to: panel)
        return panel
    }

    private func installPointerMonitors() {
        let events: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .leftMouseDown,
            .rightMouseDown,
            .leftMouseUp,
            .rightMouseUp,
        ]
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated {
                self?.recordPointerLocation()
                self?.updateAutoHideState()
            }
            return event
        }
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            Task { @MainActor in
                self?.recordPointerLocation()
                self?.updateAutoHideState()
            }
        }
    }

    private func recordPointerLocation() {
        previousPointerLocation = currentPointerLocation
        currentPointerLocation = NSEvent.mouseLocation
        if let taskbarContextNestedFrame,
           taskbarContextNestedFrame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation) {
            nestedMenuIntentTask?.cancel()
            nestedMenuIntentTask = nil
        }
    }

    private func installMenuTrackingObservers() {
        menuTrackingObservers = [
            NotificationCenter.default.addObserver(
                forName: NSMenu.didBeginTrackingNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isMenuTracking = true
                    self?.revealTaskbar(on: self?.activeScreen ?? NSScreen.main ?? NSScreen.screens[0])
                }
            },
            NotificationCenter.default.addObserver(
                forName: NSMenu.didEndTrackingNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isMenuTracking = false
                    self?.updateAutoHideState()
                }
            },
        ]
    }

    private func updateAutoHideState() {
        guard preferences.autoHideTaskbar else {
            for (panel, screen) in zip(panels, selectedScreens) {
                show(panel, on: screen, animated: panel.isAutoHidden)
            }
            return
        }

        let pointer = NSEvent.mouseLocation
        let isMouseButtonPressed = NSEvent.pressedMouseButtons != 0
        let hasPendingAttention = !dockBadges.attentionStates.isEmpty
        for (panel, screen) in zip(panels, selectedScreens) {
            if hasPendingAttention {
                show(panel, on: screen, animated: true)
                continue
            }

            let revealZone = TaskbarAutoHideGeometry.revealZone(
                screenFrame: screen.frame,
                visibleFrame: screen.visibleFrame,
                position: preferences.position
            )
            if revealZone.contains(pointer) {
                show(panel, on: screen, animated: true)
                continue
            }

            let pointerIsInsideTaskbar = !panel.isAutoHidden && panel.frame.contains(pointer)
            if TaskbarAutoHidePolicy.shouldHide(
                isEnabled: true,
                pointerIsInsideTaskbar: pointerIsInsideTaskbar,
                hasVisibleSurface: hasVisibleTransientSurface,
                hasPendingAttention: hasPendingAttention,
                isMouseButtonPressed: isMouseButtonPressed
            ) {
                scheduleHide(panel, on: screen)
            } else {
                panel.autoHideTask?.cancel()
                panel.autoHideTask = nil
            }
        }
    }

    private func scheduleHide(_ panel: TaskbarPanel, on screen: NSScreen) {
        guard !panel.isAutoHidden, panel.autoHideTask == nil else { return }
        panel.autoHideTask = Task { @MainActor [weak self, weak panel, weak screen] in
            try? await Task.sleep(nanoseconds: Self.autoHideDelayNanoseconds)
            guard !Task.isCancelled, let self, let panel, let screen else { return }
            panel.autoHideTask = nil
            let pointer = NSEvent.mouseLocation
            guard TaskbarAutoHidePolicy.shouldHide(
                isEnabled: self.preferences.autoHideTaskbar,
                pointerIsInsideTaskbar: panel.frame.contains(pointer),
                hasVisibleSurface: self.hasVisibleTransientSurface,
                hasPendingAttention: !self.dockBadges.attentionStates.isEmpty,
                isMouseButtonPressed: NSEvent.pressedMouseButtons != 0
            ) else { return }
            self.hide(panel, on: screen)
        }
    }

    private func show(_ panel: TaskbarPanel, on screen: NSScreen, animated: Bool) {
        panel.autoHideTask?.cancel()
        panel.autoHideTask = nil
        let targetFrame = frame(for: screen)
        guard panel.isAutoHidden || !panel.isVisible || panel.frame != targetFrame else { return }
        if !panel.isVisible {
            panel.setFrame(
                TaskbarAutoHideGeometry.hiddenFrame(from: targetFrame, position: preferences.position),
                display: false
            )
            panel.orderFrontRegardless()
        }
        panel.isAutoHidden = false
        animate(panel, to: targetFrame, animated: animated)
    }

    private func hide(_ panel: TaskbarPanel, on screen: NSScreen) {
        guard preferences.autoHideTaskbar, !panel.isAutoHidden else { return }
        panel.isAutoHidden = true
        let hiddenFrame = TaskbarAutoHideGeometry.hiddenFrame(
            from: frame(for: screen),
            position: preferences.position
        )
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? 0
                : Self.autoHideAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(hiddenFrame, display: true)
        } completionHandler: { [weak panel] in
            Task { @MainActor in
                guard panel?.isAutoHidden == true else { return }
                panel?.orderOut(nil)
            }
        }
    }

    private func revealTaskbar(on screen: NSScreen) {
        guard let index = selectedScreens.firstIndex(of: screen), panels.indices.contains(index) else { return }
        show(panels[index], on: screen, animated: true)
    }

    private func animate(_ panel: TaskbarPanel, to frame: CGRect, animated: Bool) {
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.autoHideAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private var selectedScreens: [NSScreen] {
        preferences.displayMode == .primary ? Array(NSScreen.screens.prefix(1)) : NSScreen.screens
    }

    private var hasVisibleTransientSurface: Bool {
        isStartMenuPresented
            || isMenuTracking
            || windowPreviewPanelController.activeOwnerID != nil
            || taskbarJumpListController.isVisible
            || startButtonContextMenuController.isVisible
            || startButtonPowerMenuController.isVisible
            || taskbarContextMenuController.isVisible
            || taskbarContextSubmenuController.isVisible
            || taskbarContextNestedMenuController.isVisible
            || quickSettingsPanelController.isVisible
            || inputSourcePanelController.isVisible
            || clockCalendarPanelController.isVisible
            || externalStatusOverflowPanelController.isVisible
            || snapLayoutsPanelController.isVisible
            || clipboardHistoryPanelController.isVisible
            || WindowsTrayDragSessionState.shared.draggedItemID != nil
    }

    private func applyAppearance(to panel: NSPanel) {
        panel.appearance = appearance
        WindowBlur.apply(
            radius: preferences.transparencyEnabled ? Int(preferences.panelBlurRadius.rounded()) : 0,
            to: panel
        )
    }

    private func showStartButtonPowerMenu(parentFrame: CGRect, screenFrame: CGRect) {
        let frame = StartButtonPowerMenuGeometry.frame(
            parentFrame: parentFrame,
            contentSize: StartButtonContextMenuMetrics.powerSize,
            screenFrame: screenFrame
        )
        let rootView = StartButtonPowerMenuView(
            actions: actions,
            onDismiss: { [weak self] in self?.dismissStartButtonContextMenus() }
        )
        .frame(width: frame.width, height: frame.height)
        startButtonPowerMenuController.show(
            rootView: AnyView(rootView),
            frame: frame,
            appearance: appearance
        )
    }

    private func showTaskbarContextSubmenu(
        _ section: TaskbarContextMenuSection,
        parentFrame: CGRect,
        screenFrame: CGRect
    ) {
        guard activeTaskbarContextSection != section || !taskbarContextSubmenuController.isVisible else {
            return
        }
        dismissTaskbarContextNestedMenu()
        activeTaskbarContextSection = section
        let titles = section.submenuTitles(terminals: taskbarTerminalEntries)
        let size = TaskbarContextMenuMetrics.submenuSize(
            titles: titles,
            dividerCount: section.submenuDividerCount,
            hasTrailingChevron: section.hasNestedSubmenu
        )
        let frame = TaskbarContextMenuGeometry.submenuFrame(
            parentFrame: parentFrame,
            rowIndex: section.rowIndex,
            contentSize: size,
            screenFrame: screenFrame
        )
        let submenu = TaskbarContextSubmenuView(
            section: section,
            terminals: taskbarTerminalEntries,
            actions: actions,
            onShowNested: { [weak self] nestedSection in
                self?.showTaskbarContextNestedMenu(
                    nestedSection,
                    parentFrame: frame,
                    screenFrame: screenFrame
                )
            },
            onDismissNested: { [weak self] in
                self?.requestTaskbarContextNestedMenuDismissal()
            },
            onWindowCommand: { [weak self] command in
                self?.performTaskbarContextWindowCommand(command)
            },
            onDismiss: { [weak self] in
                self?.dismissTaskbarContextMenus()
            }
        )
        .frame(width: size.width, height: size.height)
        taskbarContextSubmenuController.show(
            rootView: AnyView(submenu),
            frame: frame,
            appearance: appearance,
            cornerRadius: TaskbarContextMenuMetrics.cornerRadius,
            showsBorder: false,
            makesKey: false
        )
    }

    private func showTaskbarContextNestedMenu(
        _ section: TaskbarContextNestedSection,
        parentFrame: CGRect,
        screenFrame: CGRect
    ) {
        nestedMenuIntentTask?.cancel()
        nestedMenuIntentTask = nil
        guard activeTaskbarContextNestedSection != section
                || !taskbarContextNestedMenuController.isVisible else { return }
        activeTaskbarContextNestedSection = section
        let size = TaskbarContextMenuMetrics.submenuSize(
            titles: section.titles,
            dividerCount: section.dividerCount
        )
        let frame = TaskbarContextMenuGeometry.submenuFrame(
            parentFrame: parentFrame,
            rowIndex: section.rowIndex,
            contentSize: size,
            screenFrame: screenFrame
        )
        taskbarContextNestedFrame = frame
        let view = TaskbarContextNestedMenuView(
            section: section,
            actions: actions,
            onDismiss: { [weak self] in self?.dismissTaskbarContextMenus() }
        )
        .frame(width: size.width, height: size.height)
        taskbarContextNestedMenuController.show(
            rootView: AnyView(view),
            frame: frame,
            appearance: appearance,
            cornerRadius: TaskbarContextMenuMetrics.cornerRadius,
            showsBorder: false,
            makesKey: false
        )
    }

    private func requestTaskbarContextNestedMenuDismissal() {
        guard taskbarContextNestedMenuController.isVisible,
              let taskbarContextNestedFrame else { return }
        nestedMenuIntentTask?.cancel()
        if let previousPointerLocation,
           let currentPointerLocation,
           TaskbarSubmenuPointerIntent.isMovingTowardSubmenu(
               previous: previousPointerLocation,
               current: currentPointerLocation,
               submenuFrame: taskbarContextNestedFrame
           ) {
            nestedMenuIntentTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 180_000_000)
                guard !Task.isCancelled else { return }
                self?.dismissTaskbarContextNestedMenu()
            }
        } else {
            dismissTaskbarContextNestedMenu()
        }
    }

    private func performTaskbarContextWindowCommand(_ command: TaskbarWindowMenuCommand) {
        let screen = taskbarContextScreen
        dismissTaskbarContextMenus()
        switch command {
        case .cascade: actions.arrangeWindows(.cascade, on: screen)
        case .stacked: actions.arrangeWindows(.stacked, on: screen)
        case .sideBySide: actions.arrangeWindows(.sideBySide, on: screen)
        case .minimizeAll: actions.minimizeAllWindows(on: screen)
        case .restoreAll: actions.restoreAllWindows()
        }
    }

    private func performTaskbarContextCommand(_ command: TaskbarContextMenuCommand) {
        dismissTaskbarContextMenus()
        switch command {
        case .desktop: actions.showDesktop()
        case .settings: actions.open(.systemSettings)
        case .taskManager: actions.open(.activityMonitor)
        case .taskbarSettings: actions.openSettings(page: .taskbar)
        }
    }

    private func dismissTaskbarContextMenus() {
        taskbarContextMenuController.dismiss()
        taskbarContextSubmenuController.dismiss()
        dismissTaskbarContextNestedMenu()
        activeTaskbarContextSection = nil
        taskbarTerminalEntries = []
        taskbarContextScreen = nil
    }

    private func dismissTaskbarContextSubmenu() {
        taskbarContextSubmenuController.dismiss()
        dismissTaskbarContextNestedMenu()
        activeTaskbarContextSection = nil
    }

    private func dismissTaskbarContextNestedMenu() {
        nestedMenuIntentTask?.cancel()
        nestedMenuIntentTask = nil
        taskbarContextNestedMenuController.dismiss()
        activeTaskbarContextNestedSection = nil
        taskbarContextNestedFrame = nil
    }

    private func dismissStartButtonContextMenus() {
        startButtonPowerMenuController.dismiss()
        startButtonContextMenuController.dismiss()
    }

    private func utilityPanelFrame(contentSize: CGSize) -> CGRect {
        let screen = activeScreen
        return StartMenuGeometry.anchoredFrame(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            position: preferences.position,
            barHeight: CGFloat(preferences.barHeight),
            contentSize: contentSize,
            oppositeEnd: true
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
    private var isPresented = false
    private var targetFrame: NSRect?
    private var orderOutTask: Task<Void, Never>?
    private var keepsVisibleForSettings = false

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
        if isPresented {
            hide()
        } else {
            guard Date().timeIntervalSince(lastResignDate) >= 0.3 else { return }
            show(on: screen ?? taskbar.activeScreen)
        }
    }

    private func show(on screen: NSScreen) {
        orderOutTask?.cancel()
        orderOutTask = nil
        isPresented = true
        taskbar.dismissTransientSurfaces()
        taskbar.setStartMenuPresented(true, on: screen)

        let finalFrame = frame(on: screen)
        targetFrame = finalFrame
        if !panel.isVisible {
            panel.setFrame(
                StartMenuMotion.dismissedFrame(from: finalFrame, position: preferences.position),
                display: false
            )
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
        }
        applyBlur()

        animateFrame(
            to: finalFrame,
            duration: StartMenuMotion.entranceDuration,
            timingFunction: StartMenuMotion.entranceTimingFunction()
        )
        animateAlpha(to: 1)
    }

    func hide() {
        guard isPresented else { return }
        isPresented = false
        taskbar.setStartMenuPresented(false)
        guard panel.isVisible, let targetFrame else {
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }

        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? StartMenuMotion.fadeDuration
            : StartMenuMotion.exitDuration
        animateFrame(
            to: StartMenuMotion.dismissedFrame(from: targetFrame, position: preferences.position),
            duration: duration,
            timingFunction: StartMenuMotion.exitTimingFunction()
        )
        animateAlpha(to: 0)

        orderOutTask?.cancel()
        orderOutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled, self?.isPresented == false else { return }
            self?.panel.orderOut(nil)
            self?.panel.setFrame(targetFrame, display: false)
            self?.panel.alphaValue = 1
        }
    }

    func setSettingsObservationMode(_ enabled: Bool) {
        keepsVisibleForSettings = enabled
        if !enabled, isPresented, !panel.isKeyWindow {
            hide()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        lastResignDate = Date()
        if !keepsVisibleForSettings { hide() }
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

    private func frame(on screen: NSScreen) -> NSRect {
        StartMenuGeometry.frame(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            position: preferences.position,
            barHeight: CGFloat(preferences.barHeight),
            heightMode: preferences.menuHeightMode,
            oppositeEnd: preferences.startButtonAtEnd || preferences.menuButtonPlacement != .standard
        )
    }

    private func animateFrame(
        to frame: NSRect,
        duration: TimeInterval,
        timingFunction: CAMediaTimingFunction
    ) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = timingFunction
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func animateAlpha(to alphaValue: CGFloat) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = StartMenuMotion.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .linear)
            panel.animator().alphaValue = alphaValue
        }
    }
}

struct StartMenuMotion {
    static let travel: CGFloat = 16
    static let entranceDuration: TimeInterval = 0.25
    static let exitDuration: TimeInterval = 0.167
    static let fadeDuration: TimeInterval = 0.083

    static func dismissedFrame(from frame: NSRect, position: TaskbarPosition) -> NSRect {
        var dismissed = frame
        switch position {
        case .bottom: dismissed.origin.y -= travel
        case .top: dismissed.origin.y += travel
        case .left: dismissed.origin.x -= travel
        case .right: dismissed.origin.x += travel
        }
        return dismissed
    }

    static func entranceTimingFunction() -> CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0, 0, 0, 1)
    }

    static func exitTimingFunction() -> CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 1, 0, 1, 1)
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
    var onVisibilityChanged: ((Bool) -> Void)?
    private let navigation = SettingsNavigationState()

    init(preferences: PreferencesStore) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "WinTaskbar Settings"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 540)
        window.contentView = NSHostingView(rootView: SettingsView(
            preferences: preferences,
            navigation: navigation
        ))
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func show(page: SettingsPage? = nil) {
        if let page { navigation.selectedPage = page }
        onVisibilityChanged?(true)
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onVisibilityChanged?(false)
    }
}
