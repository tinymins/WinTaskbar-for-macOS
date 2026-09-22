import Combine
import Foundation

struct KarabinerMouseDevice: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let vendorID: Int?
    let productID: Int?
    let deviceAddress: String?
    let locationID: Int?

    var identifiers: [String: Any] {
        var result: [String: Any] = ["is_pointing_device": true]
        if let vendorID { result["vendor_id"] = vendorID }
        if let productID { result["product_id"] = productID }
        if let deviceAddress, !deviceAddress.isEmpty {
            result["device_address"] = deviceAddress
        } else if vendorID == nil, productID == nil, let locationID {
            result["location_id"] = locationID
        }
        return result
    }
}

@MainActor
final class KarabinerMouseScrollService: ObservableObject {
    static let shared = KarabinerMouseScrollService()

    private static let karabinerCLIPath = "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"

    @Published private(set) var isAvailable = false
    @Published private(set) var isEnabled = false
    @Published private(set) var mice: [KarabinerMouseDevice] = []
    @Published private(set) var configuredMouseCount = 0
    @Published private(set) var lastError: String?

    private let fileManager = FileManager.default

    private var configURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/karabiner/karabiner.json")
    }

    private var supportDirectoryURL: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WinTaskbar", isDirectory: true)
    }

    private var backupDirectoryURL: URL {
        supportDirectoryURL.appendingPathComponent("Karabiner Backups", isDirectory: true)
    }

    private var stateURL: URL {
        supportDirectoryURL.appendingPathComponent("karabiner-mouse-scroll-state.json")
    }

    private init() {
        refresh()
    }

    func refresh() {
        lastError = nil
        isAvailable = fileManager.isExecutableFile(atPath: Self.karabinerCLIPath)
            && fileManager.fileExists(atPath: configURL.path)

        do {
            mice = isAvailable ? try Self.readConnectedMice() : []
            let root = try readConfiguration()
            guard let profile = Self.selectedProfile(in: root) else {
                throw MouseScrollError.selectedProfileMissing
            }
            configuredMouseCount = mice.filter { Self.isEnabled($0, in: profile) }.count
            isEnabled = mice.isEmpty
                ? fileManager.fileExists(atPath: stateURL.path)
                : configuredMouseCount == mice.count
        } catch {
            mice = []
            configuredMouseCount = 0
            isEnabled = false
            if isAvailable { lastError = error.localizedDescription }
        }
    }

    func setEnabled(_ enabled: Bool) {
        lastError = nil
        do {
            guard isAvailable else { throw MouseScrollError.karabinerUnavailable }
            let currentMice = try Self.readConnectedMice()
            if enabled {
                guard !currentMice.isEmpty else { throw MouseScrollError.noExternalMouse }
                try enable(for: currentMice)
            } else {
                try disable(for: currentMice)
            }
            refresh()
        } catch {
            lastError = error.localizedDescription
            refreshStatusPreservingError()
        }
    }

    private func enable(for devices: [KarabinerMouseDevice]) throws {
        let root = try readConfiguration()
        let existingState = try readStateIfPresent()
        var snapshots = existingState?.snapshots ?? []
        let existingIDs = Set(snapshots.map(\.device.id))
        snapshots.append(contentsOf: devices.filter { !existingIDs.contains($0.id) }.map { device in
            Self.snapshot(for: device, in: root)
        })

        let backupURL = try backupCurrentConfiguration()
        let state = MouseScrollState(snapshots: snapshots, backupPath: backupURL.path)
        try writeState(state)
        do {
            try KarabinerIntegrationService.shared.updateConfiguration { root in
                Self.settingScrollReversal(true, for: snapshots.map(\.device), in: root)
            }
        } catch {
            if let existingState {
                try? writeState(existingState)
            } else {
                try? fileManager.removeItem(at: stateURL)
            }
            throw error
        }
    }

    private func disable(for connectedDevices: [KarabinerMouseDevice]) throws {
        let state = try readStateIfPresent()
        _ = try backupCurrentConfiguration()

        if let state {
            let currentRoot = try readConfiguration()
            guard state.snapshots.allSatisfy({ Self.hasManagedValues($0.device, in: currentRoot) }) else {
                throw MouseScrollError.configurationChanged(backupPath: state.backupPath)
            }
            try KarabinerIntegrationService.shared.updateConfiguration { root in
                Self.restoring(state.snapshots, in: root)
            }
            try fileManager.removeItem(at: stateURL)
        } else {
            try KarabinerIntegrationService.shared.updateConfiguration { root in
                Self.settingScrollReversal(false, for: connectedDevices, in: root, enableDevice: false)
            }
        }
    }

    private func refreshStatusPreservingError() {
        let error = lastError
        refresh()
        lastError = error
    }

    private func readConfiguration() throws -> [String: Any] {
        guard fileManager.fileExists(atPath: configURL.path) else {
            throw MouseScrollError.configurationMissing
        }
        let data = try Data(contentsOf: configURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MouseScrollError.invalidConfiguration
        }
        return root
    }

    private func backupCurrentConfiguration() throws -> URL {
        let data = try Data(contentsOf: configURL)
        try fileManager.createDirectory(at: backupDirectoryURL, withIntermediateDirectories: true)
        let url = backupDirectoryURL.appendingPathComponent(Self.backupFileName())
        try data.write(to: url, options: .atomic)
        return url
    }

    private func readStateIfPresent() throws -> MouseScrollState? {
        guard fileManager.fileExists(atPath: stateURL.path) else { return nil }
        return try JSONDecoder().decode(MouseScrollState.self, from: Data(contentsOf: stateURL))
    }

    private func writeState(_ state: MouseScrollState) throws {
        try fileManager.createDirectory(at: supportDirectoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }

    private static func readConnectedMice() throws -> [KarabinerMouseDevice] {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: karabinerCLIPath)
        process.arguments = ["--list-connected-devices"]
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw MouseScrollError.deviceDiscoveryFailed(message ?? "Karabiner CLI failed")
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        return try JSONDecoder().decode([ConnectedMouseDevice].self, from: data)
            .filter { device in
                let name = device.product.lowercased()
                return device.deviceIdentifiers.isPointingDevice == true
                    && device.isBuiltInPointingDevice != true
                    && device.isVirtualDevice != true
                    && device.deviceIdentifiers.isVirtualDevice != true
                    && !name.contains("trackpad")
                    && !(device.isApple == true && !name.contains("mouse"))
            }
            .map { device in
                let identifiers = device.deviceIdentifiers
                let identity = identifiers.deviceAddress.flatMap { $0.isEmpty ? nil : $0 }
                    ?? "\(identifiers.vendorID ?? 0):\(identifiers.productID ?? 0):\(device.locationID ?? 0)"
                return KarabinerMouseDevice(
                    id: identity,
                    name: device.product.isEmpty ? "Mouse" : device.product,
                    vendorID: identifiers.vendorID,
                    productID: identifiers.productID,
                    deviceAddress: identifiers.deviceAddress,
                    locationID: device.locationID
                )
            }
            .reduce(into: [String: KarabinerMouseDevice]()) { result, device in
                result[device.id] = device
            }
            .values
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func selectedProfile(in root: [String: Any]) -> [String: Any]? {
        (root["profiles"] as? [[String: Any]])?.first { ($0["selected"] as? Bool) == true }
    }

    private static func isEnabled(_ device: KarabinerMouseDevice, in profile: [String: Any]) -> Bool {
        guard let entry = deviceEntry(for: device, in: profile) else { return false }
        return (entry["ignore"] as? Bool) != true
            && (entry["mouse_flip_vertical_wheel"] as? Bool) == true
    }

    private static func hasManagedValues(_ device: KarabinerMouseDevice, in root: [String: Any]) -> Bool {
        guard let profile = selectedProfile(in: root),
              let entry = deviceEntry(for: device, in: profile) else { return false }
        return (entry["ignore"] as? Bool) == false
            && (entry["mouse_flip_vertical_wheel"] as? Bool) == true
    }

    private static func snapshot(for device: KarabinerMouseDevice, in root: [String: Any]) -> MouseDeviceSnapshot {
        let profile = selectedProfile(in: root) ?? [:]
        let entry = deviceEntry(for: device, in: profile)
        return MouseDeviceSnapshot(
            device: device,
            ignoreWasPresent: entry?["ignore"] != nil,
            previousIgnore: entry?["ignore"] as? Bool,
            flipWasPresent: entry?["mouse_flip_vertical_wheel"] != nil,
            previousFlip: entry?["mouse_flip_vertical_wheel"] as? Bool
        )
    }

    private static func settingScrollReversal(
        _ enabled: Bool,
        for devices: [KarabinerMouseDevice],
        in root: [String: Any],
        enableDevice: Bool = true
    ) -> [String: Any] {
        mutateSelectedProfile(in: root) { profile in
            var profile = profile
            var entries = profile["devices"] as? [[String: Any]] ?? []
            for device in devices {
                let index = entries.firstIndex { entryMatches($0, device: device) }
                if let index {
                    entries[index]["mouse_flip_vertical_wheel"] = enabled
                    if enableDevice { entries[index]["ignore"] = false }
                } else {
                    var entry: [String: Any] = [
                        "identifiers": device.identifiers,
                        "mouse_flip_vertical_wheel": enabled
                    ]
                    if enableDevice { entry["ignore"] = false }
                    entries.append(entry)
                }
            }
            profile["devices"] = entries
            return profile
        }
    }

    private static func restoring(
        _ snapshots: [MouseDeviceSnapshot],
        in root: [String: Any]
    ) -> [String: Any] {
        mutateSelectedProfile(in: root) { profile in
            var profile = profile
            var entries = profile["devices"] as? [[String: Any]] ?? []
            for snapshot in snapshots {
                guard let index = entries.firstIndex(where: { entryMatches($0, device: snapshot.device) }) else {
                    continue
                }
                if snapshot.ignoreWasPresent {
                    entries[index]["ignore"] = snapshot.previousIgnore
                } else {
                    entries[index].removeValue(forKey: "ignore")
                }
                if snapshot.flipWasPresent {
                    entries[index]["mouse_flip_vertical_wheel"] = snapshot.previousFlip
                } else {
                    entries[index].removeValue(forKey: "mouse_flip_vertical_wheel")
                }
            }
            profile["devices"] = entries
            return profile
        }
    }

    private static func mutateSelectedProfile(
        in root: [String: Any],
        transform: ([String: Any]) -> [String: Any]
    ) -> [String: Any] {
        var root = root
        guard var profiles = root["profiles"] as? [[String: Any]],
              let selectedIndex = profiles.firstIndex(where: { ($0["selected"] as? Bool) == true }) else {
            return root
        }
        profiles[selectedIndex] = transform(profiles[selectedIndex])
        root["profiles"] = profiles
        return root
    }

    private static func deviceEntry(
        for device: KarabinerMouseDevice,
        in profile: [String: Any]
    ) -> [String: Any]? {
        (profile["devices"] as? [[String: Any]])?.first { entryMatches($0, device: device) }
    }

    private static func entryMatches(_ entry: [String: Any], device: KarabinerMouseDevice) -> Bool {
        guard let identifiers = entry["identifiers"] as? [String: Any],
              (identifiers["is_pointing_device"] as? Bool) == true else { return false }
        if let vendorID = device.vendorID, identifiers["vendor_id"] as? Int != vendorID { return false }
        if let productID = device.productID, identifiers["product_id"] as? Int != productID { return false }
        if let address = device.deviceAddress, !address.isEmpty,
           let configuredAddress = identifiers["device_address"] as? String {
            return configuredAddress == address
        }
        return true
    }

    private static func backupFileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "karabiner-mouse-scroll-\(formatter.string(from: Date())).json"
    }
}

private struct ConnectedMouseDevice: Decodable {
    let deviceIdentifiers: ConnectedMouseDeviceIdentifiers
    let isApple: Bool?
    let isBuiltInPointingDevice: Bool?
    let isVirtualDevice: Bool?
    let locationID: Int?
    let product: String

    enum CodingKeys: String, CodingKey {
        case deviceIdentifiers = "device_identifiers"
        case isApple = "is_apple"
        case isBuiltInPointingDevice = "is_built_in_pointing_device"
        case isVirtualDevice = "is_virtual_device"
        case locationID = "location_id"
        case product
    }
}

private struct ConnectedMouseDeviceIdentifiers: Decodable {
    let vendorID: Int?
    let productID: Int?
    let deviceAddress: String?
    let isPointingDevice: Bool?
    let isVirtualDevice: Bool?

    enum CodingKeys: String, CodingKey {
        case vendorID = "vendor_id"
        case productID = "product_id"
        case deviceAddress = "device_address"
        case isPointingDevice = "is_pointing_device"
        case isVirtualDevice = "is_virtual_device"
    }
}

private struct MouseScrollState: Codable {
    let snapshots: [MouseDeviceSnapshot]
    let backupPath: String
}

private struct MouseDeviceSnapshot: Codable {
    let device: KarabinerMouseDevice
    let ignoreWasPresent: Bool
    let previousIgnore: Bool?
    let flipWasPresent: Bool
    let previousFlip: Bool?
}

private enum MouseScrollError: LocalizedError {
    case karabinerUnavailable
    case configurationMissing
    case invalidConfiguration
    case selectedProfileMissing
    case noExternalMouse
    case deviceDiscoveryFailed(String)
    case configurationChanged(backupPath: String)

    var errorDescription: String? {
        switch self {
        case .karabinerUnavailable:
            NSLocalizedString("Karabiner-Elements is required", comment: "Mouse scroll integration error")
        case .configurationMissing:
            NSLocalizedString("Karabiner-Elements configuration was not found.", comment: "Mouse scroll integration error")
        case .invalidConfiguration:
            NSLocalizedString("Karabiner-Elements configuration is not valid JSON.", comment: "Mouse scroll integration error")
        case .selectedProfileMissing:
            NSLocalizedString("Karabiner-Elements has no selected profile.", comment: "Mouse scroll integration error")
        case .noExternalMouse:
            NSLocalizedString("Connect an external mouse before enabling this option.", comment: "Mouse scroll integration error")
        case let .deviceDiscoveryFailed(message):
            String(
                format: NSLocalizedString("Karabiner mouse discovery failed: %@", comment: "Mouse scroll integration error"),
                message
            )
        case let .configurationChanged(backupPath):
            String(
                format: NSLocalizedString(
                    "Karabiner mouse settings changed after this option was enabled. WinTaskbar did not overwrite them. Original backup: %@",
                    comment: "Mouse scroll integration error with backup path"
                ),
                backupPath
            )
        }
    }
}
