import AppKit
import SwiftUI

struct TaskbarJumpListModel: Equatable {
    static let maximumShortcutCount = 8
    static let maximumRecentCount = 6

    let shortcuts: [PinnedShortcut]
    let recentDocuments: [RecentDocument]
    let isPinned: Bool
    let windowCount: Int

    var displayedShortcuts: [PinnedShortcut] {
        Array(shortcuts.prefix(Self.maximumShortcutCount))
    }

    var displayedRecentDocuments: [RecentDocument] {
        Array(recentDocuments.prefix(Self.maximumRecentCount))
    }

    var closeTitle: String {
        switch windowCount {
        case 0: "Close"
        case 1: "Close window"
        default: "Close all windows"
        }
    }

    var canClose: Bool { windowCount > 0 }
}

enum TaskbarJumpListMetrics {
    static let width: CGFloat = 292
    static let rowHeight: CGFloat = 34
    static let sectionHeaderHeight: CGFloat = 22
    static let dividerBlockHeight: CGFloat = 9
    static let verticalPadding: CGFloat = 8

    static func contentSize(shortcutCount: Int, recentCount: Int, isRunning: Bool) -> CGSize {
        let visibleShortcutCount = min(max(0, shortcutCount), TaskbarJumpListModel.maximumShortcutCount)
        let visibleRecentCount = min(max(0, recentCount), TaskbarJumpListModel.maximumRecentCount)
        let pinnedHeight = visibleShortcutCount > 0
            ? sectionHeaderHeight + CGFloat(visibleShortcutCount) * rowHeight + dividerBlockHeight
            : 0
        let recentHeight = visibleRecentCount > 0
            ? sectionHeaderHeight + CGFloat(visibleRecentCount) * rowHeight + dividerBlockHeight
            : 0
        let commandRows: CGFloat = 5
        let quitHeight = isRunning ? dividerBlockHeight + rowHeight : 0
        return CGSize(
            width: width,
            height: verticalPadding * 2 + recentHeight + pinnedHeight
                + commandRows * rowHeight + dividerBlockHeight + quitHeight
        )
    }
}

struct TaskbarJumpListGeometry {
    static let gap = StartMenuGeometry.taskbarGap
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

struct TaskbarJumpListInteractionPolicy {
    static func shouldDismissMenuOnAppHover(hovering: Bool) -> Bool {
        hovering
    }
}

enum TransientSurfaceDismissalPolicy {
    static func shouldDismissForOutsideInteraction(keepsVisibleForSettings: Bool) -> Bool {
        !keepsVisibleForSettings
    }
}

final class TaskbarJumpListPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class TaskbarJumpListController: ObservableObject {
    private var panel: TaskbarJumpListPanel?
    private let backdrop = NSVisualEffectView()
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var keepsVisibleForSettings = false
    private var preservesOnTrayItemMouseDown = false

    var onDismiss: (() -> Void)?
    var preservesOutsideMouseDown: (() -> Bool)?

    var isVisible: Bool { panel?.isVisible == true }
    var containsMouseLocation: Bool {
        panel?.isVisible == true && panel?.frame.contains(NSEvent.mouseLocation) == true
    }

    init() {
        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 10
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

    func show(
        rootView: AnyView,
        contentSize: CGSize,
        relativeTo anchorView: NSView,
        position: TaskbarPosition,
        preservesOnTrayItemMouseDown: Bool = false,
        cornerRadius: CGFloat = 10,
        showsBorder: Bool = true,
        makesKey: Bool = true
    ) {
        guard let anchorWindow = anchorView.window else { return }
        let windowRect = anchorView.convert(anchorView.bounds, to: nil)
        let anchorFrame = anchorWindow.convertToScreen(windowRect)
        let screenFrame = anchorWindow.screen?.frame ?? NSScreen.main?.frame ?? anchorFrame
        let targetFrame = TaskbarJumpListGeometry.frame(
            anchorFrame: anchorFrame,
            contentSize: contentSize,
            position: position,
            screenFrame: screenFrame
        )

        show(
            rootView: rootView,
            frame: targetFrame,
            appearance: anchorWindow.appearance,
            preservesOnTrayItemMouseDown: preservesOnTrayItemMouseDown,
            cornerRadius: cornerRadius,
            showsBorder: showsBorder,
            makesKey: makesKey
        )
    }

    func show(
        rootView: AnyView,
        frame: CGRect,
        appearance: NSAppearance?,
        preservesOnTrayItemMouseDown: Bool = false,
        cornerRadius: CGFloat = 10,
        showsBorder: Bool = true,
        makesKey: Bool = true
    ) {
        let panel = panel ?? makePanel()
        let wasVisible = panel.isVisible
        self.preservesOnTrayItemMouseDown = preservesOnTrayItemMouseDown
        hostingView.rootView = rootView
        backdrop.layer?.cornerRadius = cornerRadius
        backdrop.layer?.borderWidth = showsBorder ? 0.5 : 0
        panel.appearance = appearance
        panel.setFrame(frame, display: true)
        if !wasVisible {
            if makesKey {
                panel.makeKeyAndOrderFront(nil)
            } else {
                panel.orderFront(nil)
            }
            installEventMonitors()
        }
    }

    func dismiss() {
        panel?.orderOut(nil)
        preservesOnTrayItemMouseDown = false
        removeEventMonitors()
        onDismiss?()
    }

    func updateFrame(
        contentSize: CGSize,
        relativeTo anchorView: NSView,
        position: TaskbarPosition
    ) {
        guard let panel, panel.isVisible, let anchorWindow = anchorView.window else { return }
        let windowRect = anchorView.convert(anchorView.bounds, to: nil)
        let anchorFrame = anchorWindow.convertToScreen(windowRect)
        let screenFrame = anchorWindow.screen?.frame ?? NSScreen.main?.frame ?? anchorFrame
        panel.setFrame(
            TaskbarJumpListGeometry.frame(
                anchorFrame: anchorFrame,
                contentSize: contentSize,
                position: position,
                screenFrame: screenFrame
            ),
            display: true
        )
    }

    func setKeepsVisibleForSettings(_ keepsVisible: Bool) {
        keepsVisibleForSettings = keepsVisible
    }

    private func makePanel() -> TaskbarJumpListPanel {
        let panel = TaskbarJumpListPanel(
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
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.contentView = backdrop
        self.panel = panel
        return panel
    }

    private func installEventMonitors() {
        removeEventMonitors()
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                dismiss()
                return nil
            }
            if event.type != .keyDown,
               TransientSurfaceDismissalPolicy.shouldDismissForOutsideInteraction(
                   keepsVisibleForSettings: keepsVisibleForSettings
               ),
               let panel,
               !panel.frame.contains(NSEvent.mouseLocation) {
                if preservesOutsideMouseDown?() == true { return event }
                if preservesOnTrayItemMouseDown, isTrayItemMouseDown(event) { return event }
                dismiss()
            }
            return event
        }
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      TransientSurfaceDismissalPolicy.shouldDismissForOutsideInteraction(
                          keepsVisibleForSettings: self.keepsVisibleForSettings
                      ) else { return }
                self.dismiss()
            }
        }
    }

    private func removeEventMonitors() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }

    private func isTrayItemMouseDown(_ event: NSEvent) -> Bool {
        guard let window = event.window,
              let contentView = window.contentView else { return false }
        let point = contentView.convert(event.locationInWindow, from: nil)
        guard let control = contentView.hitTest(point) as? WindowsTrayIconControl else { return false }
        return control.preservesTransientPanelOnMouseDown
            || control.dragIdentifier != nil
            || control.onDrop != nil
    }
}

struct TaskbarContextClickAnchor: NSViewRepresentable {
    let onContextClick: @MainActor (NSView) -> Void

    func makeNSView(context: Context) -> TaskbarContextClickView {
        let view = TaskbarContextClickView()
        view.onContextClick = onContextClick
        return view
    }

    func updateNSView(_ nsView: TaskbarContextClickView, context: Context) {
        nsView.onContextClick = onContextClick
    }
}

final class TaskbarContextClickView: NSView {
    var onContextClick: (@MainActor (NSView) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        let isControlClick = event.type == .leftMouseDown && event.modifierFlags.contains(.control)
        return event.type == .rightMouseDown || isControlClick ? self : nil
    }

    override func rightMouseDown(with event: NSEvent) {
        onContextClick?(self)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.control) else { return }
        onContextClick?(self)
    }

    override func accessibilityPerformShowMenu() -> Bool {
        onContextClick?(self)
        return true
    }
}

struct TaskbarJumpListView: View {
    let item: TaskbarItem
    let model: TaskbarJumpListModel
    let onOpenApp: () -> Void
    let onOpenShortcut: (PinnedShortcut) -> Void
    let onOpenRecent: (RecentDocument) -> Void
    let onManageShortcuts: () -> Void
    let onShowInFinder: () -> Void
    let onTogglePin: () -> Void
    let onClose: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if !model.displayedRecentDocuments.isEmpty {
                sectionTitle("Recent")
                ForEach(model.displayedRecentDocuments) { document in
                    TaskbarJumpListRow(
                        title: document.label,
                        systemImage: document.url.isFileURL ? "folder" : "link",
                        action: { onOpenRecent(document) }
                    )
                }
                sectionDivider
            }

            if !model.displayedShortcuts.isEmpty {
                sectionTitle("Pinned")
                ForEach(model.displayedShortcuts) { shortcut in
                    TaskbarJumpListRow(
                        title: shortcut.name,
                        systemImage: shortcut.url?.isFileURL == true ? "doc" : "link",
                        action: { onOpenShortcut(shortcut) }
                    )
                }
                sectionDivider
            }

            TaskbarJumpListRow(
                title: "Manage Shortcuts…",
                systemImage: "slider.horizontal.3",
                action: onManageShortcuts
            )
            TaskbarJumpListRow(
                title: "Show in Finder",
                systemImage: "folder",
                action: onShowInFinder
            )

            sectionDivider

            TaskbarJumpListRow(title: item.name, image: item.icon, action: onOpenApp)
            TaskbarJumpListRow(
                title: model.isPinned ? "Unpin from taskbar" : "Pin to taskbar",
                systemImage: model.isPinned ? "pin.slash" : "pin",
                action: onTogglePin
            )
            TaskbarJumpListRow(
                title: model.closeTitle,
                systemImage: "xmark",
                isEnabled: model.canClose,
                action: onClose
            )

            if item.isRunning {
                sectionDivider
                TaskbarJumpListRow(
                    title: "Quit",
                    systemImage: "power",
                    action: onQuit
                )
            }
        }
        .padding(.vertical, TaskbarJumpListMetrics.verticalPadding)
        .frame(width: TaskbarJumpListMetrics.width)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .frame(height: TaskbarJumpListMetrics.sectionHeaderHeight)
    }

    private var sectionDivider: some View {
        Divider()
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
    }
}

struct TaskbarJumpListRow: View {
    struct Layout {
        var rowHeight = TaskbarJumpListMetrics.rowHeight
        var fontSize: CGFloat = 13
        var iconSize: CGFloat = 18
        var iconFontSize: CGFloat = 14
        var spacing: CGFloat = 10
        var contentHorizontalPadding: CGFloat = 10
        var outerHorizontalPadding: CGFloat = 4
        var trailingIconFontSize: CGFloat = 11
        var hoverCornerRadius: CGFloat = 5
    }

    let title: String
    var systemImage: String?
    var image: NSImage?
    var trailingSystemImage: String?
    var reservesIconSpace = true
    var isEnabled = true
    var layout = Layout()
    var onHoverChanged: ((Bool) -> Void)?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: layout.spacing) {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: layout.iconSize, height: layout.iconSize)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: layout.iconFontSize, weight: .regular))
                        .frame(width: layout.iconSize, height: layout.iconSize)
                } else if reservesIconSpace {
                    Color.clear.frame(width: layout.iconSize, height: layout.iconSize)
                }

                Text(title)
                    .font(.system(size: layout.fontSize, weight: .regular))
                    .lineLimit(1)
                Spacer(minLength: 8)

                if let trailingSystemImage {
                    Image(systemName: trailingSystemImage)
                        .font(.system(size: layout.trailingIconFontSize, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .padding(.horizontal, layout.contentHorizontalPadding)
            .frame(height: layout.rowHeight)
            .background(
                RoundedRectangle(cornerRadius: layout.hoverCornerRadius, style: .continuous)
                    .fill(isHovering && isEnabled ? Color.primary.opacity(0.10) : .clear)
            )
            .padding(.horizontal, layout.outerHorizontalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover {
            isHovering = $0
            onHoverChanged?($0)
        }
    }
}
