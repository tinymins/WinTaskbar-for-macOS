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
    static let splitSegmentWidth: CGFloat = (tileSize.width - 1) / 2
    static let tileLabelHeight: CGFloat = 15
    static let volumeHeight: CGFloat = 72
    static let footerHeight: CGFloat = 48
    static let detailHeaderHeight: CGFloat = 52
    static let detailContentHeight: CGFloat = 233
}

enum WindowsVolumeSliderMetrics {
    static let trackHeight: CGFloat = 4
    static let thumbDiameter: CGFloat = 20
    static let normalIndicatorDiameter: CGFloat = 10
    static let pressedIndicatorDiameter: CGFloat = 8
    static let hitHeight: CGFloat = 28
}

enum WindowsVolumeSliderGeometry {
    static func thumbCenter(value: Double, width: CGFloat) -> CGFloat {
        let radius = WindowsVolumeSliderMetrics.thumbDiameter / 2
        let travel = max(0, width - WindowsVolumeSliderMetrics.thumbDiameter)
        return radius + CGFloat(min(max(value, 0), 1)) * travel
    }

    static func value(at location: CGFloat, width: CGFloat) -> Double {
        let radius = WindowsVolumeSliderMetrics.thumbDiameter / 2
        let travel = max(0, width - WindowsVolumeSliderMetrics.thumbDiameter)
        guard travel > 0 else { return 0 }
        return Double(min(max((location - radius) / travel, 0), 1))
    }
}

enum QuickSettingsPanelPage: Equatable {
    case root
    case wifi
    case bluetooth
    case accessibility
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
    @State private var page = QuickSettingsPanelPage.root
    @State private var pendingSSID: String?
    @State private var password = ""
    @State private var joinFailed = false

    var body: some View {
        VStack(spacing: 0) {
            switch page {
            case .root:
                rootPage
            case .wifi:
                wifiPage
            case .bluetooth:
                bluetoothPage
            case .accessibility:
                accessibilityPage
            }
        }
        .frame(width: QuickSettingsPanelMetrics.contentSize.width,
               height: QuickSettingsPanelMetrics.contentSize.height)
    }

    private var rootPage: some View {
        VStack(spacing: 0) {
            quickSettingsGrid
            Divider()
            volumeSection
            Divider()
            footer
        }
    }

    private var quickSettingsGrid: some View {
        VStack(spacing: 25) {
            HStack(spacing: 12) {
                QuickSettingTile(
                    label: service.wifiPoweredOn ? (service.wifiSSID ?? "Available") : "Wi-Fi off",
                    symbol: service.wifiPoweredOn ? "wifi" : "wifi.slash",
                    isActive: service.wifiPoweredOn,
                    primaryAction: { service.setWiFiPower(!service.wifiPoweredOn) },
                    detailAction: showWiFiPage,
                    showsInlineChevron: false
                )
                QuickSettingTile(
                    label: "Not connected",
                    symbol: "bluetooth",
                    isActive: true,
                    primaryAction: onOpenBluetoothSettings,
                    detailAction: { page = .bluetooth },
                    showsInlineChevron: false
                )
                QuickSettingTile(
                    label: "Airplane mode",
                    symbol: "airplane",
                    isActive: false,
                    primaryAction: {},
                    detailAction: nil,
                    showsInlineChevron: false
                )
            }
            HStack(spacing: 12) {
                QuickSettingTile(
                    label: "Accessibility",
                    symbol: "figure.arms.open",
                    isActive: false,
                    primaryAction: { page = .accessibility },
                    detailAction: nil,
                    showsInlineChevron: true
                )
                QuickSettingTile(
                    label: "Energy saver",
                    symbol: "leaf",
                    isActive: service.isLowPowerModeEnabled,
                    primaryAction: onOpenBatterySettings,
                    detailAction: nil,
                    showsInlineChevron: false
                )
                QuickSettingTile(
                    label: "Live captions",
                    symbol: "captions.bubble",
                    isActive: false,
                    primaryAction: onOpenAccessibilitySettings,
                    detailAction: nil,
                    showsInlineChevron: false
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

    private var volumeSection: some View {
        HStack(spacing: 12) {
            Button(action: service.toggleMute) {
                Image(systemName: volumeSymbol)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            WindowsVolumeSlider(
                value: Binding(
                    get: { Double(service.volume) },
                    set: { service.setVolume(Float($0)) }
                )
            )
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
    }

    private var footer: some View {
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

    private var wifiPage: some View {
        detailPage(title: "Wi-Fi", trailing: AnyView(wifiHeaderControls)) {
            Group {
                if service.wifiPoweredOn {
                    if let issue = service.wifiScanIssue {
                        wifiScanIssueView(issue)
                    } else {
                        wifiNetworkList
                    }
                } else {
                    DetailEmptyState(
                        symbol: "wifi.slash",
                        title: "Wi-Fi is off",
                        detail: "Turn on Wi-Fi to see available networks.",
                        actionTitle: "Turn on",
                        action: { service.setWiFiPower(true) }
                    )
                }
            }
        }
    }

    private var wifiHeaderControls: some View {
        HStack(spacing: 8) {
            Button {
                service.scanWiFi()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Scan for networks")
            Toggle(
                "",
                isOn: Binding(
                    get: { service.wifiPoweredOn },
                    set: { service.setWiFiPower($0) }
                )
            )
            .labelsHidden()
            .controlSize(.small)
        }
    }

    private var wifiNetworkList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                if service.isScanningWiFi && service.wifiNetworks.isEmpty {
                    ProgressView("Scanning…")
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else if service.wifiNetworks.isEmpty {
                    Text("No networks found")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    ForEach(service.wifiNetworks) { network in
                        wifiNetworkEntry(network)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
    }

    private func wifiScanIssueView(_ issue: WiFiScanIssue) -> some View {
        switch issue {
        case .locationAuthorizationRequired:
            return DetailEmptyState(
                symbol: "location",
                title: "Allow location access",
                detail: "macOS requires location access to list nearby Wi-Fi networks.",
                actionTitle: "Request Access",
                action: service.scanWiFi
            )
        case .locationPermissionDenied:
            return DetailEmptyState(
                symbol: "location.slash",
                title: "Location access is off",
                detail: "macOS requires location access to list nearby Wi-Fi networks.",
                actionTitle: "Open Location Settings",
                action: {
                    QuickSettingsDestination.open("com.apple.preference.security?Privacy_LocationServices")
                }
            )
        case .scanFailed:
            return DetailEmptyState(
                symbol: "wifi.exclamationmark",
                title: "Could not scan for networks",
                detail: "Check Wi-Fi and location access, then try again.",
                actionTitle: "Try again",
                action: service.scanWiFi
            )
        }
    }

    private func wifiNetworkEntry(_ network: WiFiNetworkInfo) -> some View {
        VStack(spacing: 0) {
            Button {
                joinFailed = false
                if service.wifiSSID == network.ssid {
                    service.disconnectWiFi()
                    pendingSSID = nil
                } else {
                    pendingSSID = network.ssid
                    password = ""
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: wifiSymbol(for: network.rssi))
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(network.ssid)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        if service.wifiSSID == network.ssid {
                            Text("Connected")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: service.wifiSSID == network.ssid ? "checkmark" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)

            if pendingSSID == network.ssid {
                VStack(spacing: 7) {
                    SecureField("Network password", text: $password)
                        .textFieldStyle(.roundedBorder)
                    if joinFailed {
                        Text("Could not connect. Check the password and try again.")
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack {
                        Button("Cancel") { pendingSSID = nil }
                        Spacer()
                        Button("Connect") {
                            if service.joinWiFi(
                                ssid: network.ssid,
                                password: password.isEmpty ? nil : password
                            ) {
                                pendingSSID = nil
                            } else {
                                joinFailed = true
                            }
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                    .controlSize(.small)
                }
                .padding(10)
            }
        }
    }

    private var bluetoothPage: some View {
        detailPage(title: "Bluetooth") {
            DetailActionList(
                rows: [
                    DetailActionRowData(
                        symbol: "antenna.radiowaves.left.and.right",
                        title: "Nearby and paired devices",
                        detail: "View and connect devices in System Settings."
                    )
                ],
                action: onOpenBluetoothSettings
            )
        }
    }

    private var accessibilityPage: some View {
        detailPage(title: "Accessibility") {
            DetailActionList(
                rows: [
                    DetailActionRowData(symbol: "speaker.wave.2", title: "VoiceOver", detail: "Screen reader settings"),
                    DetailActionRowData(symbol: "plus.magnifyingglass", title: "Zoom", detail: "Screen magnification settings"),
                    DetailActionRowData(symbol: "circle.lefthalf.filled", title: "Display", detail: "Visual accessibility settings"),
                ],
                action: onOpenAccessibilitySettings
            )
        }
    }

    private func detailPage<Content: View>(
        title: String,
        trailing: AnyView? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { page = .root } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let trailing { trailing }
            }
            .padding(.horizontal, 14)
            .frame(height: QuickSettingsPanelMetrics.detailHeaderHeight)
            Divider()
            content()
                .frame(height: QuickSettingsPanelMetrics.detailContentHeight)
            Divider()
            footer
        }
    }

    private func showWiFiPage() {
        page = .wifi
        pendingSSID = nil
        joinFailed = false
        Task { @MainActor in service.scanWiFi() }
    }

    private func wifiSymbol(for rssi: Int) -> String {
        rssi > -75 ? "wifi" : "wifi.exclamationmark"
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

private struct WindowsVolumeSlider: View {
    @Binding var value: Double
    @GestureState private var isPressed = false

    private let accent = Color(red: 0.35, green: 0.80, blue: 1)

    var body: some View {
        GeometryReader { proxy in
            let thumbCenter = WindowsVolumeSliderGeometry.thumbCenter(
                value: value,
                width: proxy.size.width
            )

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.16))
                    .frame(height: WindowsVolumeSliderMetrics.trackHeight)
                Capsule()
                    .fill(accent)
                    .frame(width: thumbCenter,
                           height: WindowsVolumeSliderMetrics.trackHeight)
                Circle()
                    .fill(Color.white.opacity(isPressed ? 0.20 : 0.16))
                    .frame(width: WindowsVolumeSliderMetrics.thumbDiameter,
                           height: WindowsVolumeSliderMetrics.thumbDiameter)
                    .overlay {
                        Circle()
                            .fill(accent.opacity(isPressed ? 0.82 : 1))
                            .frame(
                                width: isPressed
                                    ? WindowsVolumeSliderMetrics.pressedIndicatorDiameter
                                    : WindowsVolumeSliderMetrics.normalIndicatorDiameter,
                                height: isPressed
                                    ? WindowsVolumeSliderMetrics.pressedIndicatorDiameter
                                    : WindowsVolumeSliderMetrics.normalIndicatorDiameter
                            )
                    }
                    .offset(x: thumbCenter - WindowsVolumeSliderMetrics.thumbDiameter / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isPressed) { _, pressed, _ in pressed = true }
                    .onChanged { gesture in
                        value = WindowsVolumeSliderGeometry.value(
                            at: gesture.location.x,
                            width: proxy.size.width
                        )
                    }
            )
        }
        .frame(height: WindowsVolumeSliderMetrics.hitHeight)
        .animation(.easeOut(duration: 0.08), value: isPressed)
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                value = min(1, value + 0.05)
            case .decrement:
                value = max(0, value - 0.05)
            @unknown default:
                break
            }
        }
    }
}

private struct QuickSettingTile: View {
    let label: String
    let symbol: String
    let isActive: Bool
    let primaryAction: () -> Void
    let detailAction: (() -> Void)?
    let showsInlineChevron: Bool
    @State private var isPrimaryHovering = false
    @State private var isDetailHovering = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                Button(action: primaryAction) {
                    primaryContent
                        .frame(
                            width: detailAction == nil
                                ? QuickSettingsPanelMetrics.tileSize.width
                                : QuickSettingsPanelMetrics.splitSegmentWidth,
                            height: QuickSettingsPanelMetrics.tileSize.height
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(segmentBackground(isHovering: isPrimaryHovering))
                .onHover { isPrimaryHovering = $0 }
                .accessibilityLabel(primaryAccessibilityLabel)
                if let detailAction {
                    Divider()
                        .overlay(isActive ? Color.white.opacity(0.22) : Color.primary.opacity(0.12))
                        .frame(width: 1, height: QuickSettingsPanelMetrics.tileSize.height)
                    Button(action: detailAction) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(
                                width: QuickSettingsPanelMetrics.splitSegmentWidth,
                                height: QuickSettingsPanelMetrics.tileSize.height
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(segmentBackground(isHovering: isDetailHovering))
                    .onHover { isDetailHovering = $0 }
                    .accessibilityLabel("\(label) details")
                }
            }
            .foregroundStyle(isActive ? Color.black.opacity(0.88) : Color.primary)
            .frame(width: QuickSettingsPanelMetrics.tileSize.width,
                   height: QuickSettingsPanelMetrics.tileSize.height)
            .background(tileBackground, in: RoundedRectangle(cornerRadius: 5))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.primary.opacity(isActive ? 0 : 0.12), lineWidth: 0.5)
            }
            Text(label)
                .font(.system(size: 11))
                .lineLimit(1)
                .frame(width: QuickSettingsPanelMetrics.tileSize.width,
                       height: QuickSettingsPanelMetrics.tileLabelHeight)
        }
        .contentShape(Rectangle())
    }

    private var tileBackground: Color {
        if isActive { return Color(red: 0.25, green: 0.74, blue: 0.95) }
        return Color.primary.opacity(0.06)
    }

    private func segmentBackground(isHovering: Bool) -> Color {
        guard isHovering else { return .clear }
        if isActive { return Color(red: 0.65, green: 0.91, blue: 0.99) }
        return Color.primary.opacity(0.10)
    }

    private var primaryAccessibilityLabel: String {
        if showsInlineChevron { return "\(label) details" }
        if detailAction != nil { return "\(label) toggle" }
        return label
    }

    @ViewBuilder
    private var primaryContent: some View {
        if showsInlineChevron {
            HStack(spacing: 8) {
                tileIcon
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
            }
        } else {
            tileIcon
        }
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

private struct DetailEmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 24))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button(actionTitle, action: action)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DetailActionRowData {
    let symbol: String
    let title: String
    let detail: String
}

private struct DetailActionList: View {
    let rows: [DetailActionRowData]
    let action: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Button(action: action) {
                    HStack(spacing: 12) {
                        Image(systemName: row.symbol)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                                .font(.system(size: 12, weight: .medium))
                            Text(row.detail)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                    .contentShape(Rectangle())
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(10)
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
