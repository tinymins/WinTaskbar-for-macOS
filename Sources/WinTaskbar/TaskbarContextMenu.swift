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
}

enum TaskbarContextMenuCommand {
    case desktop
    case settings
    case taskManager
    case taskbarSettings
}

struct TaskbarWindowMenuEntry: Identifiable {
    let window: WindowInfo
    let appName: String
    let icon: NSImage

    var id: CGWindowID { window.windowID }
    var title: String { window.title == "Window" ? appName : window.title }
}

enum TaskbarContextMenuMetrics {
    static let width: CGFloat = 200
    static let verticalPadding = TaskbarJumpListMetrics.verticalPadding
    static let rootRowCount: CGFloat = 8
    static let dividerCount: CGFloat = 2
    static let maximumWindowRows = 8

    static let rootSize = CGSize(
        width: width,
        height: verticalPadding * 2
            + rootRowCount * TaskbarJumpListMetrics.rowHeight
            + dividerCount * TaskbarJumpListMetrics.dividerBlockHeight
    )

    static func submenuSize(rowCount: Int) -> CGSize {
        CGSize(
            width: width,
            height: verticalPadding * 2
                + CGFloat(max(rowCount, 1)) * TaskbarJumpListMetrics.rowHeight
        )
    }
}

enum TaskbarContextMenuGeometry {
    static let submenuGap: CGFloat = 8
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
            - (CGFloat(rowIndex) + 0.5) * TaskbarJumpListMetrics.rowHeight
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
            onHoverChanged: { hovering in
                if hovering { onDismissSubmenu() }
            },
            action: { onCommand(command) }
        )
    }

    private var sectionDivider: some View {
        Divider()
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
    }
}

struct TaskbarContextSubmenuView: View {
    let section: TaskbarContextMenuSection
    let windows: [TaskbarWindowMenuEntry]
    let actions: AppActions
    let onOpenWindow: (WindowInfo) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            switch section {
            case .terminal:
                shortcutRow("Terminal", systemImage: "terminal") { actions.open(.terminal) }
                shortcutRow("Console", systemImage: "text.alignleft") { actions.open(.console) }
            case .goTo:
                folderRow("Home", systemImage: "house", path: NSHomeDirectory())
                folderRow("Desktop", systemImage: "desktopcomputer", path: "~/Desktop")
                folderRow("Documents", systemImage: "doc", path: "~/Documents")
                folderRow("Downloads", systemImage: "arrow.down.circle", path: "~/Downloads")
                folderRow("Applications", systemImage: "square.grid.2x2", path: "/Applications")
                folderRow("Utilities", systemImage: "wrench.and.screwdriver", path: "/Applications/Utilities")
            case .apps:
                shortcutRow("Applications", systemImage: "square.grid.2x2") { actions.open(.applications) }
                shortcutRow("System Settings", systemImage: "gearshape") { actions.open(.systemSettings) }
                shortcutRow("Activity Monitor", systemImage: "waveform.path.ecg.rectangle") {
                    actions.open(.activityMonitor)
                }
                shortcutRow("Disk Utility", systemImage: "externaldrive") { actions.open(.diskUtility) }
                shortcutRow("Console", systemImage: "text.alignleft") { actions.open(.console) }
            case .windows:
                if windows.isEmpty {
                    TaskbarJumpListRow(
                        title: "No open windows",
                        systemImage: "rectangle.on.rectangle.slash",
                        isEnabled: false,
                        action: {}
                    )
                } else {
                    ForEach(windows.prefix(TaskbarContextMenuMetrics.maximumWindowRows)) { entry in
                        TaskbarJumpListRow(title: entry.title, image: entry.icon) {
                            onDismiss()
                            onOpenWindow(entry.window)
                        }
                    }
                }
            }
        }
        .padding(.vertical, TaskbarContextMenuMetrics.verticalPadding)
        .frame(width: TaskbarContextMenuMetrics.width)
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
        TaskbarJumpListRow(title: title, systemImage: systemImage) {
            onDismiss()
            action()
        }
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
