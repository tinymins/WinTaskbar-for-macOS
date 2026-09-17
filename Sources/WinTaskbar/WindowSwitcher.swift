import AppKit
import ApplicationServices
import CoreImage
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
    static let minimumPreviewHeight: CGFloat = 92
    static let maximumPreviewHeight: CGFloat = 320
    static let previewHeightStep: CGFloat = 4
    static let tileHeight = titleBarHeight + previewHeight
    static let minimumTileWidth: CGFloat = 160
    static let maximumTileWidth: CGFloat = 320
    static let fallbackTileWidth: CGFloat = 264
    static let spacing: CGFloat = 12
    static let panelPadding: CGFloat = 18
    static let maximumPanelWidthRatio: CGFloat = 0.88
    static let maximumPanelHeightRatio: CGFloat = 0.76
    static let maximumFullyVisibleRows = 5
    static let captionButtonWidth: CGFloat = 26
    static let compactControlStripWidth = captionButtonWidth * 3
    static let scrollIndicatorWidth: CGFloat = 3

    struct Metrics {
        let previewHeight: CGFloat
        let itemWidths: [CGFloat]
        let rows: [[Int]]
        let panelSize: CGSize
    }

    static func tileHeight(for previewHeight: CGFloat) -> CGFloat {
        titleBarHeight + previewHeight
    }

    static func tileWidth(
        for windowFrame: CGRect,
        previewHeight: CGFloat = previewHeight
    ) -> CGFloat {
        let scale = previewHeight / Self.previewHeight
        let maximumWidth = (maximumTileWidth * scale).rounded()
        let fallbackWidth = (fallbackTileWidth * scale).rounded()
        guard windowFrame.width > 0, windowFrame.height > 0 else { return fallbackWidth }
        return min(
            maximumWidth,
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

    static func metrics(windowFrames: [CGRect], screenFrame: CGRect) -> Metrics {
        let maximumContentWidth = max(
            minimumTileWidth,
            screenFrame.width * maximumPanelWidthRatio - panelPadding * 2
        )
        let maximumPanelHeight = screenFrame.height * maximumPanelHeightRatio
        let screenLimitedMaximumPreviewHeight = max(
            minimumPreviewHeight,
            maximumPanelHeight - panelPadding * 2 - titleBarHeight
        )
        let largestPreviewHeight = min(maximumPreviewHeight, screenLimitedMaximumPreviewHeight)
        let baselinePreviewHeight = min(previewHeight, largestPreviewHeight)

        func geometry(for candidatePreviewHeight: CGFloat) -> (
            itemWidths: [CGFloat],
            rows: [[Int]],
            contentHeight: CGFloat
        ) {
            let itemWidths = windowFrames.map {
                tileWidth(for: $0, previewHeight: candidatePreviewHeight)
            }
            let rows = rowIndices(itemWidths: itemWidths, maximumWidth: maximumContentWidth)
            let rowCount = max(1, rows.count)
            let contentHeight = CGFloat(rowCount) * Self.tileHeight(for: candidatePreviewHeight)
                + CGFloat(max(0, rowCount - 1)) * spacing
            return (itemWidths, rows, contentHeight)
        }

        let baseline = geometry(for: baselinePreviewHeight)
        let maximumContentHeight = maximumPanelHeight - panelPadding * 2
        var selectedPreviewHeight = baselinePreviewHeight

        if baseline.contentHeight <= maximumContentHeight {
            let baselineRowCount = baseline.rows.count
            var candidatePreviewHeight = baselinePreviewHeight + previewHeightStep
            while candidatePreviewHeight <= largestPreviewHeight {
                let candidate = geometry(for: candidatePreviewHeight)
                guard candidate.rows.count == baselineRowCount,
                      candidate.contentHeight <= maximumContentHeight else { break }
                selectedPreviewHeight = candidatePreviewHeight
                candidatePreviewHeight += previewHeightStep
            }
        } else {
            var candidatePreviewHeight = baselinePreviewHeight - previewHeightStep
            selectedPreviewHeight = minimumPreviewHeight
            while candidatePreviewHeight >= minimumPreviewHeight {
                let candidate = geometry(for: candidatePreviewHeight)
                if candidate.contentHeight <= maximumContentHeight {
                    selectedPreviewHeight = candidatePreviewHeight
                    break
                }
                candidatePreviewHeight -= previewHeightStep
            }
        }

        let selected = geometry(for: selectedPreviewHeight)
        let rows = selected.rows
        let itemWidths = selected.itemWidths
        let contentWidth = rows.map { row in
            row.reduce(CGFloat.zero) { $0 + itemWidths[$1] }
                + CGFloat(max(0, row.count - 1)) * spacing
        }.max() ?? minimumTileWidth
        let tileHeight = Self.tileHeight(for: selectedPreviewHeight)
        let overflowPeekHeight = CGFloat(maximumFullyVisibleRows) * tileHeight
            + CGFloat(maximumFullyVisibleRows) * spacing
            + titleBarHeight
        let visibleContentHeight = rows.count > maximumFullyVisibleRows
            ? min(selected.contentHeight, overflowPeekHeight)
            : selected.contentHeight
        return Metrics(
            previewHeight: selectedPreviewHeight,
            itemWidths: itemWidths,
            rows: rows,
            panelSize: CGSize(
                width: contentWidth + panelPadding * 2,
                height: min(visibleContentHeight + panelPadding * 2, maximumPanelHeight)
            )
        )
    }

    static func panelSize(windowFrames: [CGRect], screenFrame: CGRect) -> CGSize {
        metrics(windowFrames: windowFrames, screenFrame: screenFrame).panelSize
    }

    static func workArea(
        visibleFrame: CGRect,
        taskbarPosition: TaskbarPosition,
        taskbarThickness: CGFloat,
        reservesTaskbar: Bool
    ) -> CGRect {
        guard reservesTaskbar else { return visibleFrame }
        var workArea = visibleFrame
        switch taskbarPosition {
        case .bottom:
            let thickness = min(max(0, taskbarThickness), workArea.height)
            workArea.origin.y += thickness
            workArea.size.height -= thickness
        case .top:
            workArea.size.height -= min(max(0, taskbarThickness), workArea.height)
        case .left:
            let thickness = min(max(0, taskbarThickness), workArea.width)
            workArea.origin.x += thickness
            workArea.size.width -= thickness
        case .right:
            workArea.size.width -= min(max(0, taskbarThickness), workArea.width)
        }
        return workArea
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

enum WindowSwitcherWindowList {
    static let detailedCacheLifetime: TimeInterval = 10

    static func initialWindows(
        visibleWindows: [WindowInfo],
        cachedWindows: [WindowInfo],
        activePIDs: Set<pid_t>,
        usesDetailedCache: Bool
    ) -> [WindowInfo] {
        guard usesDetailedCache else { return visibleWindows }
        var windowIDs = Set(visibleWindows.map(\.windowID))
        let cachedMinimizedWindows = cachedWindows.filter { window in
            window.isMinimized
                && activePIDs.contains(window.ownerPID)
                && windowIDs.insert(window.windowID).inserted
        }
        return visibleWindows + cachedMinimizedWindows
    }
}

enum WindowSwitcherDismissalPolicy {
    static func shouldDismissForMouseDown(panelFrame: CGRect, mouseLocation: CGPoint) -> Bool {
        !panelFrame.contains(mouseLocation)
    }
}

enum WindowSwitcherBackdrop {
    static let blurRadius: CGFloat = 8
    static let tint = Color(red: 0.52, green: 0.53, blue: 0.54).opacity(0.30)
    private static let context = CIContext(options: [.cacheIntermediates: false])

    struct Request: Hashable, Sendable {
        let displayID: CGDirectDisplayID
        let pixelRect: CGRect
        let windowListRect: CGRect
        let imageSize: CGSize
    }

    struct Capture: @unchecked Sendable {
        let image: CGImage
        let size: CGSize
    }

    struct Source: @unchecked Sendable {
        let image: CGImage
        let size: CGSize
    }

    static func captureRect(
        panelFrame: CGRect,
        screenFrame: CGRect,
        displayPixelWidth: CGFloat
    ) -> CGRect {
        let scale = displayPixelWidth / screenFrame.width
        return CGRect(
            x: (panelFrame.minX - screenFrame.minX) * scale,
            y: (screenFrame.maxY - panelFrame.maxY) * scale,
            width: panelFrame.width * scale,
            height: panelFrame.height * scale
        ).integral
    }

    static func request(panelFrame: CGRect, on screen: NSScreen) -> Request? {
        guard let displayID = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? CGDirectDisplayID else { return nil }
        let displayBounds = CGDisplayBounds(displayID)
        let displayScaleX = displayBounds.width / screen.frame.width
        let displayScaleY = displayBounds.height / screen.frame.height
        return Request(
            displayID: displayID,
            pixelRect: captureRect(
                panelFrame: panelFrame,
                screenFrame: screen.frame,
                displayPixelWidth: CGFloat(CGDisplayPixelsWide(displayID))
            ),
            windowListRect: CGRect(
                x: displayBounds.minX + (panelFrame.minX - screen.frame.minX) * displayScaleX,
                y: displayBounds.minY + (screen.frame.maxY - panelFrame.maxY) * displayScaleY,
                width: panelFrame.width * displayScaleX,
                height: panelFrame.height * displayScaleY
            ).integral,
            imageSize: panelFrame.size
        )
    }

    nonisolated static func captureSource(
        _ request: Request,
        below windowID: CGWindowID? = nil
    ) -> Source? {
        let source: CGImage?
        if let windowID {
            source = CGWindowListCreateImage(
                request.windowListRect,
                .optionOnScreenBelowWindow,
                windowID,
                [.boundsIgnoreFraming, .bestResolution]
            )
        } else {
            source = CGDisplayCreateImage(request.displayID, rect: request.pixelRect)
        }
        guard let source else { return nil }
        return Source(image: source, size: request.imageSize)
    }

    nonisolated static func blur(_ source: Source) -> Capture? {
        let input = CIImage(cgImage: source.image)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(blurRadius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: input.extent),
              let blurred = context.createCGImage(output, from: input.extent) else { return nil }
        return Capture(image: blurred, size: source.size)
    }

    nonisolated static func capture(_ request: Request) -> Capture? {
        guard let source = captureSource(request) else { return nil }
        return blur(source)
    }

    nonisolated static func capture(
        _ request: Request,
        below windowID: CGWindowID
    ) -> Capture? {
        guard let source = captureSource(request, below: windowID) else { return nil }
        return blur(source)
    }

    static func image(from capture: Capture) -> NSImage {
        NSImage(cgImage: capture.image, size: capture.size)
    }

    static func image(panelFrame: CGRect, on screen: NSScreen) -> NSImage? {
        guard let request = request(panelFrame: panelFrame, on: screen),
              let capture = capture(request) else { return nil }
        return image(from: capture)
    }
}

private enum WindowSwitcherWindowAction: CaseIterable {
    case toggleMinimized
    case toggleFullScreen
    case close

    var capability: WindowControlCapabilities {
        switch self {
        case .toggleMinimized: .minimize
        case .toggleFullScreen: .fullScreen
        case .close: .close
        }
    }

    var systemImage: String {
        switch self {
        case .toggleMinimized: "minus"
        case .toggleFullScreen: "square"
        case .close: "xmark"
        }
    }

    var buttonWidth: CGFloat {
        WindowSwitcherLayout.captionButtonWidth
    }

    var accessibilityLabel: String {
        switch self {
        case .toggleMinimized: "Minimize or restore window"
        case .toggleFullScreen: "Enter or exit full screen"
        case .close: "Close window"
        }
    }

    func backgroundColor(isHovering: Bool) -> Color {
        switch self {
        case .close:
            isHovering ? Color(red: 0.82, green: 0.04, blue: 0.10) : .clear
        case .toggleMinimized, .toggleFullScreen:
            isHovering ? Color.white.opacity(0.11) : .clear
        }
    }
}

private final class WindowSwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct WindowSwitcherCapturedThumbnail: @unchecked Sendable {
    let windowID: CGWindowID
    let image: CGImage
}

private struct WindowSwitcherRefreshResult: @unchecked Sendable {
    let thumbnails: [WindowSwitcherCapturedThumbnail]
    let controlCapabilities: [CGWindowID: WindowControlCapabilities]
    let backdrop: WindowSwitcherBackdrop.Capture?
}

@MainActor
private final class WindowSwitcherSelectionModel: ObservableObject {
    @Published var windowID: CGWindowID?
}

@MainActor
final class WindowSwitcherPanelController {
    private let windowsService: WindowsService
    private let activationService: WindowActivationService
    private let activationHistory: WindowActivationHistory
    private let preferences: PreferencesStore
    private let workspace: NSWorkspace
    private let panel: WindowSwitcherPanel
    private let backdrop = NSView()
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private let selection = WindowSwitcherSelectionModel()
    private var windows: [WindowInfo] = []
    private var thumbnails: [CGWindowID: NSImage] = [:]
    private var controlCapabilities: [CGWindowID: WindowControlCapabilities] = [:]
    private var backdropImage: NSImage?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var selectedIndex = 0
    private var tilePreviewHeight = WindowSwitcherLayout.previewHeight
    private var presentationID: UInt = 0
    private var refreshTask: Task<Void, Never>?
    private var windowCacheTask: Task<Void, Never>?
    private var detailedWindowsCache: [WindowInfo] = []
    private var detailedWindowsCacheDate = Date.distantPast
    private var controlCapabilitiesCache: [CGWindowID: WindowControlCapabilities] = [:]
    private var backdropCache: [WindowSwitcherBackdrop.Request: NSImage] = [:]

    init(
        windowsService: WindowsService,
        activationService: WindowActivationService,
        activationHistory: WindowActivationHistory,
        preferences: PreferencesStore,
        workspace: NSWorkspace = .shared
    ) {
        self.windowsService = windowsService
        self.activationService = activationService
        self.activationHistory = activationHistory
        self.preferences = preferences
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
        panel.animationBehavior = .none

        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 8
        backdrop.layer?.masksToBounds = true
        backdrop.layer?.borderWidth = 1
        backdrop.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        backdrop.layer?.backgroundColor = NSColor(
            calibratedRed: 0.31,
            green: 0.32,
            blue: 0.33,
            alpha: 1
        ).cgColor

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

    func prewarm() {
        let applications = workspace.runningApplications.filter {
            WindowSwitcherApplicationPolicy.shouldInclude(
                activationPolicy: $0.activationPolicy,
                isTerminated: $0.isTerminated
            )
        }
        refreshWindowCache(forPIDs: applications.map(\.processIdentifier))
    }

    private func present(reverse: Bool) {
        refreshTask?.cancel()
        presentationID &+= 1
        let currentPresentationID = presentationID
        let applications = workspace.runningApplications.filter {
            WindowSwitcherApplicationPolicy.shouldInclude(
                activationPolicy: $0.activationPolicy,
                isTerminated: $0.isTerminated
            )
        }
        let applicationPIDs = applications.map(\.processIdentifier)
        let visibleWindows = WindowsService.visibleWindowsInFrontToBackOrder(
            forPIDs: applicationPIDs
        )
        let cacheIsFresh = Date().timeIntervalSince(detailedWindowsCacheDate)
            <= WindowSwitcherWindowList.detailedCacheLifetime
        let frontToBackWindows = WindowSwitcherWindowList.initialWindows(
            visibleWindows: visibleWindows,
            cachedWindows: detailedWindowsCache,
            activePIDs: Set(applicationPIDs),
            usesDetailedCache: cacheIsFresh
        )
        windows = activationHistory.orderedWindows(from: frontToBackWindows)
        guard !windows.isEmpty else {
            dismiss()
            return
        }
        selectedIndex = reverse ? windows.count - 1 : min(1, windows.count - 1)
        updateSelection(disablesAnimations: true)
        thumbnails = Dictionary(uniqueKeysWithValues: windows.compactMap { window in
            windowsService.cachedThumbnail(for: window).map { (window.windowID, $0) }
        })
        controlCapabilities = Dictionary(uniqueKeysWithValues: windows.compactMap { window in
            controlCapabilitiesCache[window.windowID].map { (window.windowID, $0) }
        })

        let screen = screenAtMouseLocation() ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let targetFrame = panelFrame(on: screen)
        let backdropRequest = WindowSwitcherBackdrop.request(panelFrame: targetFrame, on: screen)
        backdropImage = backdropRequest.flatMap { backdropCache[$0] }
        panel.setFrame(targetFrame, display: false)
        refreshContent(disablesAnimations: true)
        backdrop.layoutSubtreeIfNeeded()
        panel.orderFrontRegardless()
        installMouseMonitors()
        refreshWindowCache(forPIDs: applicationPIDs)
        refreshPresentation(
            windows: windows,
            backdropRequest: backdropRequest,
            backdropWindowID: CGWindowID(panel.windowNumber),
            presentationID: currentPresentationID
        )
    }

    private func moveSelection(by step: Int) {
        guard panel.isVisible, !windows.isEmpty else { return }
        selectedIndex = (selectedIndex + step + windows.count) % windows.count
        updateSelection(disablesAnimations: true)
    }

    private func commitSelection() {
        guard panel.isVisible, windows.indices.contains(selectedIndex) else {
            dismiss()
            return
        }
        let selectedWindow = windows[selectedIndex]
        activationHistory.record(selectedWindow.windowID)
        dismiss()
        let activationService = activationService
        Task { @MainActor in
            let worker = Task.detached(priority: .userInitiated) {
                activationService.raiseAccessibilityWindow(selectedWindow)
            }
            await worker.value
            guard !Task.isCancelled else { return }
            activationService.activateApplication(for: selectedWindow)
        }
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
        case .toggleMinimized:
            activationService.toggleMinimized(window: window)
        case .toggleFullScreen:
            activationService.toggleFullScreen(window: window)
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
            updateSelection(disablesAnimations: true)
            if let screen = panel.screen { updatePanelFrame(on: screen) }
            refreshContent()
        }
    }

    private func updateSelection(disablesAnimations: Bool) {
        let selectedWindowID = windows.indices.contains(selectedIndex)
            ? windows[selectedIndex].windowID
            : nil
        guard disablesAnimations else {
            selection.windowID = selectedWindowID
            return
        }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selection.windowID = selectedWindowID
        }
    }

    private func refreshContent(disablesAnimations: Bool = false) {
        let content = AnyView(WindowSwitcherView(
            windows: windows,
            thumbnails: thumbnails,
            controlCapabilities: controlCapabilities,
            backdropImage: backdropImage,
            selection: selection,
            previewHeight: tilePreviewHeight,
            onWindowAction: { [weak self] action, windowID in self?.perform(action, on: windowID) },
            onSelect: { [weak self] windowID in self?.selectAndCommit(windowID: windowID) }
        ))
        guard disablesAnimations else {
            hostingView.rootView = content
            return
        }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            hostingView.rootView = content
        }
    }

    private func refreshWindowCache(forPIDs pids: [pid_t]) {
        windowCacheTask?.cancel()
        windowCacheTask = Task { @MainActor [weak self] in
            let worker = Task.detached(priority: .utility) {
                WindowsService.detailedWindowsInFrontToBackOrder(forPIDs: pids)
            }
            let windows = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self, !Task.isCancelled else { return }
            self.detailedWindowsCache = windows
            self.detailedWindowsCacheDate = Date()
            self.windowCacheTask = nil
        }
    }

    private func refreshPresentation(
        windows presentedWindows: [WindowInfo],
        backdropRequest: WindowSwitcherBackdrop.Request?,
        backdropWindowID: CGWindowID,
        presentationID: UInt
    ) {
        let activationService = activationService
        refreshTask = Task { @MainActor [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                var capturedThumbnails: [WindowSwitcherCapturedThumbnail] = []
                var capabilities: [CGWindowID: WindowControlCapabilities] = [:]
                for window in presentedWindows {
                    guard !Task.isCancelled else { break }
                    if let image = WindowsService.captureThumbnailImage(for: window) {
                        capturedThumbnails.append(WindowSwitcherCapturedThumbnail(
                            windowID: window.windowID,
                            image: image
                        ))
                    }
                    guard !Task.isCancelled else { break }
                    capabilities[window.windowID] = activationService.controlCapabilities(for: window)
                }
                let backdrop = Task.isCancelled
                    ? nil
                    : backdropRequest.flatMap {
                        WindowSwitcherBackdrop.capture($0, below: backdropWindowID)
                    }
                return WindowSwitcherRefreshResult(
                    thumbnails: capturedThumbnails,
                    controlCapabilities: capabilities,
                    backdrop: backdrop
                )
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self,
                  !Task.isCancelled,
                  self.panel.isVisible,
                  self.presentationID == presentationID else { return }

            let currentWindowIDs = Set(self.windows.map(\.windowID))
            for capture in result.thumbnails where currentWindowIDs.contains(capture.windowID) {
                let image = NSImage(
                    cgImage: capture.image,
                    size: NSSize(width: capture.image.width, height: capture.image.height)
                )
                self.windowsService.storeThumbnail(image, for: capture.windowID)
                self.thumbnails[capture.windowID] = image
            }
            self.controlCapabilitiesCache.merge(result.controlCapabilities) { _, refreshed in refreshed }
            self.controlCapabilities = self.controlCapabilitiesCache.filter {
                currentWindowIDs.contains($0.key)
            }
            if let backdropRequest, let capture = result.backdrop {
                let image = WindowSwitcherBackdrop.image(from: capture)
                self.backdropCache[backdropRequest] = image
                self.backdropImage = image
            }
            self.refreshContent()
            self.refreshTask = nil
        }
    }

    private func dismiss() {
        refreshTask?.cancel()
        refreshTask = nil
        presentationID &+= 1
        removeMouseMonitors()
        panel.orderOut(nil)
        windows = []
        thumbnails = [:]
        controlCapabilities = [:]
        backdropImage = nil
        selectedIndex = 0
        tilePreviewHeight = WindowSwitcherLayout.previewHeight
    }

    private func installMouseMonitors() {
        removeMouseMonitors()
        let mouseDownEvents: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
        ]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseDownEvents) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible else { return }
                let mouseLocation = event.window?.convertPoint(toScreen: event.locationInWindow)
                    ?? NSEvent.mouseLocation
                if WindowSwitcherDismissalPolicy.shouldDismissForMouseDown(
                    panelFrame: self.panel.frame,
                    mouseLocation: mouseLocation
                ) {
                    self.dismiss()
                }
            }
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDownEvents) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible else { return }
                self.dismiss()
            }
        }
    }

    private func removeMouseMonitors() {
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        localMouseMonitor = nil
        globalMouseMonitor = nil
    }

    private func updatePanelFrame(on screen: NSScreen) {
        panel.setFrame(panelFrame(on: screen), display: true)
    }

    private func panelFrame(on screen: NSScreen) -> CGRect {
        let reservesTaskbar = !preferences.autoHideTaskbar
            && (preferences.displayMode == .all || screen === NSScreen.screens.first)
        let workArea = WindowSwitcherLayout.workArea(
            visibleFrame: screen.visibleFrame,
            taskbarPosition: preferences.position,
            taskbarThickness: CGFloat(preferences.barHeight),
            reservesTaskbar: reservesTaskbar
        )
        let layout = WindowSwitcherLayout.metrics(
            windowFrames: windows.map(\.frame),
            screenFrame: workArea
        )
        tilePreviewHeight = layout.previewHeight
        let size = layout.panelSize
        return CGRect(
            x: workArea.midX - size.width / 2,
            y: workArea.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
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
    let backdropImage: NSImage?
    @ObservedObject var selection: WindowSwitcherSelectionModel
    let previewHeight: CGFloat
    let onWindowAction: (WindowSwitcherWindowAction, CGWindowID) -> Void
    let onSelect: (CGWindowID) -> Void

    var body: some View {
        ScrollView(.vertical) {
            WindowSwitcherFlowLayout(spacing: WindowSwitcherLayout.spacing) {
                ForEach(windows) { window in
                    WindowSwitcherTile(
                        window: window,
                        thumbnail: thumbnails[window.windowID],
                        controlCapabilities: controlCapabilities[window.windowID] ?? [],
                        isSelected: selection.windowID == window.windowID,
                        previewHeight: previewHeight,
                        onWindowAction: { onWindowAction($0, window.windowID) },
                        action: { onSelect(window.windowID) }
                    )
                }
            }
            .padding(WindowSwitcherLayout.panelPadding)
            .background(WindowSwitcherScrollViewConfigurator())
        }
        .scrollIndicators(.visible)
        .background {
            Group {
                if let backdropImage {
                    Image(nsImage: backdropImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color(red: 0.31, green: 0.32, blue: 0.33)
                }
            }
            .overlay(WindowSwitcherBackdrop.tint)
            .clipped()
        }
    }
}

private struct WindowSwitcherScrollViewConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowSwitcherScrollViewProbe {
        WindowSwitcherScrollViewProbe()
    }

    func updateNSView(_ nsView: WindowSwitcherScrollViewProbe, context: Context) {
        nsView.configureEnclosingScrollView()
    }
}

private final class WindowSwitcherScrollViewProbe: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureEnclosingScrollView()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configureEnclosingScrollView() {
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let scrollView = self?.enclosingScrollView else { return }
            scrollView.scrollerStyle = .legacy
            scrollView.autohidesScrollers = false
            scrollView.hasHorizontalScroller = false
            let contentHeight = scrollView.documentView?.frame.height ?? 0
            let needsScroller = contentHeight > scrollView.contentView.bounds.height + 1
            if needsScroller, !(scrollView.verticalScroller is WindowSwitcherThinScroller) {
                let scroller = WindowSwitcherThinScroller()
                scroller.scrollerStyle = .legacy
                scroller.controlSize = .mini
                scrollView.verticalScroller = scroller
            }
            scrollView.hasVerticalScroller = needsScroller
            scrollView.tile()
        }
    }
}

private final class WindowSwitcherThinScroller: NSScroller {
    override class func scrollerWidth(
        for controlSize: NSControl.ControlSize,
        scrollerStyle: NSScroller.Style
    ) -> CGFloat {
        7
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        let knobRect = rect(for: .knob)
        guard !knobRect.isEmpty else { return }
        let width = WindowSwitcherLayout.scrollIndicatorWidth
        let visibleKnob = CGRect(
            x: bounds.maxX - width - 2,
            y: knobRect.minY + 2,
            width: width,
            height: max(12, knobRect.height - 4)
        )
        NSColor.white.withAlphaComponent(0.42).setFill()
        NSBezierPath(
            roundedRect: visibleKnob,
            xRadius: width / 2,
            yRadius: width / 2
        ).fill()
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
    let controlCapabilities: WindowControlCapabilities
    let isSelected: Bool
    let previewHeight: CGFloat
    let onWindowAction: (WindowSwitcherWindowAction) -> Void
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var availableActions: [WindowSwitcherWindowAction] {
        WindowSwitcherWindowAction.allCases.filter { controlCapabilities.contains($0.capability) }
    }

    private var controlsWidth: CGFloat {
        availableActions.reduce(CGFloat.zero) { $0 + $1.buttonWidth }
    }

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
                        if isHovering, !availableActions.isEmpty {
                            Color.clear.frame(width: controlsWidth)
                        }
                    }
                    .padding(.leading, 10)
                    .frame(height: WindowSwitcherLayout.titleBarHeight)
                    .background(Color.white.opacity(isHovering ? 0.085 : 0.045))
                    preview
                }
                .frame(
                    width: WindowSwitcherLayout.tileWidth(
                        for: window.frame,
                        previewHeight: previewHeight
                    ),
                    height: WindowSwitcherLayout.tileHeight(for: previewHeight)
                )
                .background(Color(red: 0.08, green: 0.08, blue: 0.085))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(WindowSwitcherTileButtonStyle())
            .accessibilityLabel(window.title)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            if isHovering, !availableActions.isEmpty {
                HStack(spacing: 0) {
                    ForEach(availableActions, id: \.self) { action in
                        WindowSwitcherControlButton(action: action) {
                            onWindowAction(action)
                        }
                    }
                }
            }
        }
        .frame(
            width: WindowSwitcherLayout.tileWidth(
                for: window.frame,
                previewHeight: previewHeight
            ),
            height: WindowSwitcherLayout.tileHeight(for: previewHeight)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    isSelected
                        ? Color(red: 0.20, green: 0.70, blue: 1)
                        : Color.white.opacity(isHovering ? 0.18 : 0),
                    lineWidth: isSelected ? 3 : 1
                )
                .allowsHitTesting(false)
        }
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
                    .interpolation(.high)
                    .scaledToFit()
            }
            .frame(
                width: WindowSwitcherLayout.tileWidth(
                    for: window.frame,
                    previewHeight: previewHeight
                ),
                height: previewHeight
            )
            .clipped()
        } else {
            ZStack {
                Color(red: 0.055, green: 0.055, blue: 0.06)
                appIcon.frame(width: 48, height: 48)
            }
            .frame(
                width: WindowSwitcherLayout.tileWidth(
                    for: window.frame,
                    previewHeight: previewHeight
                ),
                height: previewHeight
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

private struct WindowSwitcherControlButton: View {
    let action: WindowSwitcherWindowAction
    let perform: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: perform) {
            Image(systemName: action.systemImage)
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.92))
                .frame(width: action.buttonWidth, height: WindowSwitcherLayout.titleBarHeight)
                .background(action.backgroundColor(isHovering: isHovering))
                .contentShape(Rectangle())
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
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.76 : 1)
            .animation(.easeOut(duration: 0.06), value: configuration.isPressed)
    }
}
