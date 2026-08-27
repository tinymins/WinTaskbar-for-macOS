import AppKit
import SwiftUI

enum TaskbarContextMenuSection: CaseIterable {
    case terminal
    case goTo
    case apps
    case windows

    var title: String {
        switch self {
        case .terminal: "Terminal"
        case .goTo: "Go To"
        case .apps: "Apps"
        case .windows: "Windows"
        }
    }

    var systemImage: String {
        switch self {
        case .terminal: "terminal"
        case .goTo: "location"
        case .apps: "square.grid.2x2"
        case .windows: "rectangle.on.rectangle"
        }
    }

    var rowIndex: Int {
        switch self {
        case .terminal: 0
        case .goTo: 1
        case .apps: 2
        case .windows: 3
        }
    }

    func submenuTitles(terminals: [TaskbarTerminalMenuEntry]) -> [String] {
        switch self {
        case .terminal: terminals.map(\.title)
        case .goTo: ["Folder", "Go to Folder…", "Connect to Server…", "Run…", "Settings"]
        case .apps: [
            "Applications", "Utilities", "Activity Monitor", "Disk Utility", "Console",
            "System Information",
        ]
        case .windows: [
            "Cascade windows", "Show windows stacked", "Show windows side by side",
            "Minimize all windows", "Restore all windows",
        ]
        }
    }

    var submenuDividerCount: Int {
        switch self {
        case .terminal: 0
        case .goTo, .apps, .windows: 1
        }
    }

    var hasNestedSubmenu: Bool { self == .goTo }
}

enum TaskbarContextNestedSection {
    case folders
    case settings

    var rowIndex: Int {
        switch self {
        case .folders: 0
        case .settings: 4
        }
    }

    var titles: [String] {
        switch self {
        case .folders: [
            "Macintosh HD", "System", "Library", "Applications", "Utilities", "Users",
            "Home", "Desktop", "Downloads", "Documents", "Pictures", "Music", "Movies",
            "User Library", "Temporary",
        ]
        case .settings: [
            "General", "About", "Displays", "Network", "Bluetooth", "Sound", "Keyboard",
            "Privacy & Security",
        ]
        }
    }

    var dividerCount: Int { self == .folders ? 2 : 0 }
}

enum TaskbarWindowMenuCommand {
    case cascade
    case stacked
    case sideBySide
    case minimizeAll
    case restoreAll
}

enum TaskbarContextMenuCommand {
    case desktop
    case settings
    case taskManager
    case taskbarSettings
}

struct TaskbarTerminalMenuEntry: Identifiable {
    let bundleIdentifier: String
    let title: String
    let url: URL
    let icon: NSImage

    var id: String { bundleIdentifier }
}

enum TaskbarTerminalCatalog {
    private static let bundleIdentifiers = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "com.github.wez.wezterm",
        "org.alacritty",
        "net.kovidgoyal.kitty",
    ]

    @MainActor
    static func installed(workspace: NSWorkspace = .shared) -> [TaskbarTerminalMenuEntry] {
        bundleIdentifiers.compactMap { bundleIdentifier in
            guard let url = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
                return nil
            }
            return TaskbarTerminalMenuEntry(
                bundleIdentifier: bundleIdentifier,
                title: FileManager.default.displayName(atPath: url.path),
                url: url,
                icon: workspace.icon(forFile: url.path)
            )
        }
    }
}

enum TaskbarContextMenuMetrics {
    static let width: CGFloat = 164
    static let rowHeight: CGFloat = 30
    static let verticalPadding: CGFloat = 5
    static let cornerRadius: CGFloat = 8
    static let rowLayout = TaskbarJumpListRow.Layout(
        rowHeight: rowHeight,
        fontSize: 12,
        iconSize: 16,
        iconFontSize: 13,
        spacing: 8,
        contentHorizontalPadding: 11,
        outerHorizontalPadding: 4,
        trailingIconFontSize: 10,
        hoverCornerRadius: 4
    )
    static let rootRowCount: CGFloat = 8
    static let dividerCount: CGFloat = 2
    static let minimumSubmenuWidth: CGFloat = 164
    static let maximumSubmenuWidth: CGFloat = 220

    static let rootSize = CGSize(
        width: width,
        height: verticalPadding * 2
            + rootRowCount * rowHeight
            + dividerCount * TaskbarJumpListMetrics.dividerBlockHeight
    )

    static func submenuSize(
        titles: [String],
        dividerCount: Int = 0,
        hasTrailingChevron: Bool = false
    ) -> CGSize {
        let font = NSFont.systemFont(ofSize: rowLayout.fontSize, weight: .regular)
        let textWidth = titles.map {
            ($0 as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 0
        let horizontalChrome: CGFloat = hasTrailingChevron ? 78 : 62
        let width = min(
            maximumSubmenuWidth,
            max(minimumSubmenuWidth, ceil(textWidth + horizontalChrome))
        )
        return CGSize(
            width: width,
            height: verticalPadding * 2
                + CGFloat(max(titles.count, 1)) * rowHeight
                + CGFloat(dividerCount) * TaskbarJumpListMetrics.dividerBlockHeight
        )
    }
}

enum TaskbarContextMenuGeometry {
    static let submenuGap: CGFloat = 5
    static let screenInset: CGFloat = 8

    static func rootFrame(
        clickPoint: CGPoint,
        taskbarFrame: CGRect,
        contentSize: CGSize,
        position: TaskbarPosition,
        screenFrame: CGRect
    ) -> CGRect {
        let anchorFrame: CGRect
        if position.isHorizontal {
            anchorFrame = CGRect(
                x: clickPoint.x,
                y: taskbarFrame.minY,
                width: 0,
                height: taskbarFrame.height
            )
        } else {
            anchorFrame = CGRect(
                x: taskbarFrame.minX,
                y: clickPoint.y,
                width: taskbarFrame.width,
                height: 0
            )
        }
        return TaskbarJumpListGeometry.frame(
            anchorFrame: anchorFrame,
            contentSize: contentSize,
            position: position,
            screenFrame: screenFrame
        )
    }

    static func submenuFrame(
        parentFrame: CGRect,
        rowIndex: Int,
        contentSize: CGSize,
        screenFrame: CGRect
    ) -> CGRect {
        let rightX = parentFrame.maxX + submenuGap
        let leftX = parentFrame.minX - submenuGap - contentSize.width
        let fitsOnRight = rightX + contentSize.width <= screenFrame.maxX - screenInset
        let rowCenterY = parentFrame.maxY
            - TaskbarContextMenuMetrics.verticalPadding
            - (CGFloat(rowIndex) + 0.5) * TaskbarContextMenuMetrics.rowHeight
        let minimumY = screenFrame.minY + screenInset
        let maximumY = max(minimumY, screenFrame.maxY - screenInset - contentSize.height)
        return CGRect(
            x: fitsOnRight ? rightX : leftX,
            y: min(max(rowCenterY - contentSize.height / 2, minimumY), maximumY),
            width: contentSize.width,
            height: contentSize.height
        )
    }
}

enum TaskbarSubmenuPointerIntent {
    static func isMovingTowardSubmenu(
        previous: CGPoint,
        current: CGPoint,
        submenuFrame: CGRect,
        tolerance: CGFloat = 8
    ) -> Bool {
        let deltaX = current.x - previous.x
        let deltaY = current.y - previous.y
        let targetX: CGFloat
        if submenuFrame.minX >= current.x {
            guard deltaX > 0 else { return false }
            targetX = submenuFrame.minX
        } else if submenuFrame.maxX <= current.x {
            guard deltaX < 0 else { return false }
            targetX = submenuFrame.maxX
        } else {
            return submenuFrame.insetBy(dx: -tolerance, dy: -tolerance).contains(current)
        }
        let scale = (targetX - current.x) / deltaX
        guard scale >= 0 else { return false }
        let projectedY = current.y + deltaY * scale
        return projectedY >= submenuFrame.minY - tolerance
            && projectedY <= submenuFrame.maxY + tolerance
    }
}

struct TaskbarContextMenuView: View {
    let onShowSection: (TaskbarContextMenuSection) -> Void
    let onCommand: (TaskbarContextMenuCommand) -> Void
    let onDismissSubmenu: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(TaskbarContextMenuSection.allCases, id: \.self) { section in
                TaskbarJumpListRow(
                    title: section.title,
                    systemImage: section.systemImage,
                    trailingSystemImage: "chevron.right",
                    layout: TaskbarContextMenuMetrics.rowLayout,
                    onHoverChanged: { hovering in
                        if hovering { onShowSection(section) }
                    },
                    action: { onShowSection(section) }
                )
            }

            commandRow("Desktop", systemImage: "desktopcomputer", command: .desktop)
            commandRow("Settings", systemImage: "gearshape", command: .settings)

            sectionDivider

            commandRow(
                "Task Manager",
                systemImage: "waveform.path.ecg.rectangle",
                command: .taskManager
            )

            sectionDivider

            commandRow("Taskbar settings", systemImage: "gearshape.2", command: .taskbarSettings)
        }
        .padding(.vertical, TaskbarContextMenuMetrics.verticalPadding)
        .frame(width: TaskbarContextMenuMetrics.width)
    }

    private func commandRow(
        _ title: String,
        systemImage: String,
        command: TaskbarContextMenuCommand
    ) -> some View {
        TaskbarJumpListRow(
            title: title,
            systemImage: systemImage,
            layout: TaskbarContextMenuMetrics.rowLayout,
            onHoverChanged: { hovering in
                if hovering { onDismissSubmenu() }
            },
            action: { onCommand(command) }
        )
    }

    private var sectionDivider: some View {
        Divider()
            .padding(.vertical, 4)
    }
}

struct TaskbarContextSubmenuView: View {
    let section: TaskbarContextMenuSection
    let terminals: [TaskbarTerminalMenuEntry]
    let actions: AppActions
    let onShowNested: (TaskbarContextNestedSection) -> Void
    let onDismissNested: () -> Void
    let onWindowCommand: (TaskbarWindowMenuCommand) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            switch section {
            case .terminal:
                ForEach(terminals) { terminal in
                    TaskbarJumpListRow(
                        title: terminal.title,
                        image: terminal.icon,
                        layout: TaskbarContextMenuMetrics.rowLayout
                    ) {
                        onDismiss()
                        actions.openApplication(at: terminal.url)
                    }
                }
            case .goTo:
                nestedRow("Folder", systemImage: "folder", section: .folders)
                shortcutRow("Go to Folder…", systemImage: "folder.badge.questionmark") {
                    actions.showFinderDialog(.goToFolder)
                }
                shortcutRow("Connect to Server…", systemImage: "network") {
                    actions.showFinderDialog(.connectToServer)
                }
                shortcutRow("Run…", systemImage: "arrow.up.forward.app") { actions.showRunDialog() }
                sectionDivider
                nestedRow("Settings", systemImage: "gearshape", section: .settings)
            case .apps:
                shortcutRow("Applications", systemImage: "square.grid.2x2") { actions.open(.applications) }
                folderRow("Utilities", systemImage: "wrench.and.screwdriver", path: "/Applications/Utilities")
                sectionDivider
                shortcutRow("Activity Monitor", systemImage: "waveform.path.ecg.rectangle") {
                    actions.open(.activityMonitor)
                }
                shortcutRow("Disk Utility", systemImage: "externaldrive") { actions.open(.diskUtility) }
                shortcutRow("Console", systemImage: "text.alignleft") { actions.open(.console) }
                shortcutRow("System Information", systemImage: "info.circle") {
                    actions.open(.systemInformation)
                }
            case .windows:
                windowRow("Cascade windows", systemImage: "rectangle.stack", command: .cascade)
                windowRow("Show windows stacked", systemImage: "rectangle.split.1x2", command: .stacked)
                windowRow("Show windows side by side", systemImage: "rectangle.split.2x1", command: .sideBySide)
                sectionDivider
                windowRow("Minimize all windows", systemImage: "rectangle.compress.vertical", command: .minimizeAll)
                windowRow("Restore all windows", systemImage: "rectangle.expand.vertical", command: .restoreAll)
            }
        }
        .padding(.vertical, TaskbarContextMenuMetrics.verticalPadding)
        .frame(maxWidth: .infinity)
    }

    private func folderRow(_ title: String, systemImage: String, path: String) -> some View {
        shortcutRow(title, systemImage: systemImage) {
            actions.openFolder(URL(
                fileURLWithPath: NSString(string: path).expandingTildeInPath,
                isDirectory: true
            ))
        }
    }

    private func shortcutRow(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        TaskbarJumpListRow(
            title: title,
            systemImage: systemImage,
            layout: TaskbarContextMenuMetrics.rowLayout,
            onHoverChanged: { hovering in
                if hovering { onDismissNested() }
            }
        ) {
            onDismiss()
            action()
        }
    }

    private func nestedRow(
        _ title: String,
        systemImage: String,
        section: TaskbarContextNestedSection
    ) -> some View {
        TaskbarJumpListRow(
            title: title,
            systemImage: systemImage,
            trailingSystemImage: "chevron.right",
            layout: TaskbarContextMenuMetrics.rowLayout,
            onHoverChanged: { hovering in
                if hovering { onShowNested(section) }
            },
            action: { onShowNested(section) }
        )
    }

    private func windowRow(
        _ title: String,
        systemImage: String,
        command: TaskbarWindowMenuCommand
    ) -> some View {
        TaskbarJumpListRow(
            title: title,
            systemImage: systemImage,
            layout: TaskbarContextMenuMetrics.rowLayout,
            onHoverChanged: { hovering in
                if hovering { onDismissNested() }
            },
            action: { onWindowCommand(command) }
        )
    }

    private var sectionDivider: some View {
        Divider().padding(.vertical, 4)
    }
}

struct TaskbarContextNestedMenuView: View {
    let section: TaskbarContextNestedSection
    let actions: AppActions
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            switch section {
            case .folders:
                folderRow("Macintosh HD", systemImage: "internaldrive", path: "/")
                folderRow("System", systemImage: "folder", path: "/System")
                folderRow("Library", systemImage: "folder", path: "/Library")
                folderRow("Applications", systemImage: "folder", path: "/Applications")
                folderRow("Utilities", systemImage: "folder", path: "/Applications/Utilities")
                folderRow("Users", systemImage: "folder", path: "/Users")
                sectionDivider
                folderRow("Home", systemImage: "house", path: NSHomeDirectory())
                folderRow("Desktop", systemImage: "desktopcomputer", path: "~/Desktop")
                folderRow("Downloads", systemImage: "arrow.down.circle", path: "~/Downloads")
                folderRow("Documents", systemImage: "doc", path: "~/Documents")
                folderRow("Pictures", systemImage: "photo", path: "~/Pictures")
                folderRow("Music", systemImage: "music.note", path: "~/Music")
                folderRow("Movies", systemImage: "film", path: "~/Movies")
                sectionDivider
                folderRow("User Library", systemImage: "folder", path: "~/Library")
                folderRow("Temporary", systemImage: "folder", path: NSTemporaryDirectory())
            case .settings:
                settingsRow("General", systemImage: "gearshape", destination: .generalSettings)
                settingsRow("About", systemImage: "info.circle", destination: .aboutThisMac)
                settingsRow("Displays", systemImage: "display", destination: .displaySettings)
                settingsRow("Network", systemImage: "network", destination: .networkSettings)
                settingsRow("Bluetooth", systemImage: "wave.3.right", destination: .bluetoothSettings)
                settingsRow("Sound", systemImage: "speaker.wave.2", destination: .soundSettings)
                settingsRow("Keyboard", systemImage: "keyboard", destination: .keyboardSettings)
                settingsRow(
                    "Privacy & Security",
                    systemImage: "hand.raised",
                    destination: .privacySecuritySettings
                )
            }
        }
        .padding(.vertical, TaskbarContextMenuMetrics.verticalPadding)
    }

    private func folderRow(_ title: String, systemImage: String, path: String) -> some View {
        row(title, systemImage: systemImage) {
            actions.openFolder(URL(
                fileURLWithPath: NSString(string: path).expandingTildeInPath,
                isDirectory: true
            ))
        }
    }

    private func settingsRow(
        _ title: String,
        systemImage: String,
        destination: SystemQuickAccess
    ) -> some View {
        row(title, systemImage: systemImage) { actions.open(destination) }
    }

    private func row(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        TaskbarJumpListRow(
            title: title,
            systemImage: systemImage,
            layout: TaskbarContextMenuMetrics.rowLayout
        ) {
            onDismiss()
            action()
        }
    }

    private var sectionDivider: some View {
        Divider().padding(.vertical, 4)
    }
}

struct TaskbarEmptyAreaContextClickAnchor: NSViewRepresentable {
    let onContextClick: @MainActor (CGPoint, NSWindow) -> Void

    func makeNSView(context: Context) -> TaskbarEmptyAreaContextClickView {
        let view = TaskbarEmptyAreaContextClickView()
        view.onContextClick = onContextClick
        return view
    }

    func updateNSView(_ nsView: TaskbarEmptyAreaContextClickView, context: Context) {
        nsView.onContextClick = onContextClick
    }
}

final class TaskbarEmptyAreaContextClickView: NSView {
    var onContextClick: (@MainActor (CGPoint, NSWindow) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        let isControlClick = event.type == .leftMouseDown && event.modifierFlags.contains(.control)
        return event.type == .rightMouseDown || isControlClick ? self : nil
    }

    override func rightMouseDown(with event: NSEvent) {
        showMenu(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.control) else { return }
        showMenu(for: event)
    }

    private func showMenu(for event: NSEvent) {
        guard let window else { return }
        onContextClick?(window.convertPoint(toScreen: event.locationInWindow), window)
    }
}
