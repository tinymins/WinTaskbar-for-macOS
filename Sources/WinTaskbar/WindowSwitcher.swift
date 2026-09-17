import AppKit
import ApplicationServices
import SwiftUI

struct WindowSwitcherApplicationPolicy {
    static func shouldInclude(
        activationPolicy: NSApplication.ActivationPolicy,
        isTerminated: Bool
    ) -> Bool {
        !isTerminated && activationPolicy != .prohibited
    }
}

struct WindowActivationOrder {
    private(set) var windowIDs: [CGWindowID] = []

    mutating func record(_ windowID: CGWindowID) {
        windowIDs.removeAll { $0 == windowID }
        windowIDs.insert(windowID, at: 0)
    }

    mutating func reconcile(
        availableWindowIDs: [CGWindowID],
        fallbackWindowIDs: [CGWindowID]
    ) -> [CGWindowID] {
        let available = Set(availableWindowIDs)
        windowIDs.removeAll { !available.contains($0) }
        var included = Set(windowIDs)
        for windowID in fallbackWindowIDs + availableWindowIDs where included.insert(windowID).inserted {
            windowIDs.append(windowID)
        }
        return windowIDs
    }
}

private let focusedWindowChangedCallback: AXObserverCallback = { _, element, _, context in
    guard let context else { return }
    let history = Unmanaged<WindowActivationHistory>.fromOpaque(context).takeUnretainedValue()
    var pid: pid_t = 0
    guard AXUIElementGetPid(element, &pid) == .success else { return }
    MainActor.assumeIsolated {
        history.recordFocusedWindow(forPID: pid)
    }
}

@MainActor
final class WindowActivationHistory {
    private struct Observation {
        let observer: AXObserver
        let source: CFRunLoopSource
    }

    private let workspace: NSWorkspace
    private var activationOrder = WindowActivationOrder()
    private var observations: [pid_t: Observation] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var isStarted = false

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        let center = workspace.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let pid,
                      let application = NSRunningApplication(processIdentifier: pid) else { return }
                self?.attach(to: application)
            }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let pid else { return }
                self?.detach(fromPID: pid)
            }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let pid else { return }
                self?.recordFocusedWindow(forPID: pid)
            }
        })

        for application in eligibleApplications() { attach(to: application) }
        if let frontmostApplication = workspace.frontmostApplication {
            recordFocusedWindow(forPID: frontmostApplication.processIdentifier)
        }
    }

    func orderedWindows(from frontToBackWindows: [WindowInfo]) -> [WindowInfo] {
        if let frontmostPID = workspace.frontmostApplication?.processIdentifier,
           let frontmostWindow = frontToBackWindows.first(where: { $0.ownerPID == frontmostPID }) {
            activationOrder.record(frontmostWindow.windowID)
        }
        let windowIDs = frontToBackWindows.map(\.windowID)
        let orderedIDs = activationOrder.reconcile(
            availableWindowIDs: windowIDs,
            fallbackWindowIDs: windowIDs
        )
        let windowsByID = Dictionary(uniqueKeysWithValues: frontToBackWindows.map { ($0.windowID, $0) })
        return orderedIDs.compactMap { windowsByID[$0] }
    }

    func record(_ windowID: CGWindowID) {
        activationOrder.record(windowID)
    }

    fileprivate func recordFocusedWindow(forPID pid: pid_t) {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.1)
        guard let window: AXUIElement = attribute(application, kAXFocusedWindowAttribute),
        let windowID = AccessibilityWindowIdentity.windowID(of: window) else { return }
        activationOrder.record(windowID)
    }

    private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private func eligibleApplications() -> [NSRunningApplication] {
        workspace.runningApplications.filter {
            WindowSwitcherApplicationPolicy.shouldInclude(
                activationPolicy: $0.activationPolicy,
                isTerminated: $0.isTerminated
            )
        }
    }

    private func attach(to application: NSRunningApplication) {
        let pid = application.processIdentifier
        guard WindowSwitcherApplicationPolicy.shouldInclude(
                  activationPolicy: application.activationPolicy,
                  isTerminated: application.isTerminated
              ),
              observations[pid] == nil else { return }
        var observer: AXObserver?
        guard AXObserverCreate(pid, focusedWindowChangedCallback, &observer) == .success,
              let observer else { return }
        let applicationElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(applicationElement, 0.1)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(
            observer,
            applicationElement,
            kAXFocusedWindowChangedNotification as CFString,
            context
        ) == .success else { return }
        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        observations[pid] = Observation(observer: observer, source: source)
    }

    private func detach(fromPID pid: pid_t) {
        guard let observation = observations.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), observation.source, .commonModes)
    }
}

enum WindowSwitcherLayout {
    static let tileSize = CGSize(width: 264, height: 196)
    static let spacing: CGFloat = 12
    static let panelPadding: CGFloat = 18

    static func columnCount(windowCount: Int, availableWidth: CGFloat) -> Int {
        guard windowCount > 0 else { return 1 }
        let capacity = max(1, Int((availableWidth - panelPadding * 2 + spacing)
            / (tileSize.width + spacing)))
        let preferred = max(1, Int(ceil(sqrt(Double(windowCount) * 1.4))))
        return min(windowCount, 5, capacity, preferred)
    }

    static func panelSize(windowCount: Int, screenFrame: CGRect) -> CGSize {
        let columns = columnCount(windowCount: windowCount, availableWidth: screenFrame.width * 0.88)
        let rows = Int(ceil(Double(max(1, windowCount)) / Double(columns)))
        let width = CGFloat(columns) * tileSize.width
            + CGFloat(max(0, columns - 1)) * spacing
            + panelPadding * 2
        let contentHeight = CGFloat(rows) * tileSize.height
            + CGFloat(max(0, rows - 1)) * spacing
            + panelPadding * 2
        return CGSize(width: width, height: min(contentHeight, screenFrame.height * 0.76))
    }
}

enum WindowSwitcherSelection {
    static func indexAfterRemoving(
        removedIndex: Int,
        selectedIndex: Int,
        remainingCount: Int
    ) -> Int {
        guard remainingCount > 0 else { return 0 }
        if removedIndex < selectedIndex { return selectedIndex - 1 }
        return min(selectedIndex, remainingCount - 1)
    }
}

private enum WindowSwitcherWindowAction: CaseIterable {
    case close
    case toggleMinimized
    case toggleFullScreen

    var capability: WindowControlCapabilities {
        switch self {
        case .close: .close
        case .toggleMinimized: .minimize
        case .toggleFullScreen: .fullScreen
        }
    }

    var color: Color {
        switch self {
        case .close: Color(red: 1, green: 0.37, blue: 0.34)
        case .toggleMinimized: Color(red: 1, green: 0.74, blue: 0.18)
        case .toggleFullScreen: Color(red: 0.15, green: 0.79, blue: 0.25)
        }
    }

    var systemImage: String {
        switch self {
        case .close: "xmark"
        case .toggleMinimized: "minus"
        case .toggleFullScreen: "arrow.up.left.and.arrow.down.right"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .close: "Close window"
        case .toggleMinimized: "Minimize or restore window"
        case .toggleFullScreen: "Enter or exit full screen"
        }
    }
}

private final class WindowSwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class WindowSwitcherPanelController {
    private let windowsService: WindowsService
    private let activationService: WindowActivationService
    private let activationHistory: WindowActivationHistory
    private let workspace: NSWorkspace
    private let panel: WindowSwitcherPanel
    private let backdrop = NSVisualEffectView()
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private var windows: [WindowInfo] = []
    private var thumbnails: [CGWindowID: NSImage] = [:]
    private var controlCapabilities: [CGWindowID: WindowControlCapabilities] = [:]
    private var selectedIndex = 0

    init(
        windowsService: WindowsService,
        activationService: WindowActivationService,
        activationHistory: WindowActivationHistory,
        workspace: NSWorkspace = .shared
    ) {
        self.windowsService = windowsService
        self.activationService = activationService
        self.activationHistory = activationHistory
        self.workspace = workspace
        panel = WindowSwitcherPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)

        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 12
        backdrop.layer?.masksToBounds = true
        backdrop.layer?.borderWidth = 0.5
        backdrop.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor

        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: backdrop.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
        ])
        panel.contentView = backdrop
    }

    func handle(_ action: AltTabGestureAction) {
        switch action {
        case let .present(reverse): present(reverse: reverse)
        case .advance: moveSelection(by: 1)
        case .retreat: moveSelection(by: -1)
        case .commit: commitSelection()
        case .cancel: dismiss()
        }
    }

    private func present(reverse: Bool) {
        let applications = workspace.runningApplications.filter {
            WindowSwitcherApplicationPolicy.shouldInclude(
                activationPolicy: $0.activationPolicy,
                isTerminated: $0.isTerminated
            )
        }
        let frontToBackWindows = windowsService.windowsInFrontToBackOrder(
            forPIDs: applications.map(\.processIdentifier)
        )
        windows = activationHistory.orderedWindows(from: frontToBackWindows)
        guard !windows.isEmpty else {
            dismiss()
            return
        }
        selectedIndex = reverse ? windows.count - 1 : min(1, windows.count - 1)
        thumbnails = Dictionary(uniqueKeysWithValues: windows.compactMap { window in
            windowsService.thumbnail(for: window).map { (window.windowID, $0) }
        })
        controlCapabilities = Dictionary(uniqueKeysWithValues: windows.map { window in
            (window.windowID, activationService.controlCapabilities(for: window))
        })
        refreshContent()

        let screen = screenAtMouseLocation() ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let size = WindowSwitcherLayout.panelSize(
            windowCount: windows.count,
            screenFrame: screen.visibleFrame
        )
        let frame = CGRect(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    private func moveSelection(by step: Int) {
        guard panel.isVisible, !windows.isEmpty else { return }
        selectedIndex = (selectedIndex + step + windows.count) % windows.count
        refreshContent()
    }

    private func commitSelection() {
        guard panel.isVisible, windows.indices.contains(selectedIndex) else {
            dismiss()
            return
        }
        let selectedWindow = windows[selectedIndex]
        activationHistory.record(selectedWindow.windowID)
        dismiss()
        activationService.raise(window: selectedWindow)
    }

    private func selectAndCommit(windowID: CGWindowID) {
        guard let index = windows.firstIndex(where: { $0.windowID == windowID }) else { return }
        selectedIndex = index
        commitSelection()
    }

    private func perform(_ action: WindowSwitcherWindowAction, on windowID: CGWindowID) {
        guard panel.isVisible,
              let index = windows.firstIndex(where: { $0.windowID == windowID }) else { return }
        let window = windows[index]
        switch action {
        case .close:
            guard activationService.close(window: window) else { return }
            windows.remove(at: index)
            thumbnails.removeValue(forKey: windowID)
            controlCapabilities.removeValue(forKey: windowID)
            guard !windows.isEmpty else {
                dismiss()
                return
            }
            selectedIndex = WindowSwitcherSelection.indexAfterRemoving(
                removedIndex: index,
                selectedIndex: selectedIndex,
                remainingCount: windows.count
            )
            refreshContent()
        case .toggleMinimized:
            activationService.toggleMinimized(window: window)
        case .toggleFullScreen:
            activationService.toggleFullScreen(window: window)
        }
    }

    private func refreshContent() {
        hostingView.rootView = AnyView(WindowSwitcherView(
            windows: windows,
            thumbnails: thumbnails,
            controlCapabilities: controlCapabilities,
            selectedWindowID: windows.indices.contains(selectedIndex) ? windows[selectedIndex].windowID : nil,
            onWindowAction: { [weak self] action, windowID in self?.perform(action, on: windowID) },
            onSelect: { [weak self] windowID in self?.selectAndCommit(windowID: windowID) }
        ))
    }

    private func dismiss() {
        panel.orderOut(nil)
        hostingView.rootView = AnyView(EmptyView())
        windows = []
        thumbnails = [:]
        controlCapabilities = [:]
        selectedIndex = 0
    }

    private func screenAtMouseLocation() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) }
    }
}

private struct WindowSwitcherView: View {
    let windows: [WindowInfo]
    let thumbnails: [CGWindowID: NSImage]
    let controlCapabilities: [CGWindowID: WindowControlCapabilities]
    let selectedWindowID: CGWindowID?
    let onWindowAction: (WindowSwitcherWindowAction, CGWindowID) -> Void
    let onSelect: (CGWindowID) -> Void

    var body: some View {
        GeometryReader { geometry in
            let columns = WindowSwitcherLayout.columnCount(
                windowCount: windows.count,
                availableWidth: geometry.size.width
            )
            ScrollView(.vertical) {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.fixed(WindowSwitcherLayout.tileSize.width), spacing: WindowSwitcherLayout.spacing),
                        count: columns
                    ),
                    spacing: WindowSwitcherLayout.spacing
                ) {
                    ForEach(windows) { window in
                        WindowSwitcherTile(
                            window: window,
                            thumbnail: thumbnails[window.windowID],
                            controlCapabilities: controlCapabilities[window.windowID] ?? [],
                            isSelected: selectedWindowID == window.windowID,
                            onWindowAction: { onWindowAction($0, window.windowID) },
                            action: { onSelect(window.windowID) }
                        )
                    }
                }
                .padding(WindowSwitcherLayout.panelPadding)
            }
            .scrollIndicators(.visible)
        }
        .background(Color.black.opacity(0.22))
    }
}

private struct WindowSwitcherTile: View {
    let window: WindowInfo
    let thumbnail: NSImage?
    let controlCapabilities: WindowControlCapabilities
    let isSelected: Bool
    let onWindowAction: (WindowSwitcherWindowAction) -> Void
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var availableActions: [WindowSwitcherWindowAction] {
        WindowSwitcherWindowAction.allCases.filter { controlCapabilities.contains($0.capability) }
    }

    private var controlsWidth: CGFloat {
        let count = availableActions.count
        return CGFloat(count) * 16 + CGFloat(max(0, count - 1)) * 6
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                        appIcon
                        Text(window.title)
                            .font(.system(size: 12, weight: isHovering ? .semibold : .medium))
                            .foregroundStyle(Color.white.opacity(isHovering ? 1 : 0.82))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if !availableActions.isEmpty {
                            Color.clear.frame(width: controlsWidth, height: 16)
                        }
                    }
                    .frame(height: 20)
                    preview
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(10)
                .frame(
                    width: WindowSwitcherLayout.tileSize.width,
                    height: WindowSwitcherLayout.tileSize.height
                )
                .background(Color.black.opacity(isHovering ? 0.72 : 0.64))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(
                            isSelected
                                ? Color(red: 0.12, green: 0.63, blue: 1)
                                : Color.white.opacity(isHovering ? 0.22 : 0),
                            lineWidth: isSelected ? 3 : 1
                        )
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(WindowSwitcherTileButtonStyle())
            .accessibilityLabel(window.title)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            if isHovering, !availableActions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(availableActions, id: \.self) { action in
                        WindowSwitcherControlButton(action: action) {
                            onWindowAction(action)
                        }
                    }
                }
                .padding(.top, 12)
                .padding(.trailing, 10)
            }
        }
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
    }

    @ViewBuilder
    private var preview: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .scaledToFit()
        } else {
            ZStack {
                Color.white.opacity(0.055)
                appIcon.frame(width: 52, height: 52)
            }
        }
    }

    private var appIcon: some View {
        Group {
            if let icon = NSRunningApplication(processIdentifier: window.ownerPID)?.icon {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                Image(systemName: "macwindow").resizable().scaledToFit()
            }
        }
        .frame(width: 16, height: 16)
    }
}

private struct WindowSwitcherTileButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: configuration.isPressed ? 0.06 : 0.10),
                value: configuration.isPressed
            )
    }
}

private struct WindowSwitcherControlButton: View {
    let action: WindowSwitcherWindowAction
    let perform: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: perform) {
            Image(systemName: action.systemImage)
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.66))
                .frame(width: 16, height: 16)
                .background(action.color.opacity(isHovering ? 1 : 0.9), in: Circle())
                .overlay {
                    Circle().stroke(Color.black.opacity(0.18), lineWidth: 0.5)
                }
                .contentShape(Circle())
        }
        .buttonStyle(WindowSwitcherControlButtonStyle())
        .onHover { isHovering = $0 }
        .help(action.accessibilityLabel)
        .accessibilityLabel(action.accessibilityLabel)
    }
}

private struct WindowSwitcherControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(.easeOut(duration: 0.06), value: configuration.isPressed)
    }
}
