import AppKit
import SwiftUI

enum StartButtonContextMenuMetrics {
    static let width: CGFloat = 240
    static let verticalPadding: CGFloat = 8
    static let dividerBlockHeight: CGFloat = 9
    static let rootRowCount: CGFloat = 17
    static let rootDividerCount: CGFloat = 2
    static let powerRowCount: CGFloat = 5

    static let rootSize = CGSize(
        width: width,
        height: verticalPadding * 2
            + rootRowCount * TaskbarJumpListMetrics.rowHeight
            + rootDividerCount * dividerBlockHeight
    )
    static let powerSize = CGSize(
        width: width,
        height: verticalPadding * 2
            + powerRowCount * TaskbarJumpListMetrics.rowHeight
            + dividerBlockHeight
    )
}

struct StartButtonPowerMenuGeometry {
    static let gap: CGFloat = 8
    static let screenInset: CGFloat = 8

    static func frame(parentFrame: CGRect, contentSize: CGSize, screenFrame: CGRect) -> CGRect {
        let rightX = parentFrame.maxX + gap
        let leftX = parentFrame.minX - gap - contentSize.width
        let x = rightX + contentSize.width <= screenFrame.maxX - screenInset ? rightX : leftX
        let minY = screenFrame.minY + screenInset
        let maxY = max(minY, screenFrame.maxY - screenInset - contentSize.height)
        return CGRect(
            x: x,
            y: min(max(parentFrame.minY, minY), maxY),
            width: contentSize.width,
            height: contentSize.height
        )
    }
}

struct StartButtonContextMenuView: View {
    let actions: AppActions
    let onDismiss: () -> Void
    let onShowPower: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            quickAccessRow(.applications)
            quickAccessRow(.battery)
            quickAccessRow(.console)
            quickAccessRow(.aboutThisMac)
            quickAccessRow(.systemInformation)
            quickAccessRow(.networkSettings)
            quickAccessRow(.diskUtility)
            quickAccessRow(.loginItems)
            quickAccessRow(.terminal)

            sectionDivider

            quickAccessRow(.activityMonitor)
            commandRow("Force Quit Applications…") { actions.showForceQuitApplications() }
            quickAccessRow(.systemSettings)
            commandRow("WinTaskbar Settings…") { actions.openSettings() }
            quickAccessRow(.finder)
            quickAccessRow(.spotlight)
            commandRow("Show Desktop") { actions.showDesktop() }

            sectionDivider

            TaskbarJumpListRow(
                title: "Power",
                trailingSystemImage: "chevron.right",
                reservesIconSpace: false,
                action: onShowPower
            )
        }
        .padding(.vertical, StartButtonContextMenuMetrics.verticalPadding)
        .frame(width: StartButtonContextMenuMetrics.width)
    }

    private func quickAccessRow(_ shortcut: SystemQuickAccess) -> some View {
        commandRow(shortcut.title) { actions.open(shortcut) }
    }

    private func commandRow(_ title: String, action: @escaping () -> Void) -> some View {
        TaskbarJumpListRow(title: title, reservesIconSpace: false) {
            onDismiss()
            action()
        }
    }

    private var sectionDivider: some View {
        Divider()
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
    }
}

struct StartButtonPowerMenuView: View {
    let actions: AppActions
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            powerRow(.lockScreen)
            powerRow(.sleep)
            powerRow(.logOut)
            sectionDivider
            powerRow(.restart)
            powerRow(.shutDown)
        }
        .padding(.vertical, StartButtonContextMenuMetrics.verticalPadding)
        .frame(width: StartButtonContextMenuMetrics.width)
    }

    private func powerRow(_ action: PowerAction) -> some View {
        TaskbarJumpListRow(title: action.rawValue, reservesIconSpace: false) {
            onDismiss()
            actions.performPower(action)
        }
    }

    private var sectionDivider: some View {
        Divider()
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
    }
}
