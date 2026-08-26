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
    static let contentSize = CGSize(width: 360, height: 246)
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
            appearance: anchorWindow.appearance
        )
    }

    func dismiss() {
        panelController.dismiss()
    }
}

private struct QuickSettingsPanelView: View {
    @ObservedObject var service: SystemStatusService
    let onOpenBatterySettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                QuickSettingTile(
                    title: "Wi-Fi",
                    detail: service.wifiPoweredOn ? (service.wifiSSID ?? "Available") : "Off",
                    symbol: service.wifiPoweredOn ? "wifi" : "wifi.slash",
                    isActive: service.wifiPoweredOn,
                    action: { service.setWiFiPower(!service.wifiPoweredOn) }
                )
                QuickSettingTile(
                    title: "Sound",
                    detail: service.isMuted ? "Muted" : "\(Int((service.volume * 100).rounded()))%",
                    symbol: volumeSymbol,
                    isActive: !service.isMuted,
                    action: service.toggleMute
                )
                QuickSettingTile(
                    title: "Energy saver",
                    detail: service.isLowPowerModeEnabled ? "On" : "Off",
                    symbol: "leaf.fill",
                    isActive: service.isLowPowerModeEnabled,
                    action: onOpenBatterySettings
                )
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 14)

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
            }
            .padding(.horizontal, 18)
            .frame(height: 68)

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
                }
                Spacer()
                Button(action: onOpenBatterySettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Battery settings")
            }
            .padding(.horizontal, 18)
            .frame(height: 54)
        }
        .frame(width: QuickSettingsPanelMetrics.contentSize.width,
               height: QuickSettingsPanelMetrics.contentSize.height)
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
    let title: String
    let detail: String
    let symbol: String
    let isActive: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 26, height: 22, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(isActive ? Color.white.opacity(0.78) : Color.secondary)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(isActive ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            .contentShape(Rectangle())
            .background(tileBackground, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(isActive ? 0 : 0.12), lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityValue(detail)
    }

    private var tileBackground: Color {
        if isActive { return Color.accentColor.opacity(isHovering ? 0.86 : 1) }
        return Color.primary.opacity(isHovering ? 0.10 : 0.06)
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
