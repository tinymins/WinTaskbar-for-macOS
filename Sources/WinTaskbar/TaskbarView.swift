import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TaskbarView: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var apps: AppDiscoveryService
    @ObservedObject var status: SystemStatusService
    @ObservedObject var actions: AppActions
    @ObservedObject var dockBadges: DockBadgeService
    let windowActivator: WindowActivationService
    let windowsService: WindowsService
    let windowPeekController: WindowPeekController
    let recentDocuments: RecentDocumentsService
    let screen: NSScreen

    var body: some View {
        GeometryReader { geometry in
            let horizontal = preferences.position.isHorizontal
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
                    .padding(.horizontal, 8)
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
                    .padding(.vertical, 8)
                    .frame(width: max(0, geometry.size.width - 0.5))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: contentAlignment)
            .background(panelBackground)
            .preferredColorScheme(preferredColorScheme)
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
    }

    @ViewBuilder
    private func itemButtons(_ items: [TaskbarItem], horizontal: Bool) -> some View {
        if horizontal {
            HStack(spacing: TaskbarItemGeometry.itemSpacing) {
                ForEach(items) { itemButton($0) }
            }
            .frame(maxHeight: .infinity)
        } else {
            VStack(spacing: TaskbarItemGeometry.itemSpacing) {
                ForEach(items) { itemButton($0) }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func itemButton(_ item: TaskbarItem) -> some View {
        TaskbarAppButton(
            item: item,
            preferences: preferences,
            apps: apps,
            windowActivator: windowActivator,
            windowsService: windowsService,
            windowPeekController: windowPeekController,
            recentDocuments: recentDocuments
        )
        .draggable(item.bundleIdentifier)
        .dropDestination(for: String.self) { bundleIDs, _ in
            guard item.isPinned, let source = bundleIDs.first else { return false }
            preferences.reorderPinned(source, before: item.bundleIdentifier)
            return true
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
            InputSourceTrayView(service: status)
        }
        if preferences.trayClockEnabled {
            ClockTrayView(service: status, horizontal: preferences.position.isHorizontal)
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
        highlightStyle: HighlightStyle
    ) -> RunningIndicatorLayout {
        let length = cellSize * (isActive ? 0.60 : 0.35)
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

struct WindowPreviewPlacement {
    static func arrowEdge(for position: TaskbarPosition) -> Edge {
        switch position {
        case .top: .top
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }
}

struct TaskbarAttentionPolicy {
    static func shouldFlash(previous: String?, current: String?) -> Bool {
        guard let current else { return false }
        guard let previous else { return true }
        if let previousCount = Int(previous), let currentCount = Int(current) {
            return currentCount > previousCount
        }
        return current != previous
    }
}

private struct TaskbarAppButton: View {
    let item: TaskbarItem
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var apps: AppDiscoveryService
    let windowActivator: WindowActivationService
    let windowsService: WindowsService
    let windowPeekController: WindowPeekController
    let recentDocuments: RecentDocumentsService
    @State private var isHovering = false
    @State private var showPreview = false
    @State private var previewHoverTask: Task<Void, Never>?
    @State private var previewCloseTask: Task<Void, Never>?
    @State private var showShortcutEditor = false
    @State private var lastBadge: String?
    @State private var attentionFlash = false
    @State private var attentionTask: Task<Void, Never>?

    var body: some View {
        appIconCell
        .background {
            appBackground
        }
        .overlay(alignment: indicatorAlignment) {
            if preferences.showRunningIndicators && !preferences.showAppLabels {
                runningIndicator
            }
        }
        .overlay {
            if preferences.activeIndicator == .border && item.isActive {
                RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { windowActivator.activateOrMinimize(item) }
        .accessibilityAddTraits(.isButton)
        .help(item.name)
        .onAppear {
            lastBadge = item.badge
            if item.badge != nil { startAttentionFlash() }
        }
        .onChange(of: item.badge) { badge in updateAttention(for: badge) }
        .onDisappear {
            stopAttentionFlash()
            cancelPreviewTasks()
            windowPeekController.hideImmediately()
        }
        .onHover(perform: handlePreviewHover)
        .popover(
            isPresented: $showPreview,
            arrowEdge: WindowPreviewPlacement.arrowEdge(for: preferences.position)
        ) {
            if let pid = item.processIdentifier {
                WindowPreviewPopover(
                    windows: windowsService.windows(forPID: pid),
                    service: windowsService,
                    windowPeekController: windowPeekController
                ) {
                    windowActivator.raise(window: $0); showPreview = false
                }
                .onHover(perform: handlePreviewPopoverHover)
            }
        }
        .contextMenu {
            Button("New Window") { windowActivator.openNewWindow(item) }
            let recent = recentDocuments.recentDocuments(forBundleID: item.bundleIdentifier)
            if preferences.showRecentInMenu && !recent.isEmpty {
                Menu("Recent") { ForEach(recent) { document in Button(document.label) { recentDocuments.open(document, with: item) } } }
            }
            let shortcuts = preferences.pinnedShortcuts[item.bundleIdentifier] ?? []
            if preferences.showShortcutsInMenu && !shortcuts.isEmpty {
                Menu("Shortcuts") { ForEach(shortcuts) { shortcut in Button(shortcut.name) { if let url = shortcut.url { NSWorkspace.shared.open(url) } } } }
            }
            Button("Manage Shortcuts…") { showShortcutEditor = true }
            Divider()
            if item.isPinned { Button("Unpin") { preferences.unpin(item.bundleIdentifier) } }
            else { Button("Pin to Taskbar") { preferences.pin(item.bundleIdentifier) } }
            Button("Show in Finder") { apps.showInFinder(item) }
            if item.isRunning { Divider(); Button("Quit") { apps.quit(item) } }
        }
        .sheet(isPresented: $showShortcutEditor) {
            ShortcutEditorView(
                bundleID: item.bundleIdentifier,
                appName: item.name,
                preferences: preferences,
                isPresented: $showShortcutEditor
            )
        }
    }

    private func handlePreviewHover(_ hovering: Bool) {
        isHovering = hovering

        guard preferences.windowPreviewsEnabled, item.processIdentifier != nil else {
            cancelPreviewTasks()
            showPreview = false
            return
        }

        previewHoverTask?.cancel()
        previewHoverTask = nil

        if hovering {
            previewCloseTask?.cancel()
            previewCloseTask = nil
            previewHoverTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled else { return }
                showPreview = true
            }
        } else {
            schedulePreviewClose()
        }
    }

    private func handlePreviewPopoverHover(_ hovering: Bool) {
        if hovering {
            previewCloseTask?.cancel()
            previewCloseTask = nil
        } else {
            schedulePreviewClose()
        }
    }

    private func schedulePreviewClose() {
        previewCloseTask?.cancel()
        previewCloseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            showPreview = false
            windowPeekController.hide()
        }
    }

    private func cancelPreviewTasks() {
        previewHoverTask?.cancel()
        previewHoverTask = nil
        previewCloseTask?.cancel()
        previewCloseTask = nil
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
            if item.badge != nil {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.orange.opacity(attentionFlash ? 0.48 : 0.16))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.orange.opacity(attentionFlash ? 0.9 : 0.35), lineWidth: 1)
                    }
            }
        }
    }

    private func updateAttention(for badge: String?) {
        let previousBadge = lastBadge
        lastBadge = badge
        guard badge != nil else {
            stopAttentionFlash()
            return
        }
        if TaskbarAttentionPolicy.shouldFlash(previous: previousBadge, current: badge) {
            startAttentionFlash()
        }
    }

    private func startAttentionFlash() {
        attentionTask?.cancel()
        attentionTask = Task { @MainActor in
            for _ in 0..<3 {
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.18)) { attentionFlash = true }
                try? await Task.sleep(nanoseconds: 180_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.18)) { attentionFlash = false }
                try? await Task.sleep(nanoseconds: 180_000_000)
            }
            attentionTask = nil
        }
    }

    private func stopAttentionFlash() {
        attentionTask?.cancel()
        attentionTask = nil
        attentionFlash = false
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
                    highlightStyle: preferences.highlightStyle
                )
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(item.isActive ? Color.accentColor : Color.secondary)
                    .frame(width: layout.width, height: layout.height)
                    .opacity(layout.opacity)
                    .padding(indicatorEdge, layout.edgePadding)
            } else if !item.isActive {
                let layout = RunningIndicatorLayout.dot(highlightStyle: preferences.highlightStyle)
                Circle()
                    .fill(Color.secondary)
                    .frame(width: layout.width, height: layout.height)
                    .opacity(layout.opacity)
                    .padding(indicatorEdge, layout.edgePadding)
            }
        }
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

private struct ShortcutEditorView: View {
    let bundleID: String
    let appName: String
    @ObservedObject var preferences: PreferencesStore
    @Binding var isPresented: Bool
    @State private var newName = ""
    @State private var newTarget = ""

    private var shortcuts: [PinnedShortcut] { preferences.pinnedShortcuts[bundleID] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(appName) Shortcuts").font(.title2.bold())
            List {
                ForEach(shortcuts) { shortcut in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(shortcut.name)
                            Text(shortcut.target).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Remove") { remove(shortcut) }
                    }
                }
            }
            HStack {
                TextField("Name", text: $newName)
                TextField("File path or URL", text: $newTarget)
                Button("Add", action: add).disabled(newName.isEmpty || newTarget.isEmpty)
            }
            HStack { Spacer(); Button("Done") { isPresented = false }.keyboardShortcut(.defaultAction) }
        }
        .padding(20).frame(width: 520, height: 360)
    }

    private func add() {
        var values = shortcuts
        values.append(PinnedShortcut(name: newName, target: newTarget))
        preferences.pinnedShortcuts[bundleID] = values
        newName = ""
        newTarget = ""
    }

    private func remove(_ shortcut: PinnedShortcut) {
        preferences.pinnedShortcuts[bundleID] = shortcuts.filter { $0.id != shortcut.id }
    }
}

private struct WindowPreviewPopover: View {
    let windows: [WindowInfo]
    let service: WindowsService
    let windowPeekController: WindowPeekController
    let onSelect: (WindowInfo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if windows.isEmpty { Text("No open windows").foregroundStyle(.secondary).padding() }
            else {
                ForEach(windows.prefix(6)) { window in
                    WindowPreviewButton(
                        window: window,
                        service: service,
                        windowPeekController: windowPeekController
                    ) {
                        onSelect(window)
                    }
                }
            }
        }.padding(10).frame(maxWidth: 360)
    }
}

private struct WindowPreviewButton: View {
    let window: WindowInfo
    let service: WindowsService
    let windowPeekController: WindowPeekController
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button {
            windowPeekController.hideImmediately()
            action()
        } label: {
            HStack(spacing: 8) {
                if let image = service.thumbnail(for: window.windowID) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 150, height: 90)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                Text(window.title).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(isHovering ? 0.08 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
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
}

private struct TaskbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(3).background(configuration.isPressed ? Color.primary.opacity(0.15) : .clear).clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
