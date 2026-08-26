import AppKit
import SwiftUI

struct WiFiTrayView: View {
    @ObservedObject var service: SystemStatusService
    @ObservedObject var panelController: QuickSettingsPanelController
    let actions: AppActions
    let position: TaskbarPosition
    let barHeight: CGFloat

    var body: some View {
        Button {
            panelController.toggle(
                service: service,
                actions: actions,
                position: position,
                barHeight: barHeight
            )
        } label: {
            Image(systemName: service.wifiPoweredOn ? (service.wifiSSID == nil ? "wifi.exclamationmark" : "wifi") : "wifi.slash")
        }
        .buttonStyle(.plain)
        .help(service.wifiSSID ?? (service.wifiPoweredOn ? "Not connected" : "Wi-Fi off"))
        .quickSettingsPanelAnchor(controller: panelController)
    }
}

struct VolumeTrayView: View {
    @ObservedObject var service: SystemStatusService
    @ObservedObject var panelController: QuickSettingsPanelController
    let actions: AppActions
    let position: TaskbarPosition
    let barHeight: CGFloat

    var body: some View {
        Button {
            panelController.toggle(
                service: service,
                actions: actions,
                position: position,
                barHeight: barHeight
            )
        } label: { Image(systemName: symbol) }
            .buttonStyle(.plain)
            .help("Volume")
            .quickSettingsPanelAnchor(controller: panelController)
    }

    private var symbol: String {
        if service.isMuted || service.volume == 0 { return "speaker.slash.fill" }
        if service.volume < 0.35 { return "speaker.wave.1.fill" }
        if service.volume < 0.7 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

struct BatteryTrayView: View {
    @ObservedObject var service: SystemStatusService
    @ObservedObject var panelController: QuickSettingsPanelController
    let actions: AppActions
    let position: TaskbarPosition
    let barHeight: CGFloat
    let horizontal: Bool

    var body: some View {
        if let level = service.batteryLevel {
            Button {
                panelController.toggle(
                    service: service,
                    actions: actions,
                    position: position,
                    barHeight: barHeight
                )
            } label: {
                HStack(spacing: 3) {
                    WindowsBatteryIcon(
                        level: level,
                        isCharging: service.isCharging,
                        state: batteryState(level)
                    )
                    if horizontal { Text("\(level)%").font(.caption2) }
                }
            }
            .buttonStyle(.plain)
            .quickSettingsPanelAnchor(controller: panelController)
            .help(service.isCharging ? "Battery charging: \(level)%" : "Battery: \(level)%")
            .accessibilityLabel(service.isCharging ? "Battery charging, \(level)%" : "Battery, \(level)%")
        }
    }

    private func batteryState(_ level: Int) -> BatteryPresentationState {
        .resolve(
            level: level,
            isCharging: service.isCharging,
            isLowPowerModeEnabled: service.isLowPowerModeEnabled
        )
    }
}

struct InputSourceTrayView: View {
    @ObservedObject var service: SystemStatusService
    let position: TaskbarPosition
    let barHeight: CGFloat
    @StateObject private var panelController = InputSourcePanelController()

    var body: some View {
        Button {
            panelController.toggle(service: service, position: position, barHeight: barHeight)
        } label: {
            Text(currentAbbreviation)
                .font(.caption2.weight(.medium))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(service.inputSource)
        .accessibilityLabel("Keyboard layout: \(service.inputSource)")
        .inputSourcePanelAnchor(controller: panelController)
        .onDisappear { panelController.dismiss() }
    }

    private var currentAbbreviation: String {
        service.inputSources.first(where: { $0.id == service.inputSourceID })?.abbreviation
            ?? String(service.inputSource.prefix(3)).uppercased()
    }
}

struct ClockTrayView: View {
    @ObservedObject var service: SystemStatusService
    let position: TaskbarPosition
    let barHeight: CGFloat
    let theme: AppTheme
    let screen: NSScreen
    @StateObject private var panelController = ClockCalendarPanelController()

    var body: some View {
        Button {
            panelController.toggle(
                screen: screen,
                position: position,
                barHeight: barHeight,
                theme: theme
            )
        } label: {
            VStack(alignment: .trailing, spacing: 0) {
                Text(service.now, format: .dateTime.hour().minute())
                if position.isHorizontal { Text(service.now, format: .dateTime.day().month(.abbreviated)) }
            }.font(.caption2.monospacedDigit())
        }
        .buttonStyle(.plain)
        .help("Clock and calendar")
        .accessibilityLabel("Clock and calendar")
        .onDisappear { panelController.dismiss(animated: false) }
    }
}
