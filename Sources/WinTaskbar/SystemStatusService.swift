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
        if baseLanguageCode?.lowercased() == "zh" { return "中" }
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

enum InputSourceCycling {
    static func nextID(sourceIDs: [String], currentID: String) -> String? {
        guard !sourceIDs.isEmpty else { return nil }
        guard let currentIndex = sourceIDs.firstIndex(of: currentID) else { return sourceIDs.first }
        return sourceIDs[(currentIndex + 1) % sourceIDs.count]
    }

    static func previousID(sourceIDs: [String], currentID: String) -> String? {
        guard !sourceIDs.isEmpty else { return nil }
        guard let currentIndex = sourceIDs.firstIndex(of: currentID) else { return sourceIDs.last }
        return sourceIDs[(currentIndex - 1 + sourceIDs.count) % sourceIDs.count]
    }
}

@MainActor
private final class AudioPropertyObservation {
    private let objectID: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let listener: AudioObjectPropertyListenerBlock

    init?(objectID: AudioObjectID, selector: AudioObjectPropertySelector,
          scope: AudioObjectPropertyScope, changed: @escaping @MainActor () -> Void) {
        self.objectID = objectID
        address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
        )
        listener = { _, _ in MainActor.assumeIsolated { changed() } }
        guard AudioObjectAddPropertyListenerBlock(objectID, &address, .main, listener) == noErr else { return nil }
    }

    isolated deinit {
        AudioObjectRemovePropertyListenerBlock(objectID, &address, .main, listener)
    }
}

@MainActor
final class SystemStatusService: NSObject, ObservableObject, CLLocationManagerDelegate, CWEventDelegate {
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

    private var statusTimer: Timer?
    private var powerSourceObserver: CFRunLoopSource?
    private var statusObservers: [AnyCancellable] = []
    private var audioOutputObserver: AudioPropertyObservation?
    private var audioDeviceObservers: [AudioPropertyObservation] = []
    private var observedAudioDevice: AudioDeviceID?
    private var wifiClient = CWWiFiClient()
    private let locationManager = CLLocationManager()
    private var scannedNetworks: [String: CWNetwork] = [:]
    private var inputSourceRefs: [String: TISInputSource] = [:]

    override init() {
        super.init()
        locationManager.delegate = self
        installStatusObservers()
        refresh()
        reloadInputSources()
        // Notifications provide immediate updates; reconcile after missed events or device changes.
        statusTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        statusTimer?.tolerance = 5
    }

    isolated deinit {
        statusTimer?.invalidate()
        if let powerSourceObserver { CFRunLoopSourceInvalidate(powerSourceObserver) }
        try? wifiClient.stopMonitoringAllEvents()
        wifiClient.delegate = nil
    }

    func refresh() {
        readBattery()
        observeAudioDevice()
        readAudio()
        readWiFi()
        readInputSource()
    }

    private func readWiFi() {
        let interface = wifiClient.interface()
        update(\.wifiSSID, to: interface?.ssid())
        update(\.wifiPoweredOn, to: interface?.powerOn() ?? false)
    }

    private func installStatusObservers() {
        powerSourceObserver = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<SystemStatusService>.fromOpaque(context).takeUnretainedValue().readBattery()
            }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let powerSourceObserver { CFRunLoopAddSource(CFRunLoopGetMain(), powerSourceObserver, .commonModes) }
        statusObservers = [
            NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
                .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.readBattery() },
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
                .receive(on: DispatchQueue.main).sink { [weak self] _ in
                    self?.startWiFiMonitoring()
                    self?.reloadInputSources()
                    self?.refresh()
                },
            DistributedNotificationCenter.default().publisher(
                for: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
            ).receive(on: DispatchQueue.main).sink { [weak self] _ in self?.readInputSource() },
            DistributedNotificationCenter.default().publisher(
                for: Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String)
            ).receive(on: DispatchQueue.main).sink { [weak self] _ in
                self?.reloadInputSources()
                self?.readInputSource()
            }
        ]
        audioOutputObserver = AudioPropertyObservation(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            scope: kAudioObjectPropertyScopeGlobal
        ) { [weak self] in
            self?.observeAudioDevice()
            self?.readAudio()
        }
        wifiClient.delegate = self
        startWiFiMonitoring()
    }

    private func observeAudioDevice() {
        let device = defaultOutputDevice()
        guard device != observedAudioDevice else { return }
        audioDeviceObservers.removeAll()
        observedAudioDevice = device
        guard let device else { return }
        audioDeviceObservers = [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute].compactMap { selector in
            AudioPropertyObservation(
                objectID: device, selector: selector, scope: kAudioDevicePropertyScopeOutput
            ) { [weak self] in self?.readAudio() }
        }
    }

    private func startWiFiMonitoring() {
        for event: CWEventType in [.powerDidChange, .ssidDidChange, .linkDidChange] {
            try? wifiClient.startMonitoringEvent(with: event)
        }
    }

    nonisolated func powerStateDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor [weak self] in self?.readWiFi() }
    }

    nonisolated func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor [weak self] in self?.readWiFi() }
    }

    nonisolated func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor [weak self] in self?.readWiFi() }
    }

    nonisolated func clientConnectionInterrupted() {
        Task { @MainActor [weak self] in self?.readWiFi() }
    }

    nonisolated func clientConnectionInvalidated() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            wifiClient.delegate = nil
            wifiClient = CWWiFiClient()
            wifiClient.delegate = self
            startWiFiMonitoring()
            readWiFi()
        }
    }

    private func update<Value: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<SystemStatusService, Value>,
        to value: Value
    ) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
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
        readAudio()
    }

    func toggleMute() {
        guard let device = defaultOutputDevice() else { return }
        writeMute(!isMuted, to: device)
        readAudio()
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
        guard let interface = wifiClient.interface(), interface.powerOn() else {
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
        guard let interface = wifiClient.interface(), let network = scannedNetworks[ssid] else { return false }
        do {
            try interface.associate(to: network, password: password)
            readWiFi()
            return true
        } catch {
            readWiFi()
            return false
        }
    }

    func disconnectWiFi() {
        wifiClient.interface()?.disassociate()
        readWiFi()
    }

    func setWiFiPower(_ enabled: Bool) {
        try? wifiClient.interface()?.setPower(enabled)
        readWiFi()
        if enabled { scanWiFi() }
    }

    func selectInputSource(id: String) {
        guard let source = inputSourceRefs[id] else { return }
        TISSelectInputSource(source)
        readInputSource()
    }

    func selectNextInputSource() {
        guard let nextID = InputSourceCycling.nextID(
            sourceIDs: inputSources.map(\.id),
            currentID: inputSourceID
        ) else { return }
        selectInputSource(id: nextID)
    }

    func selectPreviousInputSource() {
        guard let previousID = InputSourceCycling.previousID(
            sourceIDs: inputSources.map(\.id),
            currentID: inputSourceID
        ) else { return }
        selectInputSource(id: previousID)
    }

    private func readBattery() {
        update(\.isLowPowerModeEnabled, to: ProcessInfo.processInfo.isLowPowerModeEnabled)
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let source = list.first,
              let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
              let current = description[kIOPSCurrentCapacityKey] as? Int,
              let maximum = description[kIOPSMaxCapacityKey] as? Int,
              maximum > 0 else {
            update(\.batteryLevel, to: nil)
            update(\.isCharging, to: false)
            return
        }
        update(\.batteryLevel, to: Int((Double(current) / Double(maximum) * 100).rounded()))
        update(\.isCharging, to: (description[kIOPSIsChargingKey] as? Bool) ?? false)
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
            update(\.volume, to: volumeValue)
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
            update(\.isMuted, to: muteValue != 0)
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
        update(\.inputSourceID, to: id)
        update(\.inputSource, to: name)
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
