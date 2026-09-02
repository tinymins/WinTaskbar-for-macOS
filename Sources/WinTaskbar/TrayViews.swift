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

@MainActor
enum ClockTrayPresentation {
    private struct CachedDate {
        let interval: DateInterval
        let configuration: DateTimeFormatConfiguration
        let timeZone: TimeZone
        let text: String
    }

    private static var cachedDate: CachedDate?

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
        let resolvedTimeZone = TimeZone(identifier: timeZone.identifier) ?? timeZone
        if let cachedDate,
           cachedDate.configuration == configuration,
           cachedDate.timeZone == resolvedTimeZone,
           date >= cachedDate.interval.start, date < cachedDate.interval.end {
            return cachedDate.text
        }
        let text = DateTimeFormatter.string(
            from: date,
            pattern: configuration.shortDatePattern,
            configuration: configuration,
            timeZone: resolvedTimeZone
        )
        var calendar = Calendar(identifier: configuration.calendarKind.identifier)
        calendar.timeZone = resolvedTimeZone
        if let interval = calendar.dateInterval(of: .day, for: date) {
            cachedDate = CachedDate(interval: interval, configuration: configuration, timeZone: resolvedTimeZone, text: text)
        }
        return text
    }
}

@MainActor
private enum ClockTrayTextWidth {
    static let font = NSFont.monospacedDigitSystemFont(ofSize: WindowsTrayIconMetrics.clockFontSize, weight: .regular)
    private static let widths: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 128
        return cache
    }()

    static func width(of text: String) -> CGFloat {
        // Tabular ASCII digits share a width; preserve all other glyphs in the key.
        let key = String(text.map { character in
            guard let ascii = character.asciiValue, (48...57).contains(ascii) else { return character }
            return Character("0")
        }) as NSString
        if let cached = widths.object(forKey: key) { return CGFloat(cached.doubleValue) }
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        widths.setObject(NSNumber(value: Double(width)), forKey: key)
        return width
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
            taskbarPosition: position,
            preservesTransientPanelOnMouseDown: true,
            primaryAction: presentPanelIfNeeded,
            dragIdentifier: dragConfiguration.identifier,
            dropAxis: dragConfiguration.dropAxis,
            dropHoverAction: dragConfiguration.onDrop,
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
            taskbarPosition: position,
            preservesTransientPanelOnMouseDown: true,
            primaryAction: presentPanelIfNeeded,
            dragIdentifier: dragConfiguration.identifier,
            dropAxis: dragConfiguration.dropAxis,
            dropHoverAction: dragConfiguration.onDrop,
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
                taskbarPosition: position,
                preservesTransientPanelOnMouseDown: true,
                primaryAction: presentPanelIfNeeded,
                dragIdentifier: dragConfiguration.identifier,
                dropAxis: dragConfiguration.dropAxis,
                dropHoverAction: dragConfiguration.onDrop,
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

enum InputSourceTrayPresentation {
    static func usesCompactFont(for abbreviation: String) -> Bool {
        abbreviation.count >= 3
    }

    static func fontSize(for abbreviation: String) -> CGFloat {
        usesCompactFont(for: abbreviation) ? 12 : 15
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
            taskbarPosition: position,
            primaryAction: togglePanel,
            dragIdentifier: dragConfiguration.identifier,
            dropAxis: dragConfiguration.dropAxis,
            dropHoverAction: dragConfiguration.onDrop,
            dropAction: dragConfiguration.onDrop
        ) {
            Text(currentAbbreviation)
                .font(
                    .system(
                        size: InputSourceTrayPresentation.fontSize(for: currentAbbreviation),
                        weight: InputSourceTrayPresentation.usesCompactFont(for: currentAbbreviation)
                            ? .regular
                            : .medium
                    )
                )
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
    @ObservedObject var panelController: ClockCalendarPanelController
    let position: TaskbarPosition
    let barHeight: CGFloat
    let theme: AppTheme
    let showsSeconds: Bool
    let formatConfiguration: DateTimeFormatConfiguration
    let additionalClocks: [AdditionalClockConfiguration]
    let screen: NSScreen

    var body: some View {
        TimelineView(.periodic(from: .now, by: showsSeconds ? 1 : 3)) { context in
            content(at: context.date)
        }
        .onDisappear { panelController.dismiss(animated: false) }
    }

    private func content(at now: Date) -> some View {
        let time = ClockTrayPresentation.time(
            now,
            showsSeconds: showsSeconds,
            configuration: formatConfiguration
        )
        let date = position.isHorizontal ? ClockTrayPresentation.date(
            now,
            configuration: formatConfiguration
        ) : nil
        return WindowsTrayIconButton(
            title: "",
            accessibilityLabel: "Clock and calendar",
            tooltip: { clockTooltip(at: Date()) },
            taskbarPosition: position,
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
    }

    static func controlWidth(time: String, date: String?) -> CGFloat {
        let strings = [time, date].compactMap { $0 }
        let textWidth = strings.map { ClockTrayTextWidth.width(of: $0) }.max() ?? 0
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

    private func clockTooltip(at now: Date) -> String {
        let clockLines = additionalClocks.filter(\.isEnabled).compactMap { clock -> String? in
            guard let timeZone = TimeZone(identifier: clock.timeZoneIdentifier) else { return nil }
            let time = DateTimeFormatter.string(
                from: now,
                pattern: "EEE \(formatConfiguration.longTimePattern)",
                configuration: formatConfiguration,
                timeZone: timeZone
            )
            return "\(time) (\(clock.displayName))"
        }
        let longDate = DateTimeFormatter.longDateString(
            from: now,
            configuration: formatConfiguration
        )
        let localTime = DateTimeFormatter.string(
            from: now,
            pattern: "EEE \(formatConfiguration.longTimePattern)",
            configuration: formatConfiguration
        )
        return ([longDate, "", "\(localTime) (Local time)"] + clockLines).joined(separator: "\n")
    }
}
