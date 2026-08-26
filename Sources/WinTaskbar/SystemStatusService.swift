import AppKit
import Carbon
import Combine
import CoreAudio
import CoreLocation
import CoreWLAN
import Foundation
import IOKit.ps

struct WiFiNetworkInfo: Identifiable, Hashable {
    let ssid: String
    let rssi: Int
    var id: String { ssid }
}

enum WiFiScanIssue: Equatable {
    case locationAuthorizationRequired
    case locationPermissionDenied
    case scanFailed
}

enum VolumeAdjustmentPolicy {
    static func shouldUnmute(targetVolume: Float) -> Bool {
        targetVolume > 0
    }
}

struct InputSourceOption: Identifiable, Hashable {
    let id: String
    let name: String
    let abbreviation: String
    let languageCode: String?
    let iconURL: URL?

    var displayName: String {
        guard let languageCode,
              let localizedName = Locale.autoupdatingCurrent.localizedString(forLanguageCode: languageCode) else {
            return name
        }
        return localizedName
    }

    var detail: String? {
        displayName.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame ? nil : name
    }
}

enum InputSourcePresentation {
    static func abbreviation(languageCode: String?, fallbackName: String) -> String {
        guard let languageCode else { return fallbackAbbreviation(for: fallbackName) }
        let baseLanguageCode = languageCode
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init)
        guard let baseLanguageCode,
              let englishName = Locale(identifier: "en").localizedString(forLanguageCode: baseLanguageCode) else {
            return fallbackAbbreviation(for: fallbackName)
        }
        return String(englishName.prefix(3)).uppercased()
    }

    private static func fallbackAbbreviation(for name: String) -> String {
        String(name.prefix(3)).uppercased()
    }
}

@MainActor
final class SystemStatusService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var now = Date()
    @Published private(set) var batteryLevel: Int?
    @Published private(set) var isCharging = false
    @Published private(set) var isLowPowerModeEnabled = false
    @Published private(set) var volume: Float = 0
    @Published private(set) var isMuted = false
    @Published private(set) var wifiSSID: String?
    @Published private(set) var inputSource = "ABC"
    @Published private(set) var inputSourceID = ""
    @Published private(set) var wifiPoweredOn = false
    @Published private(set) var wifiNetworks: [WiFiNetworkInfo] = []
    @Published private(set) var isScanningWiFi = false
    @Published private(set) var wifiScanIssue: WiFiScanIssue?
    @Published private(set) var inputSources: [InputSourceOption] = []

    private var timer: Timer?
    private let locationManager = CLLocationManager()
    private var scannedNetworks: [String: CWNetwork] = [:]
    private var inputSourceRefs: [String: TISInputSource] = [:]

    override init() {
        super.init()
        locationManager.delegate = self
        refresh()
        reloadInputSources()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    func refresh() {
        now = Date()
        readBattery()
        readAudio()
        let interface = CWWiFiClient.shared().interface()
        wifiSSID = interface?.ssid()
        wifiPoweredOn = interface?.powerOn() ?? false
        readInputSource()
    }

    func setVolume(_ value: Float) {
        guard let device = defaultOutputDevice() else { return }
        var newValue = max(0, min(value, 1))
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &newValue)
        if VolumeAdjustmentPolicy.shouldUnmute(targetVolume: newValue) {
            writeMute(false, to: device)
        }
        refresh()
    }

    func toggleMute() {
        guard let device = defaultOutputDevice() else { return }
        writeMute(!isMuted, to: device)
        refresh()
    }

    private func writeMute(_ muted: Bool, to device: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return }
        var muteValue: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(
            device,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &muteValue
        )
    }

    func scanWiFi() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            wifiNetworks = []
            wifiScanIssue = .locationAuthorizationRequired
            NSApp.activate(ignoringOtherApps: true)
            locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
            locationManager.requestWhenInUseAuthorization()
            locationManager.startUpdatingLocation()
            return
        case .restricted, .denied:
            wifiNetworks = []
            wifiScanIssue = .locationPermissionDenied
            return
        case .authorizedAlways:
            break
        @unknown default:
            wifiNetworks = []
            wifiScanIssue = .locationPermissionDenied
            return
        }
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn() else {
            wifiNetworks = []
            wifiScanIssue = nil
            return
        }
        isScanningWiFi = true
        defer { isScanningWiFi = false }
        let networks: Set<CWNetwork>
        do {
            networks = try interface.scanForNetworks(withSSID: nil)
        } catch {
            wifiNetworks = []
            wifiScanIssue = .scanFailed
            return
        }
        var bestBySSID: [String: CWNetwork] = [:]
        for network in networks {
            guard let ssid = network.ssid, !ssid.isEmpty else { continue }
            if bestBySSID[ssid] == nil || network.rssiValue > (bestBySSID[ssid]?.rssiValue ?? Int.min) {
                bestBySSID[ssid] = network
            }
        }
        scannedNetworks = bestBySSID
        wifiNetworks = bestBySSID.map { WiFiNetworkInfo(ssid: $0.key, rssi: $0.value.rssiValue) }
            .sorted { $0.rssi > $1.rssi }
        wifiScanIssue = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let authorizationStatus = manager.authorizationStatus
        Task { @MainActor [weak self] in
            if authorizationStatus == .authorizedAlways {
                self?.locationManager.stopUpdatingLocation()
                self?.scanWiFi()
            } else if authorizationStatus == .denied || authorizationStatus == .restricted {
                self?.locationManager.stopUpdatingLocation()
                self?.wifiScanIssue = .locationPermissionDenied
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak self] in
            self?.locationManager.stopUpdatingLocation()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.locationManager.stopUpdatingLocation()
        }
    }

    func joinWiFi(ssid: String, password: String?) -> Bool {
        guard let interface = CWWiFiClient.shared().interface(), let network = scannedNetworks[ssid] else { return false }
        do {
            try interface.associate(to: network, password: password)
            refresh()
            return true
        } catch {
            refresh()
            return false
        }
    }

    func disconnectWiFi() {
        CWWiFiClient.shared().interface()?.disassociate()
        refresh()
    }

    func setWiFiPower(_ enabled: Bool) {
        try? CWWiFiClient.shared().interface()?.setPower(enabled)
        refresh()
        if enabled { scanWiFi() }
    }

    func selectInputSource(id: String) {
        guard let source = inputSourceRefs[id] else { return }
        TISSelectInputSource(source)
        readInputSource()
    }

    private func readBattery() {
        isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let source = list.first,
              let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
              let current = description[kIOPSCurrentCapacityKey] as? Int,
              let maximum = description[kIOPSMaxCapacityKey] as? Int,
              maximum > 0 else {
            batteryLevel = nil
            isCharging = false
            return
        }
        batteryLevel = Int((Double(current) / Double(maximum) * 100).rounded())
        isCharging = (description[kIOPSIsChargingKey] as? Bool) ?? false
    }

    private func readAudio() {
        guard let device = defaultOutputDevice() else { return }
        var volumeValue: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &volumeValue) == noErr {
            volume = volumeValue
        }

        var muteValue: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(device, &muteAddress),
           AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &muteValue) == noErr {
            isMuted = muteValue != 0
        }
    }

    private func defaultOutputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private func readInputSource() {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let id = stringProperty(source, kTISPropertyInputSourceID),
              let name = stringProperty(source, kTISPropertyLocalizedName) else { return }
        inputSourceID = id
        inputSource = name
    }

    private func reloadInputSources() {
        let properties = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource!,
            kTISPropertyInputSourceIsSelectCapable as String: true
        ] as CFDictionary
        guard let sources = TISCreateInputSourceList(properties, false)?.takeRetainedValue() as? [TISInputSource] else { return }
        var options: [InputSourceOption] = []
        var refs: [String: TISInputSource] = [:]
        for source in sources {
            guard let id = stringProperty(source, kTISPropertyInputSourceID),
                  let name = stringProperty(source, kTISPropertyLocalizedName) else { continue }
            let languageCode = stringArrayProperty(source, kTISPropertyInputSourceLanguages)?.first
            options.append(InputSourceOption(
                id: id,
                name: name,
                abbreviation: InputSourcePresentation.abbreviation(
                    languageCode: languageCode,
                    fallbackName: name
                ),
                languageCode: languageCode,
                iconURL: urlProperty(source, kTISPropertyIconImageURL)
            ))
            refs[id] = source
        }
        inputSources = options
        inputSourceRefs = refs
    }

    private func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue() as? String
    }

    private func stringArrayProperty(_ source: TISInputSource, _ key: CFString) -> [String]? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue() as? [String]
    }

    private func urlProperty(_ source: TISInputSource, _ key: CFString) -> URL? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue() as? URL
    }
}
