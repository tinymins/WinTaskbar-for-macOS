import AppKit
import SwiftUI

enum SystemTrayItemID: String, CaseIterable {
    case wifi = "wintaskbar.system.wifi"
    case volume = "wintaskbar.system.volume"
    case battery = "wintaskbar.system.battery"
    case inputSource = "wintaskbar.system.inputSource"
}

struct TrayItemDragConfiguration {
    let identifier: String
    let dropAxis: WindowsTrayIconDropAxis
    let onDrop: (String, Bool) -> Void
}

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
    let dragConfiguration: TrayItemDragConfiguration

    var body: some View {
        WindowsTrayIconButton(
            title: service.wifiSSID ?? (service.wifiPoweredOn ? "Not connected" : "Wi-Fi off"),
            preservesTransientPanelOnMouseDown: true,
            primaryAction: presentPanelIfNeeded,
            dragIdentifier: dragConfiguration.identifier,
            dropAxis: dragConfiguration.dropAxis,
            dropAction: dragConfiguration.onDrop
        ) {
            Image(systemName: service.wifiPoweredOn ? (service.wifiSSID == nil ? "wifi.exclamationmark" : "wifi") : "wifi.slash")
                .font(.system(size: 15, weight: .regular))
                .frame(width: WindowsTrayIconMetrics.iconSize, height: WindowsTrayIconMetrics.iconSize)
        }
        .frame(width: WindowsTrayIconMetrics.squareControlWidth, height: WindowsTrayIconMetrics.controlHeight)
    }

    private func presentPanelIfNeeded() {
        panelController.presentIfNeeded(
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
    let dragConfiguration: TrayItemDragConfiguration

    var body: some View {
        WindowsTrayIconButton(
            title: "Volume",
            preservesTransientPanelOnMouseDown: true,
            primaryAction: presentPanelIfNeeded,
            dragIdentifier: dragConfiguration.identifier,
            dropAxis: dragConfiguration.dropAxis,
            dropAction: dragConfiguration.onDrop
        ) {
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

    private func presentPanelIfNeeded() {
        panelController.presentIfNeeded(
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
    let dragConfiguration: TrayItemDragConfiguration

    var body: some View {
        if let level = service.batteryLevel {
            let title = service.isCharging ? "Battery charging: \(level)%" : "Battery: \(level)%"
            WindowsTrayIconButton(
                title: title,
                accessibilityLabel: service.isCharging ? "Battery charging, \(level)%" : "Battery, \(level)%",
                preservesTransientPanelOnMouseDown: true,
                primaryAction: presentPanelIfNeeded,
                dragIdentifier: dragConfiguration.identifier,
                dropAxis: dragConfiguration.dropAxis,
                dropAction: dragConfiguration.onDrop
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

    private func presentPanelIfNeeded() {
        panelController.presentIfNeeded(
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
    let dragConfiguration: TrayItemDragConfiguration

    var body: some View {
        WindowsTrayIconButton(
            title: service.inputSource,
            accessibilityLabel: "Keyboard layout: \(service.inputSource)",
            primaryAction: togglePanel,
            dragIdentifier: dragConfiguration.identifier,
            dropAxis: dragConfiguration.dropAxis,
            dropAction: dragConfiguration.onDrop
        ) {
            Text(currentAbbreviation)
                .font(.system(size: 15, weight: .medium))
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
        let time = ClockTrayPresentation.time(
            service.now,
            showsSeconds: showsSeconds,
            configuration: formatConfiguration
        )
        let date = position.isHorizontal ? ClockTrayPresentation.date(
            service.now,
            configuration: formatConfiguration
        ) : nil
        WindowsTrayIconButton(
            title: clockTooltip,
            accessibilityLabel: "Clock and calendar",
            tooltipGap: WindowsTrayIconMetrics.clockTooltipGap,
            primaryAction: togglePanel
        ) {
            VStack(alignment: .trailing, spacing: 0) {
                Text(time)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: date == nil ? WindowsTrayIconMetrics.controlHeight : WindowsTrayIconMetrics.clockRowHeight,
                        maxHeight: date == nil ? WindowsTrayIconMetrics.controlHeight : WindowsTrayIconMetrics.clockRowHeight,
                        alignment: .trailing
                    )
                if let date {
                    Text(date)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: WindowsTrayIconMetrics.clockRowHeight,
                            maxHeight: WindowsTrayIconMetrics.clockRowHeight,
                            alignment: .trailing
                        )
                }
            }
            .font(.system(size: WindowsTrayIconMetrics.clockFontSize, weight: .regular).monospacedDigit())
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, WindowsTrayIconMetrics.horizontalContentPadding)
        }
        .frame(
            width: Self.controlWidth(time: time, date: date),
            height: WindowsTrayIconMetrics.controlHeight
        )
        .onDisappear { panelController.dismiss(animated: false) }
    }

    static func controlWidth(time: String, date: String?) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: WindowsTrayIconMetrics.clockFontSize,
            weight: .regular
        )
        let strings = [time, date].compactMap { $0 }
        let textWidth = strings.map {
            ($0 as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 0
        return max(
            WindowsTrayIconMetrics.squareControlWidth,
            ceil(textWidth) + 2 * WindowsTrayIconMetrics.horizontalContentPadding
        )
    }

    private func togglePanel() {
        panelController.toggle(
            screen: screen,
            position: position,
            barHeight: barHeight,
            theme: theme
        )
    }

    private var clockTooltip: String {
        let clockLines = additionalClocks.filter(\.isEnabled).compactMap { clock -> String? in
            guard let timeZone = TimeZone(identifier: clock.timeZoneIdentifier) else { return nil }
            let time = DateTimeFormatter.string(
                from: service.now,
                pattern: "EEE \(formatConfiguration.longTimePattern)",
                configuration: formatConfiguration,
                timeZone: timeZone
            )
            return "\(time) (\(clock.displayName))"
        }
        let longDate = DateTimeFormatter.longDateString(
            from: service.now,
            configuration: formatConfiguration
        )
        let localTime = DateTimeFormatter.string(
            from: service.now,
            pattern: "EEE \(formatConfiguration.longTimePattern)",
            configuration: formatConfiguration
        )
        return ([longDate, "", "\(localTime) (Local time)"] + clockLines).joined(separator: "\n")
    }
}
