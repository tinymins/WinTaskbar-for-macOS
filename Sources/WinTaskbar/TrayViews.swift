import AppKit
import SwiftUI

enum ClockTrayPresentation {
    private static let calendar = Calendar(identifier: .gregorian)
    private static let dateLocale = Locale(identifier: "en_US_POSIX")
    private static let timeLocale = Locale(identifier: "en_US_POSIX@hours=h23")

    static func time(
        _ date: Date,
        showsSeconds: Bool,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        date.formatted(
            Date.FormatStyle(
                date: .omitted,
                time: showsSeconds ? .standard : .shortened,
                locale: timeLocale,
                calendar: calendar,
                timeZone: timeZone
            )
        )
    }

    static func date(
        _ date: Date,
        usesAbbreviatedFormat: Bool,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        if usesAbbreviatedFormat {
            let format = Date.FormatStyle(
                date: .omitted,
                time: .omitted,
                locale: dateLocale,
                calendar: calendar,
                timeZone: timeZone
            )
            return date.formatted(format.month(.defaultDigits).day(.defaultDigits))
        }
        return date.formatted(
            Date.FormatStyle(
                date: .numeric,
                time: .omitted,
                locale: dateLocale,
                calendar: calendar,
                timeZone: timeZone
            )
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
        Button {
            panelController.toggle(
                service: service,
                actions: actions,
                position: position,
                barHeight: barHeight,
                screen: screen
            )
        } label: {
            Image(systemName: service.wifiPoweredOn ? (service.wifiSSID == nil ? "wifi.exclamationmark" : "wifi") : "wifi.slash")
        }
        .buttonStyle(.plain)
        .help(service.wifiSSID ?? (service.wifiPoweredOn ? "Not connected" : "Wi-Fi off"))
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
        Button {
            panelController.toggle(
                service: service,
                actions: actions,
                position: position,
                barHeight: barHeight,
                screen: screen
            )
        } label: { Image(systemName: symbol) }
            .buttonStyle(.plain)
            .help("Volume")
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
    let screen: NSScreen

    var body: some View {
        if let level = service.batteryLevel {
            Button {
                panelController.toggle(
                    service: service,
                    actions: actions,
                    position: position,
                    barHeight: barHeight,
                    screen: screen
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
    @ObservedObject var panelController: InputSourcePanelController
    let position: TaskbarPosition
    let barHeight: CGFloat
    let screen: NSScreen

    var body: some View {
        Button {
            panelController.toggle(
                service: service,
                position: position,
                barHeight: barHeight,
                screen: screen,
                appearance: NSApp.effectiveAppearance
            )
        } label: {
            Text(currentAbbreviation)
                .font(.caption2.weight(.medium))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(service.inputSource)
        .accessibilityLabel("Keyboard layout: \(service.inputSource)")
        .onDisappear { panelController.dismiss() }
    }

    private var currentAbbreviation: String {
        service.inputSources.first(where: { $0.id == service.inputSourceID })?.abbreviation
            ?? String(service.inputSource.prefix(3)).uppercased()
    }
}

struct ClockTrayView: View {
    @ObservedObject var service: SystemStatusService
    @ObservedObject var panelController: ClockCalendarPanelController
    let position: TaskbarPosition
    let barHeight: CGFloat
    let theme: AppTheme
    let usesAbbreviatedFormat: Bool
    let showsSeconds: Bool
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
                Text(ClockTrayPresentation.time(service.now, showsSeconds: showsSeconds))
                if position.isHorizontal {
                    Text(ClockTrayPresentation.date(
                        service.now,
                        usesAbbreviatedFormat: usesAbbreviatedFormat
                    ))
                }
            }.font(.caption2.monospacedDigit())
        }
        .buttonStyle(.plain)
        .help("Clock and calendar")
        .accessibilityLabel("Clock and calendar")
        .onDisappear { panelController.dismiss(animated: false) }
    }
}
