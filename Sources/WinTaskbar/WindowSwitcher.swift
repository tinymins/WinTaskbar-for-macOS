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
    static let titleBarHeight: CGFloat = 40
    static let previewHeight: CGFloat = 156
    static let tileHeight = titleBarHeight + previewHeight
    static let minimumTileWidth: CGFloat = 160
    static let maximumTileWidth: CGFloat = 320
    static let fallbackTileWidth: CGFloat = 264
    static let spacing: CGFloat = 12
    static let panelPadding: CGFloat = 18

    static func tileWidth(for windowFrame: CGRect) -> CGFloat {
        guard windowFrame.width > 0, windowFrame.height > 0 else { return fallbackTileWidth }
        return min(
            maximumTileWidth,
            max(minimumTileWidth, (previewHeight * windowFrame.width / windowFrame.height).rounded())
        )
    }

    static func rowIndices(itemWidths: [CGFloat], maximumWidth: CGFloat) -> [[Int]] {
        guard !itemWidths.isEmpty else { return [] }
        var rows: [[Int]] = []
        var currentRow: [Int] = []
        var currentWidth: CGFloat = 0
        for (index, width) in itemWidths.enumerated() {
            let proposedWidth = currentRow.isEmpty ? width : currentWidth + spacing + width
            if !currentRow.isEmpty, proposedWidth > maximumWidth {
                rows.append(currentRow)
                currentRow = [index]
                currentWidth = width
            } else {
                currentRow.append(index)
                currentWidth = proposedWidth
            }
        }
        if !currentRow.isEmpty { rows.append(currentRow) }
        return rows
    }

    static func panelSize(windowFrames: [CGRect], screenFrame: CGRect) -> CGSize {
        let itemWidths = windowFrames.map(tileWidth)
        let maximumContentWidth = max(
            minimumTileWidth,
            screenFrame.width * 0.88 - panelPadding * 2
        )
        let rows = rowIndices(itemWidths: itemWidths, maximumWidth: maximumContentWidth)
        let contentWidth = rows.map { row in
            row.reduce(CGFloat.zero) { $0 + itemWidths[$1] }
                + CGFloat(max(0, row.count - 1)) * spacing
        }.max() ?? minimumTileWidth
        let contentHeight = CGFloat(max(1, rows.count)) * tileHeight
            + CGFloat(max(0, rows.count - 1)) * spacing
        return CGSize(
            width: contentWidth + panelPadding * 2,
            height: min(contentHeight + panelPadding * 2, screenFrame.height * 0.76)
        )
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
    private var closableWindowIDs: Set<CGWindowID> = []
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

        backdrop.material = .underWindowBackground
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 8
        backdrop.layer?.masksToBounds = true
        backdrop.layer?.borderWidth = 1
        backdrop.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor

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
        closableWindowIDs = Set(windows.filter(activationService.canClose).map(\.windowID))
        refreshContent()

        let screen = screenAtMouseLocation() ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        updatePanelFrame(on: screen)
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

    private func close(windowID: CGWindowID) {
        guard panel.isVisible,
              let index = windows.firstIndex(where: { $0.windowID == windowID }) else { return }
        let window = windows[index]
        guard activationService.close(window: window) else { return }
        windows.remove(at: index)
        thumbnails.removeValue(forKey: windowID)
        closableWindowIDs.remove(windowID)
        guard !windows.isEmpty else {
            dismiss()
            return
        }
        selectedIndex = WindowSwitcherSelection.indexAfterRemoving(
            removedIndex: index,
            selectedIndex: selectedIndex,
            remainingCount: windows.count
        )
        if let screen = panel.screen { updatePanelFrame(on: screen) }
        refreshContent()
    }

    private func refreshContent() {
        hostingView.rootView = AnyView(WindowSwitcherView(
            windows: windows,
            thumbnails: thumbnails,
            closableWindowIDs: closableWindowIDs,
            selectedWindowID: windows.indices.contains(selectedIndex) ? windows[selectedIndex].windowID : nil,
            onClose: { [weak self] windowID in self?.close(windowID: windowID) },
            onSelect: { [weak self] windowID in self?.selectAndCommit(windowID: windowID) }
        ))
    }

    private func dismiss() {
        panel.orderOut(nil)
        hostingView.rootView = AnyView(EmptyView())
        windows = []
        thumbnails = [:]
        closableWindowIDs = []
        selectedIndex = 0
    }

    private func updatePanelFrame(on screen: NSScreen) {
        let size = WindowSwitcherLayout.panelSize(
            windowFrames: windows.map(\.frame),
            screenFrame: screen.visibleFrame
        )
        panel.setFrame(CGRect(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        ), display: true)
    }

    private func screenAtMouseLocation() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) }
    }
}

private struct WindowSwitcherView: View {
    let windows: [WindowInfo]
    let thumbnails: [CGWindowID: NSImage]
    let closableWindowIDs: Set<CGWindowID>
    let selectedWindowID: CGWindowID?
    let onClose: (CGWindowID) -> Void
    let onSelect: (CGWindowID) -> Void

    var body: some View {
        ScrollView(.vertical) {
            WindowSwitcherFlowLayout(spacing: WindowSwitcherLayout.spacing) {
                ForEach(windows) { window in
                    WindowSwitcherTile(
                        window: window,
                        thumbnail: thumbnails[window.windowID],
                        canClose: closableWindowIDs.contains(window.windowID),
                        isSelected: selectedWindowID == window.windowID,
                        closeAction: { onClose(window.windowID) },
                        action: { onSelect(window.windowID) }
                    )
                }
            }
            .padding(WindowSwitcherLayout.panelPadding)
        }
        .scrollIndicators(.visible)
        .background(Color(red: 0.12, green: 0.12, blue: 0.13).opacity(0.88))
    }
}

private struct WindowSwitcherFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        guard !sizes.isEmpty else { return .zero }
        let naturalWidth = sizes.reduce(CGFloat.zero) { $0 + $1.width }
            + CGFloat(max(0, sizes.count - 1)) * spacing
        let width = proposal.width ?? naturalWidth
        let rows = WindowSwitcherLayout.rowIndices(
            itemWidths: sizes.map(\.width),
            maximumWidth: width
        )
        let height = rows.reduce(CGFloat.zero) { partial, row in
            partial + (row.map { sizes[$0].height }.max() ?? 0)
        } + CGFloat(max(0, rows.count - 1)) * spacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let rows = WindowSwitcherLayout.rowIndices(
            itemWidths: sizes.map(\.width),
            maximumWidth: bounds.width
        )
        var y = bounds.minY
        for row in rows {
            let rowWidth = row.reduce(CGFloat.zero) { $0 + sizes[$1].width }
                + CGFloat(max(0, row.count - 1)) * spacing
            let rowHeight = row.map { sizes[$0].height }.max() ?? 0
            var x = bounds.midX - rowWidth / 2
            for index in row {
                let size = sizes[index]
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: size.width, height: size.height)
                )
                x += size.width + spacing
            }
            y += rowHeight + spacing
        }
    }
}

private struct WindowSwitcherTile: View {
    let window: WindowInfo
    let thumbnail: NSImage?
    let canClose: Bool
    let isSelected: Bool
    let closeAction: () -> Void
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: action) {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        appIcon
                        Text(window.title)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(Color.white.opacity(isHovering ? 1 : 0.88))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if canClose {
                            Color.clear.frame(width: WindowSwitcherLayout.titleBarHeight)
                        }
                    }
                    .padding(.leading, 10)
                    .frame(height: WindowSwitcherLayout.titleBarHeight)
                    .background(Color.white.opacity(isHovering ? 0.085 : 0.045))
                    preview
                }
                .frame(
                    width: WindowSwitcherLayout.tileWidth(for: window.frame),
                    height: WindowSwitcherLayout.tileHeight
                )
                .background(Color(red: 0.08, green: 0.08, blue: 0.085))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            isSelected
                                ? Color(red: 0.20, green: 0.70, blue: 1)
                                : Color.white.opacity(isHovering ? 0.18 : 0),
                            lineWidth: isSelected ? 3 : 1
                        )
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(WindowSwitcherTileButtonStyle())
            .accessibilityLabel(window.title)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            if isHovering, canClose {
                WindowSwitcherCloseButton(action: closeAction)
            }
        }
        .frame(
            width: WindowSwitcherLayout.tileWidth(for: window.frame),
            height: WindowSwitcherLayout.tileHeight
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
    }

    @ViewBuilder
    private var preview: some View {
        if let thumbnail {
            ZStack {
                Color(red: 0.055, green: 0.055, blue: 0.06)
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFit()
            }
            .frame(
                width: WindowSwitcherLayout.tileWidth(for: window.frame),
                height: WindowSwitcherLayout.previewHeight
            )
            .clipped()
        } else {
            ZStack {
                Color(red: 0.055, green: 0.055, blue: 0.06)
                appIcon.frame(width: 48, height: 48)
            }
            .frame(
                width: WindowSwitcherLayout.tileWidth(for: window.frame),
                height: WindowSwitcherLayout.previewHeight
            )
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

private struct WindowSwitcherCloseButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color.white)
                .frame(
                    width: WindowSwitcherLayout.titleBarHeight,
                    height: WindowSwitcherLayout.titleBarHeight
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(WindowSwitcherCloseButtonStyle())
        .help("Close window")
        .accessibilityLabel("Close window")
    }
}

private struct WindowSwitcherCloseButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Color(red: 0.82, green: 0.04, blue: 0.10)
                    .opacity(configuration.isPressed ? 0.72 : 1)
            )
            .animation(.easeOut(duration: 0.06), value: configuration.isPressed)
    }
}
