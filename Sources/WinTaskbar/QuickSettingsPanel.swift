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
    static let splitDividerOpacity: Double = 0.08
    static let tileLabelHeight: CGFloat = 15
    static let volumeHeight: CGFloat = 72
    static let footerHeight: CGFloat = 48
    static let footerLeadingPadding: CGFloat = 24
    static let footerTrailingPadding: CGFloat = 16
    static let settingsPageCount = 2
    static let detailHeaderHeight: CGFloat = 52
    static let detailContentHeight: CGFloat = 233
    static let detailBackButtonSize: CGFloat = 40
    static let detailBackButtonCornerRadius: CGFloat = 4
    static let accessibilityRowHeight: CGFloat = 55
    static let accessibilityIconColumnWidth: CGFloat = 22
    static let accessibilityStatusColumnWidth: CGFloat = 24
    static let accessibilityToggleSize = CGSize(width: 40, height: 20)
}

enum QuickSettingsPageNavigation {
    static func targetPage(currentPage: Int, deltaY: CGFloat, pageCount: Int) -> Int {
        guard deltaY != 0, pageCount > 0 else { return currentPage }
        let requestedPage = currentPage + (deltaY < 0 ? 1 : -1)
        return min(max(requestedPage, 0), pageCount - 1)
    }
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

enum QuickSettingsPanelOpeningPolicy {
    static func shouldPresent(isVisible: Bool) -> Bool {
        !isVisible
    }
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

    var isVisible: Bool { panelController.isVisible }

    func presentIfNeeded(
        service: SystemStatusService,
        actions: AppActions,
        position: TaskbarPosition,
        barHeight: CGFloat,
        screen: NSScreen
    ) {
        guard QuickSettingsPanelOpeningPolicy.shouldPresent(isVisible: isVisible) else { return }
        present(
            service: service,
            actions: actions,
            position: position,
            barHeight: barHeight,
            screen: screen
        )
    }

    func toggle(
        service: SystemStatusService,
        actions: AppActions,
        position: TaskbarPosition,
        barHeight: CGFloat,
        screen: NSScreen
    ) {
        if panelController.isVisible {
            dismiss()
            return
        }
        present(
            service: service,
            actions: actions,
            position: position,
            barHeight: barHeight,
            screen: screen
        )
    }

    private func present(
        service: SystemStatusService,
        actions: AppActions,
        position: TaskbarPosition,
        barHeight: CGFloat,
        screen: NSScreen
    ) {
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
            appearance: NSAppearance(named: .darkAqua),
            preservesOnTrayItemMouseDown: true
        )
    }

    func dismiss() {
        panelController.dismiss()
    }

    func setKeepsVisibleForSettings(_ keepsVisible: Bool) {
        panelController.setKeepsVisibleForSettings(keepsVisible)
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
    @State private var isDetailBackHovering = false
    @State private var settingsPage = 0
    @State private var lastSettingsPageChange = Date.distantPast

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
        VStack(spacing: 0) {
            quickSettingsPageOne
                .frame(height: QuickSettingsPanelMetrics.settingsGridHeight)
                .accessibilityHidden(settingsPage != 0)
            quickSettingsPageTwo
                .frame(height: QuickSettingsPanelMetrics.settingsGridHeight)
                .accessibilityHidden(settingsPage != 1)
        }
        .offset(y: -CGFloat(settingsPage) * QuickSettingsPanelMetrics.settingsGridHeight)
        .frame(height: QuickSettingsPanelMetrics.settingsGridHeight, alignment: .top)
        .clipped()
        .background {
            QuickSettingsScrollMonitor(onScroll: handleQuickSettingsScroll)
        }
        .overlay(alignment: .trailing) {
            settingsPageIndicator
                .padding(.trailing, 6)
        }
        .animation(.easeInOut(duration: 0.18), value: settingsPage)
    }

    private var quickSettingsPageOne: some View {
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
    }

    private var quickSettingsPageTwo: some View {
        VStack(spacing: 25) {
            HStack(spacing: 12) {
                QuickSettingTile(
                    label: "Night light",
                    symbol: "sun.max",
                    isActive: false,
                    primaryAction: {
                        QuickSettingsDestination.open("com.apple.Displays-Settings.extension")
                    },
                    detailAction: nil,
                    showsInlineChevron: false
                )
                QuickSettingTile(
                    label: "Mobile hotspot",
                    symbol: "antenna.radiowaves.left.and.right",
                    isActive: false,
                    primaryAction: {
                        QuickSettingsDestination.open("com.apple.Sharing-Settings.extension")
                    },
                    detailAction: nil,
                    showsInlineChevron: false
                )
                QuickSettingTile(
                    label: "Nearby sharing",
                    symbol: "square.and.arrow.up",
                    isActive: false,
                    primaryAction: {
                        QuickSettingsDestination.open("com.apple.Sharing-Settings.extension")
                    },
                    detailAction: nil,
                    showsInlineChevron: false
                )
            }
            HStack(spacing: 12) {
                QuickSettingTile(
                    label: "Wired display",
                    symbol: "rectangle.on.rectangle",
                    isActive: false,
                    primaryAction: {
                        QuickSettingsDestination.open("com.apple.Displays-Settings.extension")
                    },
                    detailAction: nil,
                    showsInlineChevron: true
                )
                QuickSettingTile(
                    label: "Project",
                    symbol: "rectangle.on.rectangle.angled",
                    isActive: false,
                    primaryAction: {
                        QuickSettingsDestination.open("com.apple.Displays-Settings.extension")
                    },
                    detailAction: nil,
                    showsInlineChevron: true
                )
                Color.clear
                    .frame(width: QuickSettingsPanelMetrics.tileSize.width,
                           height: QuickSettingsPanelMetrics.tileSize.height
                                + 8 + QuickSettingsPanelMetrics.tileLabelHeight)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 24)
    }

    private var settingsPageIndicator: some View {
        VStack(spacing: 5) {
            if settingsPage > 0 {
                settingsPageArrow(symbol: "chevron.up", page: settingsPage - 1)
            }
            Button { showSettingsPage(0) } label: {
                Circle()
                    .frame(width: 5, height: 5)
                    .opacity(settingsPage == 0 ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Quick settings page 1")
            Button { showSettingsPage(1) } label: {
                Circle()
                    .frame(width: 5, height: 5)
                    .opacity(settingsPage == 1 ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Quick settings page 2")
            if settingsPage < QuickSettingsPanelMetrics.settingsPageCount - 1 {
                settingsPageArrow(symbol: "chevron.down", page: settingsPage + 1)
            }
        }
        .foregroundStyle(.secondary)
    }

    private func settingsPageArrow(symbol: String, page: Int) -> some View {
        Button { showSettingsPage(page) } label: {
            Image(systemName: symbol)
                .font(.system(size: 7, weight: .bold))
                .frame(width: 10, height: 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(page == 0 ? "Previous quick settings page" : "Next quick settings page")
    }

    private func handleQuickSettingsScroll(_ deltaY: CGFloat) {
        guard abs(deltaY) > 0.1 else { return }
        let targetPage = QuickSettingsPageNavigation.targetPage(
            currentPage: settingsPage,
            deltaY: deltaY,
            pageCount: QuickSettingsPanelMetrics.settingsPageCount
        )
        guard targetPage != settingsPage,
              Date().timeIntervalSince(lastSettingsPageChange) >= 0.35 else { return }
        showSettingsPage(targetPage)
    }

    private func showSettingsPage(_ requestedPage: Int) {
        let pageRange = 0..<QuickSettingsPanelMetrics.settingsPageCount
        guard pageRange.contains(requestedPage), requestedPage != settingsPage else { return }
        lastSettingsPageChange = Date()
        settingsPage = requestedPage
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
        .padding(.leading, QuickSettingsPanelMetrics.footerLeadingPadding)
        .padding(.trailing, QuickSettingsPanelMetrics.footerTrailingPadding)
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
        detailPage(
            title: "Accessibility",
            footerContent: AnyView(accessibilityFooter)
        ) {
            AccessibilitySettingsList(action: onOpenAccessibilitySettings)
        }
    }

    private var accessibilityFooter: some View {
        Button(action: onOpenAccessibilitySettings) {
            HStack {
                Text("More Accessibility settings")
                    .font(.system(size: 11))
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: QuickSettingsPanelMetrics.footerHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.black.opacity(0.10))
    }

    private func detailPage<Content: View>(
        title: String,
        trailing: AnyView? = nil,
        footerContent: AnyView? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button { page = .root } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(
                            width: QuickSettingsPanelMetrics.detailBackButtonSize,
                            height: QuickSettingsPanelMetrics.detailBackButtonSize
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    isDetailBackHovering ? Color.primary.opacity(0.08) : .clear,
                    in: RoundedRectangle(
                        cornerRadius: QuickSettingsPanelMetrics.detailBackButtonCornerRadius
                    )
                )
                .onHover { isDetailBackHovering = $0 }
                .accessibilityLabel("Back")
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let trailing { trailing }
            }
            .padding(.leading, 6)
            .padding(.trailing, 14)
            .frame(height: QuickSettingsPanelMetrics.detailHeaderHeight)
            Divider()
            content()
                .frame(height: QuickSettingsPanelMetrics.detailContentHeight)
            Divider()
            if let footerContent {
                footerContent
            } else {
                footer
            }
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
            ZStack(alignment: .leading) {
                if isPrimaryHovering {
                    Rectangle()
                        .fill(segmentHoverColor)
                        .frame(
                            width: detailAction == nil
                                ? QuickSettingsPanelMetrics.tileSize.width
                                : QuickSettingsPanelMetrics.splitSegmentWidth,
                            height: QuickSettingsPanelMetrics.tileSize.height
                        )
                        .allowsHitTesting(false)
                }
                if isDetailHovering {
                    Rectangle()
                        .fill(segmentHoverColor)
                        .frame(
                            width: QuickSettingsPanelMetrics.splitSegmentWidth,
                            height: QuickSettingsPanelMetrics.tileSize.height
                        )
                        .offset(x: QuickSettingsPanelMetrics.splitSegmentWidth + 1)
                        .allowsHitTesting(false)
                }
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
                    .onHover { isPrimaryHovering = $0 }
                    .accessibilityLabel(primaryAccessibilityLabel)
                    if let detailAction {
                        Rectangle()
                            .fill(Color.white.opacity(QuickSettingsPanelMetrics.splitDividerOpacity))
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
                        .onHover { isDetailHovering = $0 }
                        .accessibilityLabel("\(label) details")
                    }
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

    private var segmentHoverColor: Color {
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

private struct AccessibilitySettingRowData: Identifiable {
    let id: String
    let symbol: String
    let title: String
    let detail: String
}

private struct AccessibilitySettingSection: Identifiable {
    let id: String
    let title: String
    let rows: [AccessibilitySettingRowData]
}

private struct AccessibilitySettingsList: View {
    let action: () -> Void

    private let sections = [
        AccessibilitySettingSection(
            id: "vision",
            title: "Vision",
            rows: [
                AccessibilitySettingRowData(
                    id: "magnifier",
                    symbol: "plus.magnifyingglass",
                    title: "Magnifier",
                    detail: "See words and images better"
                ),
                AccessibilitySettingRowData(
                    id: "narrator",
                    symbol: "speaker.wave.2",
                    title: "Narrator",
                    detail: "Your built-in screen reader"
                ),
                AccessibilitySettingRowData(
                    id: "color-filters",
                    symbol: "paintpalette",
                    title: "Color filters",
                    detail: "Distinguish among colors easily"
                ),
            ]
        ),
        AccessibilitySettingSection(
            id: "hearing",
            title: "Hearing",
            rows: [
                AccessibilitySettingRowData(
                    id: "live-captions",
                    symbol: "captions.bubble",
                    title: "Live captions",
                    detail: "Real time audio transcription"
                ),
                AccessibilitySettingRowData(
                    id: "mono-audio",
                    symbol: "speaker.wave.2",
                    title: "Mono audio",
                    detail: "Combine left and right audio channels"
                ),
            ]
        ),
        AccessibilitySettingSection(
            id: "motor-mobility",
            title: "Motor and Mobility",
            rows: [
                AccessibilitySettingRowData(
                    id: "voice-access",
                    symbol: "waveform.and.mic",
                    title: "Voice access",
                    detail: "Interact with your PC using voice"
                ),
                AccessibilitySettingRowData(
                    id: "sticky-keys",
                    symbol: "keyboard",
                    title: "Sticky keys",
                    detail: "Use shortcuts one key at a time"
                ),
            ]
        ),
    ]

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(sections) { section in
                    Text(section.title)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 34, alignment: .bottom)
                        .padding(.horizontal, 16)
                    ForEach(section.rows) { row in
                        AccessibilitySettingRow(row: row, action: action)
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }
}

private struct AccessibilitySettingRow: View {
    let row: AccessibilitySettingRowData
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Image(systemName: row.symbol)
                    .font(.system(size: 13))
                    .frame(width: QuickSettingsPanelMetrics.accessibilityIconColumnWidth)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.system(size: 12, weight: .medium))
                    Text(row.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.leading, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("Off")
                    .font(.system(size: 11))
                    .frame(
                        width: QuickSettingsPanelMetrics.accessibilityStatusColumnWidth,
                        alignment: .trailing
                    )
                WindowsToggleIndicator()
                    .padding(.leading, 8)
            }
            .padding(.horizontal, 16)
            .frame(height: QuickSettingsPanelMetrics.accessibilityRowHeight)
            .contentShape(Rectangle())
            .background(
                isHovering ? Color.primary.opacity(0.06) : .clear,
                in: RoundedRectangle(cornerRadius: 4)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(row.title), Off, \(row.detail)")
        .help("Open Accessibility settings")
    }
}

private struct WindowsToggleIndicator: View {
    var body: some View {
        Capsule()
            .fill(Color.white.opacity(0.04))
            .overlay {
                Capsule()
                    .stroke(Color.white.opacity(0.58), lineWidth: 1)
            }
            .overlay(alignment: .leading) {
                Circle()
                    .fill(Color.white.opacity(0.78))
                    .frame(width: 12, height: 12)
                    .padding(.leading, 4)
            }
            .frame(
                width: QuickSettingsPanelMetrics.accessibilityToggleSize.width,
                height: QuickSettingsPanelMetrics.accessibilityToggleSize.height
            )
            .accessibilityHidden(true)
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

private struct QuickSettingsScrollMonitor: NSViewRepresentable {
    let onScroll: @MainActor (CGFloat) -> Void

    func makeNSView(context: Context) -> QuickSettingsScrollMonitorView {
        let view = QuickSettingsScrollMonitorView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: QuickSettingsScrollMonitorView, context: Context) {
        nsView.onScroll = onScroll
    }

    static func dismantleNSView(_ nsView: QuickSettingsScrollMonitorView, coordinator: Void) {
        nsView.removeEventMonitor()
    }
}

@MainActor
private final class QuickSettingsScrollMonitorView: NSView {
    var onScroll: (@MainActor (CGFloat) -> Void)?
    private var eventMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeEventMonitor()
        guard window != nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self,
                  event.window === self.window,
                  abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX),
                  self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else {
                return event
            }
            self.onScroll?(event.scrollingDeltaY)
            return nil
        }
    }

    func removeEventMonitor() {
        guard let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }
}
