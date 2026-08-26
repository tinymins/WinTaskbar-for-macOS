import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TaskbarDragMotion {
    static let duration: TimeInterval = 0.167
    static let reorderFirstControlPoint = CGPoint(x: 0.55, y: 0.55)
    static let reorderSecondControlPoint = CGPoint(x: 0, y: 1)
    static let reorder = Animation.timingCurve(
        reorderFirstControlPoint.x,
        reorderFirstControlPoint.y,
        reorderSecondControlPoint.x,
        reorderSecondControlPoint.y,
        duration: duration
    )
    static let decoration = Animation.timingCurve(0, 0, 0, 1, duration: duration)
}

struct TaskbarDragReorderPolicy {
    static func iconCenter(
        pointerLocation: CGPoint,
        grabOffset: CGSize,
        horizontal: Bool,
        fixedCrossAxisPosition: CGFloat
    ) -> CGPoint {
        var center = CGPoint(
            x: pointerLocation.x + grabOffset.width,
            y: pointerLocation.y + grabOffset.height
        )
        if horizontal { center.y = fixedCrossAxisPosition }
        else { center.x = fixedCrossAxisPosition }
        return center
    }
}

private enum TaskbarDragCoordinateSpace {
    static let name = "WinTaskbar.AppItems"
}

private struct TaskbarItemFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private final class TaskbarDragGeometryState {
    var itemFrames: [String: CGRect] = [:]
}

private struct TaskbarDragPreviewContent {
    let item: TaskbarItem
    let icon: NSImage
}

private final class TaskbarDragPreviewState: ObservableObject {
    @Published var content: TaskbarDragPreviewContent?
    @Published var center: CGPoint?
}

private struct TaskbarDragPreviewLayer<Content: View>: View {
    @ObservedObject var state: TaskbarDragPreviewState
    @ViewBuilder let content: (TaskbarDragPreviewContent) -> Content

    var body: some View {
        if let preview = state.content, let center = state.center {
            content(preview)
                .position(center)
                .allowsHitTesting(false)
        }
    }
}

struct TaskbarView: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var apps: AppDiscoveryService
    @ObservedObject var status: SystemStatusService
    @ObservedObject var actions: AppActions
    @ObservedObject var dockBadges: DockBadgeService
    let windowActivator: WindowActivationService
    let windowsService: WindowsService
    let windowPeekController: WindowPeekController
    @ObservedObject var windowPreviewPanelController: WindowPreviewPanelController
    @ObservedObject var taskbarJumpListController: TaskbarJumpListController
    @ObservedObject var startButtonContextMenuController: TaskbarJumpListController
    @ObservedObject var startButtonPowerMenuController: TaskbarJumpListController
    let shortcutEditorController: ShortcutEditorController
    @ObservedObject var recentDocuments: RecentDocumentsService
    let screen: NSScreen
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragGeometry = TaskbarDragGeometryState()
    @State private var dragPreviewState = TaskbarDragPreviewState()
    @State private var taskbarOrderRevision = 0
    @State private var dragGrabOffset = CGSize.zero
    @State private var dragFixedCrossAxisPosition: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let horizontal = preferences.position.isHorizontal
            let _ = taskbarOrderRevision
            let items = apps.taskbarItems(
                pinnedBundleIDs: preferences.pinnedBundleIDs,
                badges: dockBadges.badges,
                showFinder: preferences.showFinder
            )
            let capacity = visibleCapacity(length: horizontal ? geometry.size.width : geometry.size.height)
            let visible = Array(items.prefix(capacity))
            let overflow = Array(items.dropFirst(capacity))

            Group {
                if horizontal {
                    HStack(spacing: TaskbarItemGeometry.itemSpacing) {
                        if showsStartButtonAtLeadingEdge { startButton }
                        itemButtons(visible, horizontal: true)
                        if !overflow.isEmpty { overflowButton(overflow) }
                        Spacer(minLength: 8)
                        if showsStartButtonBeforeTray { startButton }
                        tray
                        if preferences.showDesktopEnabled { showDesktopStrip(horizontal: true) }
                        if showsStartButtonAtOppositeEnd { startButton }
                    }
                    .padding(.horizontal, StartMenuGeometry.screenEdgeInset)
                    .frame(height: max(0, geometry.size.height - 0.5))
                } else {
                    VStack(spacing: TaskbarItemGeometry.itemSpacing) {
                        if showsStartButtonAtLeadingEdge { startButton }
                        itemButtons(visible, horizontal: false)
                        if !overflow.isEmpty { overflowButton(overflow) }
                        Spacer(minLength: 8)
                        if showsStartButtonBeforeTray { startButton }
                        tray
                        if preferences.showDesktopEnabled { showDesktopStrip(horizontal: false) }
                        if showsStartButtonAtOppositeEnd { startButton }
                    }
                    .padding(.vertical, StartMenuGeometry.screenEdgeInset)
                    .frame(width: max(0, geometry.size.width - 0.5))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: contentAlignment)
            .background(panelBackground)
            .preferredColorScheme(preferredColorScheme)
            .coordinateSpace(name: TaskbarDragCoordinateSpace.name)
            .onPreferenceChange(TaskbarItemFramePreferenceKey.self) { dragGeometry.itemFrames = $0 }
            .overlay(alignment: .topLeading) {
                TaskbarDragPreviewLayer(state: dragPreviewState) { preview in
                    dragPreview(for: preview.item, icon: preview.icon)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                var accepted = false
                for url in urls where url.pathExtension.lowercased() == "app" {
                    if let bundleID = Bundle(url: url)?.bundleIdentifier {
                        preferences.pin(bundleID)
                        accepted = true
                    }
                }
                return accepted
            }
        }
    }

    private var startButton: some View {
        Button {
            dismissStartButtonContextMenus()
            actions.toggleStartMenu(on: screen)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: itemGeometry.cellSize * 0.52, weight: .medium))
                if !preferences.startButtonLabel.isEmpty {
                    Text(preferences.startButtonLabel)
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .frame(minWidth: itemGeometry.cellSize, minHeight: itemGeometry.cellSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(TaskbarButtonStyle())
        .help("Open menu")
        .accessibilityLabel("Open menu")
        .overlay {
            TaskbarContextClickAnchor { anchorView in
                showStartButtonContextMenu(relativeTo: anchorView)
            }
        }
    }

    private func showStartButtonContextMenu(relativeTo anchorView: NSView) {
        guard let anchorWindow = anchorView.window else { return }
        actions.closeStartMenu()
        windowPreviewPanelController.dismissAll()
        windowPeekController.hideImmediately()
        taskbarJumpListController.dismiss()
        startButtonPowerMenuController.dismiss()

        let screen = anchorWindow.screen ?? self.screen
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
            onDismiss: dismissStartButtonContextMenus,
            onShowPower: {
                showStartButtonPowerMenu(
                    parentFrame: frame,
                    screenFrame: screen.frame,
                    appearance: anchorWindow.appearance
                )
            }
        )
        .frame(width: frame.width, height: frame.height)

        startButtonContextMenuController.show(
            rootView: AnyView(rootView),
            frame: frame,
            appearance: anchorWindow.appearance
        )
    }

    private func showStartButtonPowerMenu(
        parentFrame: CGRect,
        screenFrame: CGRect,
        appearance: NSAppearance?
    ) {
        let frame = StartButtonPowerMenuGeometry.frame(
            parentFrame: parentFrame,
            contentSize: StartButtonContextMenuMetrics.powerSize,
            screenFrame: screenFrame
        )
        let rootView = StartButtonPowerMenuView(
            actions: actions,
            onDismiss: dismissStartButtonContextMenus
        )
        .frame(width: frame.width, height: frame.height)
        startButtonPowerMenuController.show(
            rootView: AnyView(rootView),
            frame: frame,
            appearance: appearance
        )
    }

    private func dismissStartButtonContextMenus() {
        startButtonPowerMenuController.dismiss()
        startButtonContextMenuController.dismiss()
    }

    @ViewBuilder
    private func itemButtons(_ items: [TaskbarItem], horizontal: Bool) -> some View {
        if horizontal {
            HStack(spacing: TaskbarItemGeometry.itemSpacing) {
                ForEach(items) { itemButton($0) }
            }
            .frame(maxHeight: .infinity)
            .animation(
                reduceMotion ? nil : TaskbarDragMotion.reorder,
                value: items.map(\.bundleIdentifier)
            )
        } else {
            VStack(spacing: TaskbarItemGeometry.itemSpacing) {
                ForEach(items) { itemButton($0) }
            }
            .frame(maxWidth: .infinity)
            .animation(
                reduceMotion ? nil : TaskbarDragMotion.reorder,
                value: items.map(\.bundleIdentifier)
            )
        }
    }

    private func itemButton(_ item: TaskbarItem) -> some View {
        let previewOwnerID = WindowPreviewOwnerID(
            displayID: displayID,
            bundleIdentifier: item.bundleIdentifier
        )
        return TaskbarAppButton(
            item: item,
            previewOwnerID: previewOwnerID,
            preferences: preferences,
            apps: apps,
            dockBadges: dockBadges,
            windowActivator: windowActivator,
            windowsService: windowsService,
            windowPeekController: windowPeekController,
            windowPreviewPanelController: windowPreviewPanelController,
            taskbarJumpListController: taskbarJumpListController,
            shortcutEditorController: shortcutEditorController,
            recentDocuments: recentDocuments,
            isTaskbarReordering: { dragPreviewState.content != nil },
            onReorderChanged: { updateReordering(item, value: $0) },
            onReorderEnded: { finishReordering(item) },
            onHoveringApp: { hovering in
                if hovering { dismissStartButtonContextMenus() }
            }
        )
        .equatable()
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: TaskbarItemFramePreferenceKey.self,
                    value: [
                        item.bundleIdentifier: proxy.frame(in: .named(TaskbarDragCoordinateSpace.name)),
                    ]
                )
            }
        }
    }

    private func updateReordering(_ item: TaskbarItem, value: DragGesture.Value) {
        if dragPreviewState.content == nil { beginReordering(item, value: value) }
        guard dragPreviewState.content?.item.bundleIdentifier == item.bundleIdentifier else { return }
        let draggedIconCenter = TaskbarDragReorderPolicy.iconCenter(
            pointerLocation: value.location,
            grabOffset: dragGrabOffset,
            horizontal: preferences.position.isHorizontal,
            fixedCrossAxisPosition: dragFixedCrossAxisPosition
                ?? (preferences.position.isHorizontal ? value.startLocation.y : value.startLocation.x)
        )
        dragPreviewState.center = draggedIconCenter
        updateReorderTarget(for: item, draggedIconCenter: draggedIconCenter)
    }

    private func beginReordering(_ item: TaskbarItem, value: DragGesture.Value) {
        dragPreviewState.content = TaskbarDragPreviewContent(item: item, icon: item.icon)
        if let frame = dragGeometry.itemFrames[item.bundleIdentifier] {
            dragGrabOffset = CGSize(
                width: frame.midX - value.startLocation.x,
                height: frame.midY - value.startLocation.y
            )
            dragFixedCrossAxisPosition = preferences.position.isHorizontal ? frame.midY : frame.midX
            dragPreviewState.center = CGPoint(x: frame.midX, y: frame.midY)
        } else {
            dragGrabOffset = .zero
            dragFixedCrossAxisPosition = preferences.position.isHorizontal
                ? value.startLocation.y
                : value.startLocation.x
            dragPreviewState.center = value.startLocation
        }
        taskbarJumpListController.dismiss()
        windowPreviewPanelController.dismissAll()
        windowPeekController.hideImmediately()
    }

    private func updateReorderTarget(for item: TaskbarItem, draggedIconCenter: CGPoint) {
        guard dragGeometry.itemFrames[item.bundleIdentifier]?.contains(draggedIconCenter) != true else { return }
        let taskbarBounds = dragGeometry.itemFrames.values.reduce(CGRect.null) { $0.union($1) }
            .insetBy(dx: -TaskbarItemGeometry.itemSpacing, dy: -TaskbarItemGeometry.itemSpacing)
        guard taskbarBounds.contains(draggedIconCenter),
              let target = dragGeometry.itemFrames
                .filter({ $0.key != item.bundleIdentifier })
                .min(by: { lhs, rhs in
                    if preferences.position.isHorizontal {
                        return abs(lhs.value.midX - draggedIconCenter.x)
                            < abs(rhs.value.midX - draggedIconCenter.x)
                    }
                    return abs(lhs.value.midY - draggedIconCenter.y)
                        < abs(rhs.value.midY - draggedIconCenter.y)
                }) else { return }
        let after = preferences.position.isHorizontal
            ? draggedIconCenter.x > target.value.midX
            : draggedIconCenter.y > target.value.midY
        let animation: Animation? = reduceMotion ? nil : TaskbarDragMotion.reorder
        withAnimation(animation) {
            guard apps.reorderTaskbarItem(
                item.bundleIdentifier,
                relativeTo: target.key,
                after: after
            ) else { return }
            taskbarOrderRevision &+= 1
        }
    }

    private func finishReordering(_ item: TaskbarItem) {
        guard dragPreviewState.content?.item.bundleIdentifier == item.bundleIdentifier else { return }
        preferences.alignPinnedOrder(to: apps.taskbarBundleOrder)
        let animation: Animation? = reduceMotion ? nil : TaskbarDragMotion.reorder
        guard let frame = dragGeometry.itemFrames[item.bundleIdentifier] else {
            clearReorderingState()
            return
        }
        withAnimation(animation) {
            dragPreviewState.center = CGPoint(x: frame.midX, y: frame.midY)
        }
        guard !reduceMotion else {
            clearReorderingState()
            return
        }
        Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: UInt64((TaskbarDragMotion.duration + (1.0 / 60.0)) * 1_000_000_000)
            )
            guard dragPreviewState.content?.item.bundleIdentifier == item.bundleIdentifier else { return }
            clearReorderingState()
        }
    }

    private func clearReorderingState() {
        dragPreviewState.content = nil
        dragPreviewState.center = nil
        dragGrabOffset = .zero
        dragFixedCrossAxisPosition = nil
    }

    private func dragPreview(for item: TaskbarItem, icon: NSImage) -> some View {
        Image(nsImage: icon)
            .resizable()
            .interpolation(.high)
            .frame(width: itemGeometry.iconSize, height: itemGeometry.iconSize)
            .overlay(alignment: .topTrailing) {
                if let badge = item.badge {
                    Text(badge)
                        .font(.system(size: 8, weight: .bold))
                        .padding(3)
                        .background(Color.red)
                        .clipShape(Capsule())
                }
            }
    }

    private func overflowButton(_ items: [TaskbarItem]) -> some View {
        Menu {
            ForEach(items) { item in
                Button { windowActivator.activateOrMinimize(item) } label: {
                    Label {
                        Text(item.name)
                    } icon: {
                        Image(nsImage: item.icon)
                    }
                }
            }
        } label: {
            Image(systemName: preferences.position.isHorizontal ? "chevron.up" : "chevron.right")
                .frame(width: itemGeometry.cellSize, height: itemGeometry.cellSize)
        }
        .menuStyle(.borderlessButton)
        .frame(width: itemGeometry.cellSize + 6)
        .help("More apps")
    }

    @ViewBuilder
    private var tray: some View {
        if preferences.position.isHorizontal {
            HStack(spacing: 10) { trayContents }
        } else {
            VStack(spacing: 10) { trayContents }
        }
    }

    @ViewBuilder
    private var trayContents: some View {
        if preferences.trayWifiEnabled {
            WiFiTrayView(service: status)
        }
        if preferences.trayVolumeEnabled {
            VolumeTrayView(service: status)
        }
        if preferences.trayBatteryEnabled {
            BatteryTrayView(service: status, horizontal: preferences.position.isHorizontal)
        }
        if preferences.trayInputSourceEnabled {
            InputSourceTrayView(service: status, position: preferences.position)
        }
        if preferences.trayClockEnabled {
            ClockTrayView(
                service: status,
                position: preferences.position,
                barHeight: CGFloat(preferences.barHeight),
                theme: preferences.theme,
                screen: screen
            )
        }
    }

    private func visibleCapacity(length: CGFloat) -> Int {
        let itemLength = itemGeometry.cellSize + TaskbarItemGeometry.itemSpacing
        let reserved: CGFloat = preferences.position.isHorizontal ? 250 : 240
        return max(1, Int((length - reserved) / max(itemLength, 1)))
    }

    private var showsStartButtonAtLeadingEdge: Bool {
        if preferences.startButtonAtEnd { return false }
        return preferences.menuButtonPlacement == .standard
    }

    private var showsStartButtonBeforeTray: Bool {
        if preferences.startButtonAtEnd { return false }
        return preferences.menuButtonPlacement == .beforeTray
    }

    private var showsStartButtonAtOppositeEnd: Bool {
        preferences.startButtonAtEnd || preferences.menuButtonPlacement == .oppositeEnd
    }

    private func showDesktopStrip(horizontal: Bool) -> some View {
        Button(action: actions.showDesktop) {
            Rectangle().fill(Color.primary.opacity(0.18))
                .frame(width: horizontal ? 4 : itemGeometry.cellSize, height: horizontal ? itemGeometry.cellSize : 4)
        }
        .buttonStyle(.plain).help("Show Desktop")
    }

    private var panelBackground: some View {
        Rectangle().fill(.ultraThinMaterial)
            .overlay {
                if let tint = Color(hex: preferences.panelTintHex) {
                    tint.opacity(preferences.transparencyEnabled ? max(0.08, 1 - preferences.panelOpacity) : 0.2)
                } else {
                    Color.black.opacity(preferences.transparencyEnabled ? max(0.04, 1 - preferences.panelOpacity) : 0.18)
                }
            }
    }

    private var preferredColorScheme: ColorScheme? {
        switch preferences.theme { case .automatic: nil; case .light: .light; case .dark: .dark }
    }

    private var contentAlignment: Alignment {
        switch preferences.position {
        case .bottom: .bottom
        case .top: .top
        case .left: .leading
        case .right: .trailing
        }
    }

    private var itemGeometry: TaskbarItemGeometry {
        .calculate(
            barHeight: preferences.barHeight,
            iconScale: preferences.iconScale,
            iconPadding: preferences.iconPadding
        )
    }

    private var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
    }

}

struct TaskbarItemGeometry: Equatable {
    static let itemSpacing: CGFloat = 4

    let cellSize: CGFloat
    let iconSize: CGFloat

    static func calculate(
        barHeight: CGFloat,
        iconScale: CGFloat,
        iconPadding: CGFloat
    ) -> TaskbarItemGeometry {
        let cellSize = min(barHeight - 2, 40 * iconScale)
        let iconInset = cellSize * iconPadding
        return TaskbarItemGeometry(
            cellSize: cellSize,
            iconSize: max(0, cellSize - (2 * iconInset))
        )
    }
}

struct RunningIndicatorLayout: Equatable {
    let width: CGFloat
    let height: CGFloat
    let opacity: Double
    let edgePadding: CGFloat

    static func underline(
        position: TaskbarPosition,
        cellSize: CGFloat,
        isActive: Bool,
        highlightStyle: HighlightStyle,
        requestsAttention: Bool = false
    ) -> RunningIndicatorLayout {
        let length = cellSize * (requestsAttention ? 0.75 : (isActive ? 0.60 : 0.35))
        return RunningIndicatorLayout(
            width: position.isHorizontal ? length : 2,
            height: position.isHorizontal ? 2 : length,
            opacity: isActive ? 1 : 0.7,
            edgePadding: highlightStyle == .windows ? 3 : -3
        )
    }

    static func dot(highlightStyle: HighlightStyle) -> RunningIndicatorLayout {
        RunningIndicatorLayout(
            width: 4,
            height: 4,
            opacity: 0.7,
            edgePadding: highlightStyle == .windows ? 3 : -2
        )
    }
}

struct WindowPreviewLayout {
    enum Axis: Equatable {
        case horizontal
        case vertical
    }

    static func axis(for position: TaskbarPosition) -> Axis {
        position.isHorizontal ? .horizontal : .vertical
    }
}

enum WindowPreviewHoverAction: Equatable {
    case present
    case scheduleDismissal
    case dismiss
}

struct WindowPreviewHoverPolicy {
    static func action(hovering: Bool, previewsEnabled: Bool, hasProcess: Bool) -> WindowPreviewHoverAction {
        guard previewsEnabled, hasProcess else { return .dismiss }
        return hovering ? .present : .scheduleDismissal
    }
}

struct WindowPreviewThumbnailGeometry {
    static let maximumSize = CGSize(width: 176, height: 100)
    static let minimumContentWidth: CGFloat = 120

    static func thumbnailSize(for sourceSize: CGSize) -> CGSize {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return maximumSize }
        let scale = min(
            maximumSize.width / sourceSize.width,
            maximumSize.height / sourceSize.height
        )
        return CGSize(
            width: (sourceSize.width * scale).rounded(.down),
            height: (sourceSize.height * scale).rounded(.down)
        )
    }

    static func contentWidth(for sourceSize: CGSize) -> CGFloat {
        max(minimumContentWidth, thumbnailSize(for: sourceSize).width)
    }

    static func horizontalInset(for sourceSize: CGSize) -> CGFloat {
        (contentWidth(for: sourceSize) - thumbnailSize(for: sourceSize).width) / 2
    }
}

enum WindowPreviewMetrics {
    static let horizontalPadding: CGFloat = 8
    static let topPadding: CGFloat = 8
    static let bottomPadding: CGFloat = 6
    static let titleHeight: CGFloat = 24
    static let titleToThumbnailSpacing: CGFloat = 3
    static let closeControlSize: CGFloat = 24
    static let emptySize = CGSize(width: 160, height: 48)
}

struct WindowPreviewContentGeometry {
    static func itemSize(for window: WindowInfo) -> CGSize {
        let thumbnailSize = WindowPreviewThumbnailGeometry.thumbnailSize(for: window.frame.size)
        return CGSize(
            width: WindowPreviewThumbnailGeometry.contentWidth(for: window.frame.size)
                + (2 * WindowPreviewMetrics.horizontalPadding),
            height: WindowPreviewMetrics.topPadding
                + WindowPreviewMetrics.titleHeight
                + WindowPreviewMetrics.titleToThumbnailSpacing
                + thumbnailSize.height
                + WindowPreviewMetrics.bottomPadding
        )
    }

    static func contentSize(windows: [WindowInfo], position: TaskbarPosition) -> CGSize {
        let sizes = windows.prefix(6).map(itemSize)
        guard !sizes.isEmpty else { return WindowPreviewMetrics.emptySize }
        if WindowPreviewLayout.axis(for: position) == .horizontal {
            return CGSize(
                width: sizes.reduce(0) { $0 + $1.width },
                height: sizes.map(\.height).max() ?? 0
            )
        }
        return CGSize(
            width: sizes.map(\.width).max() ?? 0,
            height: sizes.reduce(0) { $0 + $1.height }
        )
    }
}

private struct TaskbarAppButton: View, @MainActor Equatable {
    let item: TaskbarItem
    let previewOwnerID: WindowPreviewOwnerID
    @ObservedObject var preferences: PreferencesStore
    let apps: AppDiscoveryService
    @ObservedObject var dockBadges: DockBadgeService
    let windowActivator: WindowActivationService
    let windowsService: WindowsService
    let windowPeekController: WindowPeekController
    @ObservedObject var windowPreviewPanelController: WindowPreviewPanelController
    let taskbarJumpListController: TaskbarJumpListController
    let shortcutEditorController: ShortcutEditorController
    let recentDocuments: RecentDocumentsService
    let isTaskbarReordering: () -> Bool
    let onReorderChanged: (DragGesture.Value) -> Void
    let onReorderEnded: () -> Void
    let onHoveringApp: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var isBeingDragged = false
    @State private var previewWindows: [WindowInfo] = []
    @State private var attentionPulse = false
    @State private var attentionTask: Task<Void, Never>?

    static func == (lhs: TaskbarAppButton, rhs: TaskbarAppButton) -> Bool {
        lhs.item == rhs.item
            && lhs.previewOwnerID == rhs.previewOwnerID
            && lhs.preferences === rhs.preferences
            && lhs.apps === rhs.apps
            && lhs.dockBadges === rhs.dockBadges
            && lhs.windowActivator === rhs.windowActivator
            && lhs.windowsService === rhs.windowsService
            && lhs.windowPeekController === rhs.windowPeekController
            && lhs.windowPreviewPanelController === rhs.windowPreviewPanelController
            && lhs.taskbarJumpListController === rhs.taskbarJumpListController
            && lhs.shortcutEditorController === rhs.shortcutEditorController
            && lhs.recentDocuments === rhs.recentDocuments
    }

    var body: some View {
        Button {
            guard !isTaskbarReordering() else { return }
            dockBadges.acknowledge(item.bundleIdentifier)
            DispatchQueue.main.async {
                windowActivator.activateOrMinimize(item)
            }
        } label: {
            appIconCell
            .opacity(isBeingDragged ? 0 : 1)
            .background {
                appBackground
                    .opacity(isBeingDragged ? 0 : 1)
                    .animation(dragDecorationAnimation, value: isBeingDragged)
            }
            .overlay(alignment: indicatorAlignment) {
                if preferences.showRunningIndicators && !preferences.showAppLabels {
                    runningIndicator
                        .scaleEffect(
                            x: preferences.position.isHorizontal && isBeingDragged ? 0 : 1,
                            y: preferences.position.isHorizontal || !isBeingDragged ? 1 : 0
                        )
                        .opacity(isBeingDragged ? 0 : 1)
                        .animation(dragDecorationAnimation, value: isBeingDragged)
                }
            }
            .overlay {
                if preferences.activeIndicator == .border && item.isActive {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.accentColor, lineWidth: 1)
                        .opacity(isBeingDragged ? 0 : 1)
                        .animation(dragDecorationAnimation, value: isBeingDragged)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(TaskbarButtonStyle(contentPadding: 0, suppressPressFeedback: isBeingDragged))
        .simultaneousGesture(reorderGesture)
        .overlay {
            TaskbarContextClickAnchor { anchorView in
                showJumpList(relativeTo: anchorView)
            }
        }
        .help(item.name)
        .onChange(of: attentionState?.pulseGeneration ?? 0) { generation in
            if generation > 0 { startAttentionPulse() }
        }
        .onChange(of: attentionState != nil) { highlighted in
            if !highlighted { stopAttentionPulse() }
        }
        .onDisappear {
            stopAttentionPulse()
            windowPreviewPanelController.dismiss(ownerID: previewOwnerID)
            windowPeekController.hideImmediately()
        }
        .onHover(perform: handlePreviewHover)
        .onChange(of: windowPreviewPanelController.activeOwnerID) { activeOwnerID in
            guard activeOwnerID == previewOwnerID, let pid = item.processIdentifier else { return }
            previewWindows = windowsService.windows(forPID: pid)
        }
        .background {
            if item.processIdentifier != nil {
                WindowPreviewPanelPresenter(
                    isPresented: windowPreviewPanelController.activeOwnerID == previewOwnerID,
                    ownerID: previewOwnerID,
                    position: preferences.position,
                    contentSize: WindowPreviewContentGeometry.contentSize(
                        windows: previewWindows,
                        position: preferences.position
                    ),
                    animatesTransition: !reduceMotion,
                    controller: windowPreviewPanelController
                ) {
                    WindowPreviewPopover(
                        windows: previewWindows,
                        position: preferences.position,
                        service: windowsService,
                        windowPeekController: windowPeekController,
                        onSelect: {
                            windowActivator.raise(window: $0)
                            windowPreviewPanelController.dismiss(ownerID: previewOwnerID)
                        },
                        onClose: {
                            windowPeekController.hideImmediately()
                            windowActivator.close(window: $0)
                            windowPreviewPanelController.dismiss(ownerID: previewOwnerID)
                        }
                    )
                    .onHover(perform: handlePreviewPopoverHover)
                }
            }
        }
    }

    private var reorderGesture: some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named(TaskbarDragCoordinateSpace.name))
            .onChanged { value in
                if !isBeingDragged { isBeingDragged = true }
                onReorderChanged(value)
            }
            .onEnded { _ in
                onReorderEnded()
                guard !reduceMotion else {
                    isBeingDragged = false
                    return
                }
                Task { @MainActor in
                    try? await Task.sleep(
                        nanoseconds: UInt64(TaskbarDragMotion.duration * 1_000_000_000)
                    )
                    isBeingDragged = false
                }
            }
    }

    private func showJumpList(relativeTo anchorView: NSView) {
        windowPreviewPanelController.dismissAll()
        windowPeekController.hideImmediately()

        let windows = item.processIdentifier.map(windowsService.windows(forPID:)) ?? []
        let shortcuts = preferences.showShortcutsInMenu
            ? preferences.pinnedShortcuts[item.bundleIdentifier] ?? []
            : []
        let recent = preferences.showRecentInMenu
            ? recentDocuments.recentDocuments(forBundleID: item.bundleIdentifier)
            : []
        let model = TaskbarJumpListModel(
            shortcuts: shortcuts,
            recentDocuments: recent,
            isPinned: item.isPinned,
            windowCount: windows.count
        )
        let contentSize = TaskbarJumpListMetrics.contentSize(
            shortcutCount: shortcuts.count,
            recentCount: recent.count,
            isRunning: item.isRunning
        )
        let rootView = TaskbarJumpListView(
            item: item,
            model: model,
            onOpenApp: {
                taskbarJumpListController.dismiss()
                windowActivator.openNewWindow(item)
            },
            onOpenShortcut: { shortcut in
                taskbarJumpListController.dismiss()
                if let url = shortcut.url { NSWorkspace.shared.open(url) }
            },
            onOpenRecent: { document in
                taskbarJumpListController.dismiss()
                recentDocuments.open(document, with: item)
            },
            onManageShortcuts: {
                taskbarJumpListController.dismiss()
                shortcutEditorController.present(
                    bundleID: item.bundleIdentifier,
                    appName: item.name
                )
            },
            onShowInFinder: {
                taskbarJumpListController.dismiss()
                apps.showInFinder(item)
            },
            onTogglePin: {
                taskbarJumpListController.dismiss()
                if item.isPinned { preferences.unpin(item.bundleIdentifier) }
                else { preferences.pin(item.bundleIdentifier) }
            },
            onClose: {
                taskbarJumpListController.dismiss()
                for window in windows { windowActivator.close(window: window) }
            },
            onQuit: {
                taskbarJumpListController.dismiss()
                apps.quit(item)
            }
        )
        .frame(width: contentSize.width, height: contentSize.height)

        taskbarJumpListController.show(
            rootView: AnyView(rootView),
            contentSize: contentSize,
            relativeTo: anchorView,
            position: preferences.position
        )
    }

    private func handlePreviewHover(_ hovering: Bool) {
        onHoveringApp(hovering)
        if isTaskbarReordering() {
            isHovering = false
            windowPreviewPanelController.dismiss(ownerID: previewOwnerID)
            windowPeekController.hideImmediately()
            return
        }
        if TaskbarJumpListInteractionPolicy.shouldDismissMenuOnAppHover(hovering: hovering) {
            taskbarJumpListController.dismiss()
        }
        isHovering = hovering

        switch WindowPreviewHoverPolicy.action(
            hovering: hovering,
            previewsEnabled: preferences.windowPreviewsEnabled,
            hasProcess: item.processIdentifier != nil
        ) {
        case .dismiss:
            windowPreviewPanelController.dismiss(ownerID: previewOwnerID)
        case .present:
            if windowPreviewPanelController.activeOwnerID != previewOwnerID {
                windowPeekController.hideImmediately()
            }
            windowPreviewPanelController.activate(ownerID: previewOwnerID)
        case .scheduleDismissal:
            schedulePreviewClose()
        }
    }

    private func handlePreviewPopoverHover(_ hovering: Bool) {
        if hovering {
            windowPreviewPanelController.cancelDismissal(ownerID: previewOwnerID)
        } else {
            schedulePreviewClose()
        }
    }

    private func schedulePreviewClose() {
        windowPreviewPanelController.scheduleDismissal(ownerID: previewOwnerID) {
            windowPeekController.hide()
        }
    }

    private var dragDecorationAnimation: Animation? {
        reduceMotion ? nil : TaskbarDragMotion.decoration
    }

    @ViewBuilder
    private var appBackground: some View {
        ZStack {
            if preferences.activeIndicator == .background && item.isActive {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.22))
            } else if isHovering {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            }
            if attentionState != nil {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(attentionBackgroundColor.opacity(attentionPulse ? 0.48 : 0.36))
                    .padding(preferences.position.isHorizontal ? .horizontal : .vertical, -2)
                    .padding(preferences.position.isHorizontal ? .vertical : .horizontal, -1)
            }
        }
    }

    private var attentionBackgroundColor: Color {
        Color(red: 0.72, green: 0.31, blue: 0.40)
    }

    private var attentionAccentColor: Color {
        Color(red: 0.90, green: 0.43, blue: 0.52)
    }

    private var attentionState: TaskbarAttentionState? {
        dockBadges.attentionStates[item.bundleIdentifier]
    }

    private func startAttentionPulse() {
        attentionTask?.cancel()
        guard !reduceMotion else {
            attentionPulse = false
            return
        }
        attentionTask = Task { @MainActor in
            for _ in 0..<2 {
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.22)) { attentionPulse = true }
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.32)) { attentionPulse = false }
                try? await Task.sleep(for: .milliseconds(320))
            }
            attentionTask = nil
        }
    }

    private func stopAttentionPulse() {
        attentionTask?.cancel()
        attentionTask = nil
        attentionPulse = false
    }

    @ViewBuilder
    private var appIconCell: some View {
        let geometry = TaskbarItemGeometry.calculate(
            barHeight: preferences.barHeight,
            iconScale: preferences.iconScale,
            iconPadding: preferences.iconPadding
        )
        let content = VStack(spacing: 1) {
            Image(nsImage: item.icon).resizable().interpolation(.high)
                .frame(width: geometry.iconSize, height: geometry.iconSize)
                .overlay(alignment: .topTrailing) {
                    if let badge = item.badge {
                        Text(badge).font(.system(size: 8, weight: .bold)).padding(3).background(Color.red).clipShape(Capsule())
                    }
                }
            if preferences.showAppLabels {
                Text(item.name).font(.system(size: 9)).lineLimit(1).frame(maxWidth: geometry.cellSize + 18)
            }
        }
        .contentShape(Rectangle())

        if preferences.highlightStyle == .windows && preferences.position.isHorizontal {
            content
                .frame(width: geometry.cellSize)
                .frame(maxHeight: .infinity)
        } else if preferences.highlightStyle == .windows {
            content
                .frame(height: geometry.cellSize)
                .frame(maxWidth: .infinity)
        } else {
            content.frame(width: geometry.cellSize, height: geometry.cellSize)
        }
    }

    @ViewBuilder
    private var runningIndicator: some View {
        if item.isRunning {
            if preferences.activeIndicator == .underline {
                let layout = RunningIndicatorLayout.underline(
                    position: preferences.position,
                    cellSize: TaskbarItemGeometry.calculate(
                        barHeight: preferences.barHeight,
                        iconScale: preferences.iconScale,
                        iconPadding: preferences.iconPadding
                    ).cellSize,
                    isActive: item.isActive,
                    highlightStyle: preferences.highlightStyle,
                    requestsAttention: attentionState != nil
                )
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(runningIndicatorColor)
                    .frame(width: layout.width, height: layout.height)
                    .opacity(attentionState == nil ? layout.opacity : 1)
                    .padding(indicatorEdge, layout.edgePadding)
            } else if !item.isActive {
                let layout = RunningIndicatorLayout.dot(highlightStyle: preferences.highlightStyle)
                Circle()
                    .fill(runningIndicatorColor)
                    .frame(width: layout.width, height: layout.height)
                    .opacity(attentionState == nil ? layout.opacity : 1)
                    .padding(indicatorEdge, layout.edgePadding)
            }
        }
    }

    private var runningIndicatorColor: Color {
        if attentionState != nil { return attentionAccentColor }
        return item.isActive ? Color.accentColor : Color.secondary
    }

    private var indicatorAlignment: Alignment {
        switch preferences.position {
        case .bottom: .bottom
        case .top: .top
        case .left: .leading
        case .right: .trailing
        }
    }

    private var indicatorEdge: Edge.Set {
        switch preferences.position {
        case .bottom: .bottom
        case .top: .top
        case .left: .leading
        case .right: .trailing
        }
    }
}

private struct WindowPreviewPopover: View {
    let windows: [WindowInfo]
    let position: TaskbarPosition
    let service: WindowsService
    let windowPeekController: WindowPeekController
    let onSelect: (WindowInfo) -> Void
    let onClose: (WindowInfo) -> Void

    @ViewBuilder
    var body: some View {
        if windows.isEmpty {
            Text("No open windows")
                .foregroundStyle(.secondary)
                .frame(width: WindowPreviewMetrics.emptySize.width, height: WindowPreviewMetrics.emptySize.height)
        } else if WindowPreviewLayout.axis(for: position) == .horizontal {
            HStack(alignment: .top, spacing: 0) {
                ForEach(windows.prefix(6)) { window in
                    previewButton(for: window)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(windows.prefix(6)) { window in
                    previewButton(for: window)
                }
            }
        }
    }

    private func previewButton(for window: WindowInfo) -> some View {
        WindowPreviewButton(
            window: window,
            service: service,
            windowPeekController: windowPeekController,
            action: { onSelect(window) },
            closeAction: { onClose(window) }
        )
    }
}

private struct WindowPreviewButton: View {
    let window: WindowInfo
    let service: WindowsService
    let windowPeekController: WindowPeekController
    let action: () -> Void
    let closeAction: () -> Void
    @State private var isHovering = false
    @State private var isCloseHovering = false

    private var thumbnailSize: CGSize {
        WindowPreviewThumbnailGeometry.thumbnailSize(for: window.frame.size)
    }

    private var contentWidth: CGFloat {
        WindowPreviewThumbnailGeometry.contentWidth(for: window.frame.size)
    }

    var body: some View {
        ZStack {
            Button {
                windowPeekController.hideImmediately()
                action()
            } label: {
                VStack(alignment: .leading, spacing: WindowPreviewMetrics.titleToThumbnailSpacing) {
                    HStack(spacing: 6) {
                        appIcon
                        Text(window.title)
                            .lineLimit(1)
                            .help(window.title)
                        Spacer(minLength: 0)
                        Color.clear.frame(
                            width: WindowPreviewMetrics.closeControlSize,
                            height: WindowPreviewMetrics.titleHeight
                        )
                    }
                    thumbnail
                        .padding(.horizontal, WindowPreviewThumbnailGeometry.horizontalInset(for: window.frame.size))
                }
                .frame(width: contentWidth, alignment: .topLeading)
                .padding(.horizontal, WindowPreviewMetrics.horizontalPadding)
                .padding(.top, WindowPreviewMetrics.topPadding)
                .padding(.bottom, WindowPreviewMetrics.bottomPadding)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .overlay(alignment: .topTrailing) {
            if isHovering {
                Button(action: closeAction) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .frame(
                            width: WindowPreviewMetrics.closeControlSize,
                            height: WindowPreviewMetrics.closeControlSize
                        )
                        .background {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(isCloseHovering ? Color.red.opacity(0.85) : Color.clear)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, WindowPreviewMetrics.horizontalPadding)
                .padding(.top, WindowPreviewMetrics.topPadding)
                .onHover { isCloseHovering = $0 }
                .help("Close")
            }
        }
        .background(Color.white.opacity(isHovering ? 0.055 : 0))
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            if !hovering { isCloseHovering = false }
            if hovering {
                windowPeekController.show(window: window)
            } else {
                windowPeekController.scheduleHide()
            }
        }
        .onDisappear {
            if isHovering { windowPeekController.hideImmediately() }
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
        .frame(width: 14, height: 14)
    }

    @ViewBuilder
    private var thumbnail: some View {
        Group {
            if let image = service.thumbnail(for: window) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ZStack {
                    Color.primary.opacity(0.06)
                    Image(systemName: "macwindow")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Preview unavailable")
            }
        }
        .frame(width: thumbnailSize.width, height: thumbnailSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

struct TaskbarButtonMotion {
    static let pressedScale: CGFloat = 0.82
    static let pressDuration: TimeInterval = 0.06
    static let releaseDuration: TimeInterval = 0.08

    static func animation(isPressed: Bool) -> Animation {
        .easeOut(duration: isPressed ? pressDuration : releaseDuration)
    }
}

private struct TaskbarButtonStyle: ButtonStyle {
    var contentPadding: CGFloat = 3
    var suppressPressFeedback = false

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = configuration.isPressed && !suppressPressFeedback
        configuration.label
            .scaleEffect(isPressed ? TaskbarButtonMotion.pressedScale : 1)
            .padding(contentPadding)
            .background(isPressed ? Color.primary.opacity(0.15) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .animation(TaskbarButtonMotion.animation(isPressed: isPressed), value: isPressed)
    }
}
