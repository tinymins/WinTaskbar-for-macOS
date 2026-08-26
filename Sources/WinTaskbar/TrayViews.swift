import AppKit
import SwiftUI

struct WiFiTrayView: View {
    @ObservedObject var service: SystemStatusService
    @State private var showPopover = false
    @State private var pendingSSID: String?
    @State private var password = ""

    var body: some View {
        Button {
            showPopover.toggle()
            if showPopover { service.scanWiFi() }
        } label: {
            Image(systemName: service.wifiPoweredOn ? (service.wifiSSID == nil ? "wifi.exclamationmark" : "wifi") : "wifi.slash")
        }
        .buttonStyle(.plain)
        .help(service.wifiSSID ?? (service.wifiPoweredOn ? "Not connected" : "Wi-Fi off"))
        .popover(isPresented: $showPopover) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Wi-Fi").font(.headline)
                    Spacer()
                    Toggle("", isOn: Binding(get: { service.wifiPoweredOn }, set: { service.setWiFiPower($0) }))
                        .labelsHidden()
                }
                if service.isScanningWiFi { ProgressView("Scanning…") }
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(service.wifiNetworks) { network in
                            Button {
                                if service.wifiSSID == network.ssid { service.disconnectWiFi() }
                                else { pendingSSID = network.ssid; password = "" }
                            } label: {
                                HStack {
                                    Image(systemName: signalSymbol(network.rssi))
                                    Text(network.ssid).lineLimit(1)
                                    Spacer()
                                    if service.wifiSSID == network.ssid { Image(systemName: "checkmark") }
                                }.padding(.vertical, 4)
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(height: 220)

                if let pendingSSID {
                    Divider()
                    Text(pendingSSID).font(.subheadline.bold())
                    SecureField("Password", text: $password)
                    HStack {
                        Button("Cancel") { self.pendingSSID = nil }
                        Spacer()
                        Button("Join") {
                            if service.joinWiFi(ssid: pendingSSID, password: password.isEmpty ? nil : password) {
                                self.pendingSSID = nil
                            }
                        }.keyboardShortcut(.defaultAction)
                    }
                }
                Divider()
                Button("Rescan", action: service.scanWiFi)
            }
            .padding(14).frame(width: 300)
        }
    }

    private func signalSymbol(_ rssi: Int) -> String {
        if rssi > -55 { return "wifi" }
        if rssi > -70 { return "wifi" }
        return "wifi.exclamationmark"
    }
}

struct VolumeTrayView: View {
    @ObservedObject var service: SystemStatusService
    @State private var showPopover = false

    var body: some View {
        Button { showPopover.toggle() } label: { Image(systemName: symbol) }
            .buttonStyle(.plain)
            .help("Volume")
            .popover(isPresented: $showPopover) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Volume").font(.headline)
                    HStack {
                        Button(action: service.toggleMute) { Image(systemName: symbol) }.buttonStyle(.plain)
                        Slider(value: Binding(get: { Double(service.volume) }, set: { service.setVolume(Float($0)) }), in: 0...1)
                    }
                }.padding(14).frame(width: 260)
            }
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
    let horizontal: Bool
    @State private var showPopover = false

    var body: some View {
        if let level = service.batteryLevel {
            Button { showPopover.toggle() } label: {
                HStack(spacing: 3) {
                    Image(systemName: service.isCharging ? "battery.100percent.bolt" : batterySymbol(level))
                    if horizontal { Text("\(level)%").font(.caption2) }
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showPopover) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(service.isCharging ? "Battery — Charging" : "Battery").font(.headline)
                    ProgressView(value: Double(level), total: 100)
                    Text("\(level)%").font(.title.monospacedDigit())
                }.padding(14).frame(width: 220)
            }
        }
    }

    private func batterySymbol(_ level: Int) -> String {
        switch level { case 0..<13: "battery.0percent"; case 13..<38: "battery.25percent"; case 38..<63: "battery.50percent"; case 63..<88: "battery.75percent"; default: "battery.100percent" }
    }
}

struct InputSourceTrayView: View {
    @ObservedObject var service: SystemStatusService
    let position: TaskbarPosition
    @StateObject private var panelController = InputSourcePanelController()

    var body: some View {
        Button {
            panelController.toggle(service: service, position: position)
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
