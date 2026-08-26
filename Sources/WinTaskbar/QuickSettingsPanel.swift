import AppKit
import SwiftUI

enum BatteryPresentationState: Equatable {
    case normal
    case charging
    case saver
    case critical

    static func resolve(level: Int, isCharging: Bool, isLowPowerModeEnabled: Bool) -> Self {
        if isCharging { return .charging }
        if level <= 6 { return .critical }
        if isLowPowerModeEnabled || level <= 20 { return .saver }
        return .normal
    }

    var color: Color {
        switch self {
        case .normal: .primary
        case .charging: Color(red: 0.18, green: 0.67, blue: 0.32)
        case .saver: Color(red: 0.93, green: 0.67, blue: 0.08)
        case .critical: Color(red: 0.86, green: 0.20, blue: 0.18)
        }
    }
}

enum QuickSettingsPanelMetrics {
    static let contentSize = CGSize(width: 360, height: 335)
    static let settingsGridHeight: CGFloat = 213
    static let tileSize = CGSize(width: 96, height: 47)
    static let tileLabelHeight: CGFloat = 15
    static let volumeHeight: CGFloat = 72
    static let footerHeight: CGFloat = 48
}

enum QuickSettingsPanelGeometry {
    static func frame(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        position: TaskbarPosition,
        barHeight: CGFloat
    ) -> CGRect {
        StartMenuGeometry.anchoredFrame(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            position: position,
            barHeight: barHeight,
            contentSize: QuickSettingsPanelMetrics.contentSize,
            oppositeEnd: true
        )
    }
}

@MainActor
final class QuickSettingsPanelController: ObservableObject {
    private let panelController = TaskbarJumpListController()
    private weak var anchorView: NSView?

    func attach(anchorView: NSView) {
        self.anchorView = anchorView
    }

    func toggle(
        service: SystemStatusService,
        actions: AppActions,
        position: TaskbarPosition,
        barHeight: CGFloat
    ) {
        if panelController.isVisible {
            dismiss()
            return
        }
        guard let anchorView,
              let anchorWindow = anchorView.window,
              let screen = anchorWindow.screen else { return }
        service.refresh()
        let rootView = QuickSettingsPanelView(
            service: service,
            onOpenBatterySettings: { [weak self, weak actions] in
                actions?.open(.battery)
                self?.dismiss()
            },
            onOpenSystemSettings: { [weak self, weak actions] in
                actions?.open(.systemSettings)
                self?.dismiss()
            },
            onOpenBluetoothSettings: { [weak self] in
                QuickSettingsDestination.open("com.apple.Bluetooth-Settings.extension")
                self?.dismiss()
            },
            onOpenAccessibilitySettings: { [weak self] in
                QuickSettingsDestination.open("com.apple.Accessibility-Settings.extension")
                self?.dismiss()
            }
        )
        panelController.show(
            rootView: AnyView(rootView),
            frame: QuickSettingsPanelGeometry.frame(
                screenFrame: screen.frame,
                visibleFrame: screen.visibleFrame,
                position: position,
                barHeight: barHeight
            ),
            appearance: NSAppearance(named: .darkAqua)
        )
    }

    func dismiss() {
        panelController.dismiss()
    }
}

private enum QuickSettingsDestination {
    static func open(_ settingsPaneIdentifier: String) {
        guard let url = URL(string: "x-apple.systempreferences:\(settingsPaneIdentifier)") else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct QuickSettingsPanelView: View {
    @ObservedObject var service: SystemStatusService
    let onOpenBatterySettings: () -> Void
    let onOpenSystemSettings: () -> Void
    let onOpenBluetoothSettings: () -> Void
    let onOpenAccessibilitySettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            quickSettingsGrid

            Divider()

            HStack(spacing: 12) {
                Button(action: service.toggleMute) {
                    Image(systemName: volumeSymbol)
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                Slider(
                    value: Binding(
                        get: { Double(service.volume) },
                        set: { service.setVolume(Float($0)) }
                    ),
                    in: 0...1
                )
                .controlSize(.small)
                .tint(.accentColor)
                Button(action: onOpenSystemSettings) {
                    HStack(spacing: 1) {
                        Image(systemName: "slider.horizontal.3")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: 12))
                    .frame(width: 31, height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Sound settings")
            }
            .padding(.leading, 19)
            .padding(.trailing, 10)
            .frame(height: QuickSettingsPanelMetrics.volumeHeight)

            Divider()

            HStack {
                if let level = service.batteryLevel {
                    Button(action: onOpenBatterySettings) {
                        HStack(spacing: 8) {
                            WindowsBatteryIcon(
                                level: level,
                                isCharging: service.isCharging,
                                state: batteryState
                            )
                            Text("\(level)%")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .monospacedDigit()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(service.isCharging ? "Battery charging" : "Battery")
                    .accessibilityLabel(service.isCharging ? "Battery charging, \(level)%" : "Battery, \(level)%")
                }
                Spacer()
                Button(action: onOpenSystemSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
            .padding(.horizontal, 16)
            .frame(height: QuickSettingsPanelMetrics.footerHeight)
            .background(Color.black.opacity(0.10))
        }
        .frame(width: QuickSettingsPanelMetrics.contentSize.width,
               height: QuickSettingsPanelMetrics.contentSize.height)
    }

    private var quickSettingsGrid: some View {
        VStack(spacing: 25) {
            HStack(spacing: 12) {
                QuickSettingTile(
                    label: service.wifiPoweredOn ? (service.wifiSSID ?? "Available") : "Wi-Fi off",
                    symbol: service.wifiPoweredOn ? "wifi" : "wifi.slash",
                    isActive: service.wifiPoweredOn,
                    isSplit: true,
                    action: { service.setWiFiPower(!service.wifiPoweredOn) }
                )
                QuickSettingTile(
                    label: "Not connected",
                    symbol: "bluetooth",
                    isActive: true,
                    isSplit: true,
                    action: onOpenBluetoothSettings
                )
                QuickSettingTile(
                    label: "Airplane mode",
                    symbol: "airplane",
                    isActive: false,
                    isSplit: false,
                    action: {}
                )
            }
            HStack(spacing: 12) {
                QuickSettingTile(
                    label: "Accessibility",
                    symbol: "figure.arms.open",
                    isActive: false,
                    isSplit: true,
                    action: onOpenAccessibilitySettings
                )
                QuickSettingTile(
                    label: "Energy saver",
                    symbol: "leaf",
                    isActive: service.isLowPowerModeEnabled,
                    isSplit: false,
                    action: onOpenBatterySettings
                )
                QuickSettingTile(
                    label: "Live captions",
                    symbol: "captions.bubble",
                    isActive: false,
                    isSplit: false,
                    action: onOpenAccessibilitySettings
                )
            }
        }
        .padding(.horizontal, 24)
        .frame(height: QuickSettingsPanelMetrics.settingsGridHeight)
        .overlay(alignment: .trailing) {
            VStack(spacing: 5) {
                Circle().frame(width: 5, height: 5)
                Circle().frame(width: 5, height: 5).opacity(0.45)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(.secondary)
            .padding(.trailing, 9)
        }
    }

    private var volumeSymbol: String {
        if service.isMuted || service.volume == 0 { return "speaker.slash.fill" }
        if service.volume < 0.35 { return "speaker.wave.1.fill" }
        if service.volume < 0.7 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private var batteryState: BatteryPresentationState {
        .resolve(
            level: service.batteryLevel ?? 0,
            isCharging: service.isCharging,
            isLowPowerModeEnabled: service.isLowPowerModeEnabled
        )
    }
}

private struct QuickSettingTile: View {
    let label: String
    let symbol: String
    let isActive: Bool
    let isSplit: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    HStack(spacing: 0) {
                        tileIcon
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if isSplit {
                            Divider()
                                .overlay(isActive ? Color.white.opacity(0.22) : Color.primary.opacity(0.12))
                                .frame(width: 1, height: QuickSettingsPanelMetrics.tileSize.height)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .frame(width: 31, height: QuickSettingsPanelMetrics.tileSize.height)
                        }
                    }
                    .foregroundStyle(isActive ? Color.black.opacity(0.88) : Color.primary)
                    .frame(width: QuickSettingsPanelMetrics.tileSize.width,
                           height: QuickSettingsPanelMetrics.tileSize.height)
                    .background(tileBackground, in: RoundedRectangle(cornerRadius: 5))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.primary.opacity(isActive ? 0 : 0.12), lineWidth: 0.5)
                    }
                }
                Text(label)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .frame(width: QuickSettingsPanelMetrics.tileSize.width,
                           height: QuickSettingsPanelMetrics.tileLabelHeight)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(label)
    }

    private var tileBackground: Color {
        if isActive { return Color(red: 0.25, green: 0.74, blue: 0.95).opacity(isHovering ? 0.86 : 1) }
        return Color.primary.opacity(isHovering ? 0.10 : 0.06)
    }

    @ViewBuilder
    private var tileIcon: some View {
        if symbol == "bluetooth" {
            BluetoothGlyph()
                .stroke(lineWidth: 1.2)
                .frame(width: 12, height: 17)
        } else {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
        }
    }
}

private struct BluetoothGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let midX = rect.midX
        let top = rect.minY
        let bottom = rect.maxY
        let middle = rect.midY
        let left = rect.minX
        let right = rect.maxX
        let upperQuarter = rect.minY + rect.height * 0.25
        let lowerQuarter = rect.minY + rect.height * 0.75
        var path = Path()
        path.move(to: CGPoint(x: midX, y: top))
        path.addLine(to: CGPoint(x: midX, y: bottom))
        path.move(to: CGPoint(x: midX, y: top))
        path.addLine(to: CGPoint(x: right, y: upperQuarter))
        path.addLine(to: CGPoint(x: midX, y: middle))
        path.addLine(to: CGPoint(x: right, y: lowerQuarter))
        path.addLine(to: CGPoint(x: midX, y: bottom))
        path.move(to: CGPoint(x: left, y: upperQuarter))
        path.addLine(to: CGPoint(x: right, y: lowerQuarter))
        path.move(to: CGPoint(x: left, y: lowerQuarter))
        path.addLine(to: CGPoint(x: right, y: upperQuarter))
        return path
    }
}

struct WindowsBatteryIcon: View {
    let level: Int
    let isCharging: Bool
    let state: BatteryPresentationState

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(state.color, lineWidth: 1.2)
                RoundedRectangle(cornerRadius: 1)
                    .fill(state.color)
                    .padding(2.2)
                    .scaleEffect(x: CGFloat(max(0, min(level, 100))) / 100, y: 1, anchor: .leading)
                if isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 6, weight: .bold))
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 17, height: 10)
            Capsule()
                .fill(state.color)
                .frame(width: 2, height: 5)
        }
        .frame(width: 20, height: 12)
        .accessibilityHidden(true)
    }
}

private struct QuickSettingsPanelAnchor: NSViewRepresentable {
    let onAttach: @MainActor (NSView) -> Void

    func makeNSView(context: Context) -> QuickSettingsPanelAnchorView {
        let view = QuickSettingsPanelAnchorView()
        onAttach(view)
        return view
    }

    func updateNSView(_ nsView: QuickSettingsPanelAnchorView, context: Context) {
        onAttach(nsView)
    }
}

private final class QuickSettingsPanelAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension View {
    func quickSettingsPanelAnchor(controller: QuickSettingsPanelController) -> some View {
        background(QuickSettingsPanelAnchor(onAttach: controller.attach(anchorView:)))
    }
}
