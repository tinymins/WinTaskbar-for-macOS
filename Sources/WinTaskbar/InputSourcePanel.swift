import AppKit
import SwiftUI

enum InputSourcePanelMetrics {
    static let width: CGFloat = 360
    static let headerHeight: CGFloat = 52
    static let rowHeight: CGFloat = 48
    static let rowSpacing: CGFloat = 2
    static let listVerticalPadding: CGFloat = 8
    static let footerHeight: CGFloat = 48
    static let dividerHeight: CGFloat = 1
    static let maximumVisibleRows = 5

    static func contentSize(inputSourceCount: Int) -> CGSize {
        let visibleRows = min(max(inputSourceCount, 1), maximumVisibleRows)
        let listHeight = CGFloat(visibleRows) * rowHeight
            + CGFloat(max(visibleRows - 1, 0)) * rowSpacing
            + listVerticalPadding * 2
        return CGSize(
            width: width,
            height: headerHeight + listHeight + dividerHeight + footerHeight
        )
    }
}

enum InputSourcePanelGeometry {
    static func frame(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        position: TaskbarPosition,
        barHeight: CGFloat,
        contentSize: CGSize
    ) -> CGRect {
        StartMenuGeometry.anchoredFrame(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            position: position,
            barHeight: barHeight,
            contentSize: contentSize,
            oppositeEnd: true
        )
    }
}

@MainActor
final class InputSourcePanelController: ObservableObject {
    private let panelController = TaskbarJumpListController()

    var isVisible: Bool { panelController.isVisible }

    func toggle(
        service: SystemStatusService,
        position: TaskbarPosition,
        barHeight: CGFloat,
        screen: NSScreen,
        appearance: NSAppearance?
    ) {
        if panelController.isVisible {
            dismiss()
            return
        }
        present(
            service: service,
            position: position,
            barHeight: barHeight,
            screen: screen,
            appearance: appearance
        )
    }

    func show(
        service: SystemStatusService,
        position: TaskbarPosition,
        barHeight: CGFloat,
        screen: NSScreen,
        appearance: NSAppearance?
    ) {
        present(
            service: service,
            position: position,
            barHeight: barHeight,
            screen: screen,
            appearance: appearance
        )
    }

    func advance(service: SystemStatusService) {
        service.selectNextInputSource()
    }

    func retreat(service: SystemStatusService) {
        service.selectPreviousInputSource()
    }

    private func present(
        service: SystemStatusService,
        position: TaskbarPosition,
        barHeight: CGFloat,
        screen: NSScreen,
        appearance: NSAppearance?
    ) {
        let contentSize = InputSourcePanelMetrics.contentSize(inputSourceCount: service.inputSources.count)
        let rootView = InputSourcePanelView(
            service: service,
            onSelect: { [weak self, weak service] sourceID in
                service?.selectInputSource(id: sourceID)
                self?.dismiss()
            },
            onOpenSettings: { [weak self] in
                InputSourceSettings.open()
                self?.dismiss()
            }
        )
        panelController.show(
            rootView: AnyView(rootView),
            frame: InputSourcePanelGeometry.frame(
                screenFrame: screen.frame,
                visibleFrame: screen.visibleFrame,
                position: position,
                barHeight: barHeight,
                contentSize: contentSize
            ),
            appearance: appearance
        )
    }

    func dismiss() {
        panelController.dismiss()
    }

    func setKeepsVisibleForSettings(_ keepsVisible: Bool) {
        panelController.setKeepsVisibleForSettings(keepsVisible)
    }
}

private enum InputSourceSettings {
    static func open() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard") else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct InputSourcePanelView: View {
    @ObservedObject var service: SystemStatusService
    let onSelect: (String) -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            sourceList
            Divider()
            InputSourceSettingsButton(action: onOpenSettings)
        }
        .frame(width: InputSourcePanelMetrics.width)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Keyboard layout")
                .font(.system(size: 13, weight: .semibold))
            shortcutKey("⌃", width: 21)
            Text("+")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            shortcutKey("Space", width: 42)
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: InputSourcePanelMetrics.headerHeight)
    }

    private var sourceList: some View {
        ScrollView {
            LazyVStack(spacing: InputSourcePanelMetrics.rowSpacing) {
                if service.inputSources.isEmpty {
                    Text("No input sources")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: InputSourcePanelMetrics.rowHeight)
                } else {
                    ForEach(service.inputSources) { source in
                        InputSourceRow(
                            source: source,
                            isSelected: source.id == service.inputSourceID,
                            action: { onSelect(source.id) }
                        )
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, InputSourcePanelMetrics.listVerticalPadding)
        }
        .scrollIndicators(.hidden)
        .frame(height: InputSourcePanelMetrics.contentSize(inputSourceCount: service.inputSources.count).height
            - InputSourcePanelMetrics.headerHeight
            - InputSourcePanelMetrics.footerHeight
            - InputSourcePanelMetrics.dividerHeight)
    }

    private func shortcutKey(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: width, height: 19)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 3))
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.primary.opacity(0.16), lineWidth: 0.5)
            }
    }
}

private struct InputSourceRow: View {
    let source: InputSourceOption
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                sourceMark
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.displayName)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    if let detail = source.detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: InputSourcePanelMetrics.rowHeight, alignment: .leading)
            .contentShape(Rectangle())
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 4))
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 3, height: 24)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(source.detail.map { "\(source.displayName), \($0)" } ?? source.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var sourceMark: some View {
        if let iconURL = source.iconURL,
           let image = NSImage(contentsOf: iconURL) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 22, height: 22)
        } else {
            Text(source.abbreviation)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
        }
    }

    private var rowBackground: Color {
        if isSelected { return Color.primary.opacity(0.10) }
        if isHovering { return Color.primary.opacity(0.06) }
        return .clear
    }
}

private struct InputSourceSettingsButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text("More keyboard settings")
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .contentShape(Rectangle())
                .background(isHovering ? Color.primary.opacity(0.06) : .clear)
        }
        .buttonStyle(.plain)
        .frame(height: InputSourcePanelMetrics.footerHeight)
        .onHover { isHovering = $0 }
    }
}
