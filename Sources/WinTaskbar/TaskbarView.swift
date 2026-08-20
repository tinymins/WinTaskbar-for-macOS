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
    let recentDocuments: RecentDocumentsService

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
                    HStack(spacing: preferences.iconPadding) {
                        if showsStartButton(at: .start) { startButton }
                        itemButtons(visible, horizontal: true)
                        if !overflow.isEmpty { overflowButton(overflow) }
                        Spacer(minLength: 8)
                        if showsStartButton(at: .beforeTray) { startButton }
                        tray
                        if preferences.showDesktopEnabled { showDesktopStrip(horizontal: true) }
                        if showsStartButton(at: .afterTray) { startButton }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                } else {
                    VStack(spacing: preferences.iconPadding) {
                        if showsStartButton(at: .start) { startButton }
                        itemButtons(visible, horizontal: false)
                        if !overflow.isEmpty { overflowButton(overflow) }
                        Spacer(minLength: 8)
                        if showsStartButton(at: .beforeTray) { startButton }
                        tray
                        if preferences.showDesktopEnabled { showDesktopStrip(horizontal: false) }
                        if showsStartButton(at: .afterTray) { startButton }
                    }
                    .padding(.horizontal, 3)
                    .padding(.vertical, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        Button(action: actions.toggleStartMenu) {
            HStack(spacing: 5) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: preferences.iconScale * 0.52, weight: .medium))
                if !preferences.startButtonLabel.isEmpty {
                    Text(preferences.startButtonLabel)
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .frame(minWidth: preferences.iconScale, minHeight: preferences.iconScale)
            .contentShape(Rectangle())
        }
        .buttonStyle(TaskbarButtonStyle())
        .help("Open menu")
        .accessibilityLabel("Open menu")
    }

    @ViewBuilder
    private func itemButtons(_ items: [TaskbarItem], horizontal: Bool) -> some View {
        if horizontal {
            HStack(spacing: preferences.iconPadding) {
                ForEach(items) { itemButton($0) }
            }
        } else {
            VStack(spacing: preferences.iconPadding) {
                ForEach(items) { itemButton($0) }
            }
        }
    }

    private func itemButton(_ item: TaskbarItem) -> some View {
        TaskbarAppButton(
            item: item,
            preferences: preferences,
            apps: apps,
            windowActivator: windowActivator,
            windowsService: windowsService,
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
                .frame(width: preferences.iconScale, height: preferences.iconScale)
        }
        .menuStyle(.borderlessButton)
        .frame(width: preferences.iconScale + 6)
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
        let itemLength = CGFloat(preferences.iconScale + preferences.iconPadding + 8)
        let reserved: CGFloat = preferences.position.isHorizontal ? 250 : 240
        return max(1, Int((length - reserved) / max(itemLength, 1)))
    }

    private func showsStartButton(at placement: MenuButtonPlacement) -> Bool {
        if preferences.startButtonAtEnd { return placement == .afterTray }
        return preferences.menuButtonPlacement == placement
    }

    private func showDesktopStrip(horizontal: Bool) -> some View {
        Button(action: actions.showDesktop) {
            Rectangle().fill(Color.primary.opacity(0.18))
                .frame(width: horizontal ? 4 : CGFloat(preferences.iconScale), height: horizontal ? CGFloat(preferences.iconScale) : 4)
        }
        .buttonStyle(.plain).help("Show Desktop")
    }

    private var panelBackground: some View {
        Rectangle().fill(.ultraThinMaterial)
            .overlay(Color.black.opacity(preferences.transparencyEnabled ? max(0.05, 1 - preferences.panelOpacity) : 0.22))
    }

    private var preferredColorScheme: ColorScheme? {
        switch preferences.theme { case .automatic: nil; case .light: .light; case .dark: .dark }
    }

}

private struct TaskbarAppButton: View {
    let item: TaskbarItem
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var apps: AppDiscoveryService
    let windowActivator: WindowActivationService
    let windowsService: WindowsService
    let recentDocuments: RecentDocumentsService
    @State private var showPreview = false
    @State private var showShortcutEditor = false

    var body: some View {
        Button { windowActivator.activateOrMinimize(item) } label: {
            VStack(spacing: 1) {
                Image(nsImage: item.icon).resizable().interpolation(.high)
                    .frame(width: preferences.iconScale, height: preferences.iconScale)
                    .overlay(alignment: .topTrailing) {
                        if let badge = item.badge {
                            Text(badge).font(.system(size: 8, weight: .bold)).padding(3).background(Color.red).clipShape(Capsule())
                        }
                    }
                if preferences.showAppLabels {
                    Text(item.name).font(.system(size: 9)).lineLimit(1).frame(maxWidth: preferences.iconScale + 18)
                }
                if preferences.showRunningIndicators && item.isRunning && preferences.activeIndicator == .underline {
                    Capsule().fill(item.isActive ? Color.accentColor : Color.secondary)
                        .frame(width: preferences.highlightStyle == .windows ? preferences.iconScale * 0.75 : 5, height: 2)
                }
            }
            .padding(.horizontal, 2)
            .background {
                if preferences.activeIndicator == .background && item.isRunning {
                    RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(item.isActive ? 0.2 : 0.09))
                }
            }
            .overlay {
                if preferences.activeIndicator == .border && item.isRunning {
                    RoundedRectangle(cornerRadius: 6).stroke(item.isActive ? Color.accentColor : .secondary, lineWidth: 1)
                }
            }
        }
        .buttonStyle(TaskbarButtonStyle()).help(item.name)
        .onHover { hovering in showPreview = hovering && preferences.windowPreviewsEnabled && item.processIdentifier != nil }
        .popover(isPresented: $showPreview, arrowEdge: preferences.position == .top ? .top : .bottom) {
            if let pid = item.processIdentifier {
                WindowPreviewPopover(windows: windowsService.windows(forPID: pid), service: windowsService) {
                    windowActivator.raise(window: $0); showPreview = false
                }
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
    let onSelect: (WindowInfo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if windows.isEmpty { Text("No open windows").foregroundStyle(.secondary).padding() }
            else {
                ForEach(windows.prefix(6)) { window in
                    Button { onSelect(window) } label: {
                        HStack(spacing: 8) {
                            if let image = service.thumbnail(for: window.windowID) {
                                Image(nsImage: image).resizable().scaledToFit().frame(width: 150, height: 90).clipShape(RoundedRectangle(cornerRadius: 5))
                            }
                            Text(window.title).lineLimit(2)
                        }
                    }.buttonStyle(.plain)
                }
            }
        }.padding(10).frame(maxWidth: 360)
    }
}

private struct TaskbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(3).background(configuration.isPressed ? Color.primary.opacity(0.15) : .clear).clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
