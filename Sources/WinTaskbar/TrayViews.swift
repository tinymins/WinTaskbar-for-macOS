import AppKit
import SwiftUI

enum ClockTrayPresentation {
    static func time(
        _ date: Date,
        showsSeconds: Bool,
        configuration: DateTimeFormatConfiguration,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        DateTimeFormatter.string(
            from: date,
            pattern: showsSeconds ? configuration.longTimePattern : configuration.shortTimePattern,
            configuration: configuration,
            timeZone: timeZone
        )
    }

    static func date(
        _ date: Date,
        configuration: DateTimeFormatConfiguration,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        DateTimeFormatter.string(
            from: date,
            pattern: configuration.shortDatePattern,
            configuration: configuration,
            timeZone: timeZone
        )
    }
}

struct WiFiTrayView: View {
    @ObservedObject var service: SystemStatusService
    @ObservedObject var panelController: QuickSettingsPanelController
    let actions: AppActions
    let position: TaskbarPosition
    let barHeight: CGFloat
    let screen: NSScreen

    var body: some View {
        WindowsTrayIconButton(
            title: service.wifiSSID ?? (service.wifiPoweredOn ? "Not connected" : "Wi-Fi off"),
            primaryAction: togglePanel
        ) {
            Image(systemName: service.wifiPoweredOn ? (service.wifiSSID == nil ? "wifi.exclamationmark" : "wifi") : "wifi.slash")
                .font(.system(size: 15, weight: .regular))
                .frame(width: WindowsTrayIconMetrics.iconSize, height: WindowsTrayIconMetrics.iconSize)
        }
        .frame(width: WindowsTrayIconMetrics.squareControlWidth, height: WindowsTrayIconMetrics.controlHeight)
    }

    private func togglePanel() {
        panelController.toggle(
            service: service,
            actions: actions,
            position: position,
            barHeight: barHeight,
            screen: screen
        )
    }
}

struct VolumeTrayView: View {
    @ObservedObject var service: SystemStatusService
    @ObservedObject var panelController: QuickSettingsPanelController
    let actions: AppActions
    let position: TaskbarPosition
    let barHeight: CGFloat
    let screen: NSScreen

    var body: some View {
        WindowsTrayIconButton(title: "Volume", primaryAction: togglePanel) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .regular))
                .frame(width: WindowsTrayIconMetrics.iconSize, height: WindowsTrayIconMetrics.iconSize)
        }
        .frame(width: WindowsTrayIconMetrics.squareControlWidth, height: WindowsTrayIconMetrics.controlHeight)
    }

    private var symbol: String {
        if service.isMuted || service.volume == 0 { return "speaker.slash.fill" }
        if service.volume < 0.35 { return "speaker.wave.1.fill" }
        if service.volume < 0.7 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private func togglePanel() {
        panelController.toggle(
            service: service,
            actions: actions,
            position: position,
            barHeight: barHeight,
            screen: screen
        )
    }
}

struct BatteryTrayView: View {
    @ObservedObject var service: SystemStatusService
    @ObservedObject var panelController: QuickSettingsPanelController
    let actions: AppActions
    let position: TaskbarPosition
    let barHeight: CGFloat
    let horizontal: Bool
    let screen: NSScreen

    var body: some View {
        if let level = service.batteryLevel {
            let title = service.isCharging ? "Battery charging: \(level)%" : "Battery: \(level)%"
            WindowsTrayIconButton(
                title: title,
                accessibilityLabel: service.isCharging ? "Battery charging, \(level)%" : "Battery, \(level)%",
                primaryAction: togglePanel
            ) {
                HStack(spacing: 3) {
                    WindowsBatteryIcon(
                        level: level,
                        isCharging: service.isCharging,
                        state: batteryState(level)
                    )
                    if horizontal { Text("\(level)%").font(.caption2) }
                }
            }
            .frame(
                width: horizontal ? WindowsTrayIconMetrics.batteryControlWidth : WindowsTrayIconMetrics.squareControlWidth,
                height: WindowsTrayIconMetrics.controlHeight
            )
        }
    }

    private func batteryState(_ level: Int) -> BatteryPresentationState {
        .resolve(
            level: level,
            isCharging: service.isCharging,
            isLowPowerModeEnabled: service.isLowPowerModeEnabled
        )
    }

    private func togglePanel() {
        panelController.toggle(
            service: service,
            actions: actions,
            position: position,
            barHeight: barHeight,
            screen: screen
        )
    }
}

struct InputSourceTrayView: View {
    @ObservedObject var service: SystemStatusService
    @ObservedObject var panelController: InputSourcePanelController
    let position: TaskbarPosition
    let barHeight: CGFloat
    let screen: NSScreen

    var body: some View {
        WindowsTrayIconButton(
            title: service.inputSource,
            accessibilityLabel: "Keyboard layout: \(service.inputSource)",
            primaryAction: togglePanel
        ) {
            Text(currentAbbreviation)
                .font(.caption2.weight(.medium))
        }
        .frame(width: WindowsTrayIconMetrics.squareControlWidth, height: WindowsTrayIconMetrics.controlHeight)
        .onDisappear { panelController.dismiss() }
    }

    private var currentAbbreviation: String {
        service.inputSources.first(where: { $0.id == service.inputSourceID })?.abbreviation
            ?? String(service.inputSource.prefix(3)).uppercased()
    }

    private func togglePanel() {
        panelController.toggle(
            service: service,
            position: position,
            barHeight: barHeight,
            screen: screen,
            appearance: NSApp.effectiveAppearance
        )
    }
}

struct ClockTrayView: View {
    @ObservedObject var service: SystemStatusService
    @ObservedObject var panelController: ClockCalendarPanelController
    let position: TaskbarPosition
    let barHeight: CGFloat
    let theme: AppTheme
    let showsSeconds: Bool
    let formatConfiguration: DateTimeFormatConfiguration
    let additionalClocks: [AdditionalClockConfiguration]
    let screen: NSScreen

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
                Text(ClockTrayPresentation.time(
                    service.now,
                    showsSeconds: showsSeconds,
                    configuration: formatConfiguration
                ))
                if position.isHorizontal {
                    Text(ClockTrayPresentation.date(
                        service.now,
                        configuration: formatConfiguration
                    ))
                }
            }.font(.caption2.monospacedDigit())
        }
        .buttonStyle(.plain)
        .help(clockHelp)
        .accessibilityLabel("Clock and calendar")
        .onDisappear { panelController.dismiss(animated: false) }
    }

    private var clockHelp: String {
        let clockLines = additionalClocks.filter(\.isEnabled).compactMap { clock -> String? in
            guard let timeZone = TimeZone(identifier: clock.timeZoneIdentifier) else { return nil }
            let time = DateTimeFormatter.string(
                from: service.now,
                pattern: formatConfiguration.shortTimePattern,
                configuration: formatConfiguration,
                timeZone: timeZone
            )
            let relativeDay = AdditionalClockPresentation.relativeDay(
                for: service.now,
                targetTimeZone: timeZone
            )
            return "\(clock.displayName)  \([time, relativeDay?.localizedLabel].compactMap { $0 }.joined(separator: " "))"
        }
        return (["Clock and calendar"] + clockLines).joined(separator: "\n")
    }
}
