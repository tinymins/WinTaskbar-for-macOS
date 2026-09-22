import Combine
import Foundation

enum KeyboardModifierRole: String, Codable, CaseIterable, Identifiable {
    case control
    case function
    case windows
    case alt

    var id: String { rawValue }

    var title: String {
        switch self {
        case .control: "Ctrl"
        case .function: "Fn"
        case .windows: "Win"
        case .alt: "Alt"
        }
    }

    func localOutput(
        for side: KeyboardModifierSide,
        windowsKeyMapping: WindowsKeyMapping
    ) -> String {
        switch self {
        case .control:
            windowsKeyMapping == .command
                ? windowsKeyMapping.karabinerFallbackKeyCode(for: side)
                : (side == .left ? "left_command" : "right_command")
        case .function:
            windowsKeyMapping == .function
                ? windowsKeyMapping.karabinerFallbackKeyCode(for: side)
                : "fn"
        case .windows: windowsKeyMapping.karabinerKeyCode(for: side)
        case .alt:
            windowsKeyMapping == .option
                ? windowsKeyMapping.karabinerFallbackKeyCode(for: side)
                : (side == .left ? "left_option" : "right_option")
        }
    }

    func windowsAppOutput(for side: KeyboardModifierSide) -> String {
        switch self {
        case .control: side == .left ? "left_control" : "right_control"
        case .function: "fn"
        case .windows: side == .left ? "left_command" : "right_command"
        case .alt: side == .left ? "left_option" : "right_option"
        }
    }
}

private extension WindowsKeyMapping {
    func karabinerKeyCode(for side: KeyboardModifierSide) -> String {
        switch self {
        case .function: "fn"
        case .control: side == .left ? "left_control" : "right_control"
        case .option: side == .left ? "left_option" : "right_option"
        case .command: side == .left ? "left_command" : "right_command"
        }
    }

    func karabinerFallbackKeyCode(for side: KeyboardModifierSide) -> String {
        side == .left ? "left_control" : "right_control"
    }
}

enum KeyboardModifierSide: String, Codable, CaseIterable, Identifiable {
    case left
    case right

    var id: String { rawValue }
    var title: String {
        NSLocalizedString(self == .left ? "Left" : "Right", comment: "Keyboard modifier side")
    }
}

struct KeyboardModifierAssignment: Codable, Hashable, Identifiable {
    var side: KeyboardModifierSide
    var role: KeyboardModifierRole
    var physicalKey: String

    var id: String { "\(side.rawValue).\(role.rawValue)" }
}

struct KarabinerKeyboardDevice: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var manufacturer: String?
    var vendorID: Int?
    var productID: Int?
    var locationID: Int?
    var deviceAddress: String?
    var isBuiltIn: Bool

    var subtitle: String {
        if isBuiltIn {
            return NSLocalizedString("Built-in keyboard", comment: "Keyboard device type")
        }
        let vendor = vendorID.map(String.init) ?? "?"
        let product = productID.map(String.init) ?? "?"
        return String(
            format: NSLocalizedString("Vendor %@ · Product %@", comment: "Keyboard device identifiers"),
            vendor,
            product
        )
    }

    var conditionIdentifier: [String: Any] {
        if isBuiltIn { return ["is_built_in_keyboard": true] }
        var identifier: [String: Any] = ["is_keyboard": true]
        if let vendorID { identifier["vendor_id"] = vendorID }
        if let productID { identifier["product_id"] = productID }
        if let deviceAddress, !deviceAddress.isEmpty {
            identifier["device_address"] = deviceAddress
        } else if let locationID {
            identifier["location_id"] = locationID
        }
        return identifier
    }
}

struct KeyboardMappingProfile: Codable, Hashable, Identifiable {
    var device: KarabinerKeyboardDevice
    var assignments: [KeyboardModifierAssignment]

    var id: String { device.id }

    func assignment(side: KeyboardModifierSide, role: KeyboardModifierRole) -> KeyboardModifierAssignment? {
        assignments.first { $0.side == side && $0.role == role }
    }

    func physicalKey(
        forLogicalKey logicalKey: String,
        windowsKeyMapping: WindowsKeyMapping
    ) -> String? {
        assignments.first {
            $0.role.localOutput(for: $0.side, windowsKeyMapping: windowsKeyMapping) == logicalKey
        }?.physicalKey
    }

    func preservingLogicalOutputs(
        from previousWindowsKeyMapping: WindowsKeyMapping,
        to updatedWindowsKeyMapping: WindowsKeyMapping
    ) -> KeyboardMappingProfile {
        guard previousWindowsKeyMapping != updatedWindowsKeyMapping else { return self }
        let updatedAssignments = assignments.map { assignment in
            let previousOutput = assignment.role.localOutput(
                for: assignment.side,
                windowsKeyMapping: previousWindowsKeyMapping
            )
            let updatedRole = KeyboardModifierRole.allCases.first {
                $0.localOutput(
                    for: assignment.side,
                    windowsKeyMapping: updatedWindowsKeyMapping
                ) == previousOutput
            } ?? assignment.role
            return KeyboardModifierAssignment(
                side: assignment.side,
                role: updatedRole,
                physicalKey: assignment.physicalKey
            )
        }
        return KeyboardMappingProfile(device: device, assignments: updatedAssignments)
    }
}

@MainActor
final class KarabinerIntegrationService: ObservableObject {
    static let shared = KarabinerIntegrationService()

    private static let managedRulePrefix = "WinTaskbar managed: Windows keyboard mode"
    private static let managedRuleDescription = "WinTaskbar managed: Windows keyboard mode v1"
    private static let karabinerCLIPath = "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"
    private static let managedModifierKeys: Set<String> = [
        "fn", "left_command", "right_command", "left_control", "right_control", "left_option", "right_option"
    ]

    @Published private(set) var isAvailable = false
    @Published private(set) var isEnabled = false
    @Published private(set) var version: String?
    @Published private(set) var conflictCount = 0
    @Published private(set) var lastError: String?
    @Published private(set) var keyboards: [KarabinerKeyboardDevice] = []
    @Published private(set) var keyboardMappings: [KeyboardMappingProfile] = []

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
        supportDirectoryURL.appendingPathComponent("karabiner-integration-state.json")
    }

    private var keyboardMappingsURL: URL {
        supportDirectoryURL.appendingPathComponent("keyboard-mappings.json")
    }

    private init() {
        refresh()
    }

    func refresh() {
        lastError = nil
        isAvailable = fileManager.isExecutableFile(atPath: Self.karabinerCLIPath)
            && fileManager.fileExists(atPath: configURL.path)
        version = isAvailable ? Self.readKarabinerVersion() : nil

        do {
            keyboards = isAvailable ? try Self.readConnectedKeyboards() : []
            keyboardMappings = try readKeyboardMappings()
            if keyboardMappings.isEmpty,
               let builtInKeyboard = keyboards.first(where: \.isBuiltIn) {
                keyboardMappings = [Self.defaultBuiltInMapping(for: builtInKeyboard)]
            }
            let root = try readConfiguration()
            guard let profile = Self.selectedProfile(in: root) else {
                isEnabled = false
                conflictCount = 0
                return
            }
            isEnabled = Self.containsManagedRule(profile)
            conflictCount = isEnabled ? 0 : Self.countConflicts(in: profile, mappings: keyboardMappings)
        } catch {
            isEnabled = false
            conflictCount = 0
            if isAvailable { lastError = error.localizedDescription }
        }
    }

    func enable(preferences: PreferencesStore) {
        lastError = nil
        do {
            guard isAvailable else { throw IntegrationError.karabinerUnavailable }
            var root = try readConfiguration()
            guard var profiles = root["profiles"] as? [[String: Any]],
                  let selectedIndex = profiles.firstIndex(where: { ($0["selected"] as? Bool) == true }) else {
                throw IntegrationError.selectedProfileMissing
            }
            if Self.containsManagedRule(profiles[selectedIndex]) {
                migrateManagedConfigurationIfNeeded(preferences: preferences)
                return
            }

            let originalData = try canonicalData(root)
            let previousPreferences = StoredPreferences(preferences: preferences)
            let removal = Self.removingConflicts(from: profiles[selectedIndex], mappings: keyboardMappings)
            var profile = removal.profile
            var complexModifications = profile["complex_modifications"] as? [String: Any] ?? [:]
            var rules = complexModifications["rules"] as? [[String: Any]] ?? []
            rules.insert(Self.managedRule(
                mappings: keyboardMappings,
                windowsKeyMapping: preferences.windowsKeyMapping
            ), at: 0)
            complexModifications["rules"] = rules
            profile["complex_modifications"] = complexModifications
            profiles[selectedIndex] = profile
            root["profiles"] = profiles

            let installedData = try canonicalData(root)
            try fileManager.createDirectory(at: backupDirectoryURL, withIntermediateDirectories: true)
            let backupURL = backupDirectoryURL.appendingPathComponent(Self.backupFileName())
            try originalData.write(to: backupURL, options: .atomic)

            let state = IntegrationState(
                originalConfiguration: originalData.base64EncodedString(),
                installedConfiguration: installedData.base64EncodedString(),
                backupPath: backupURL.path,
                previousPreferences: previousPreferences
            )
            try writeState(state)
            do {
                try writeConfiguration(installedData)
                try writeKeyboardMappings(keyboardMappings)
            } catch {
                try? fileManager.removeItem(at: stateURL)
                throw error
            }

            preferences.globalHotkeysEnabled = true
            preferences.altTabSwitcherEnabled = true
            preferences.altTabModifier = .option
            preferences.windowsKeyOpensStart = true
            conflictCount = removal.count
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func migrateManagedConfigurationIfNeeded(preferences: PreferencesStore) {
        lastError = nil
        do {
            guard isAvailable else { return }
            var root = try readConfiguration()
            guard var profiles = root["profiles"] as? [[String: Any]],
                  let selectedIndex = profiles.firstIndex(where: { ($0["selected"] as? Bool) == true }),
                  Self.containsManagedRule(profiles[selectedIndex]),
                  !Self.containsCurrentManagedRule(
                      profiles[selectedIndex],
                      mappings: keyboardMappings,
                      windowsKeyMapping: preferences.windowsKeyMapping
                  ) else { return }

            let state = try readState()
            let currentData = try canonicalData(root)
            guard currentData.base64EncodedString() == state.installedConfiguration else {
                throw IntegrationError.configurationChanged(backupPath: state.backupPath)
            }

            var profile = profiles[selectedIndex]
            var complexModifications = profile["complex_modifications"] as? [String: Any] ?? [:]
            var rules = complexModifications["rules"] as? [[String: Any]] ?? []
            rules.removeAll { Self.isManagedRule($0) }
            rules.insert(Self.managedRule(
                mappings: keyboardMappings,
                windowsKeyMapping: preferences.windowsKeyMapping
            ), at: 0)
            complexModifications["rules"] = rules
            profile["complex_modifications"] = complexModifications
            profiles[selectedIndex] = profile
            root["profiles"] = profiles

            let installedData = try canonicalData(root)
            let updatedState = IntegrationState(
                originalConfiguration: state.originalConfiguration,
                installedConfiguration: installedData.base64EncodedString(),
                backupPath: state.backupPath,
                previousPreferences: state.previousPreferences
            )
            try writeState(updatedState)
            try writeConfiguration(installedData)
            try writeKeyboardMappings(keyboardMappings)
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func mapping(for device: KarabinerKeyboardDevice) -> KeyboardMappingProfile? {
        keyboardMappings.first { $0.device.id == device.id }
    }

    func saveKeyboardMapping(
        for device: KarabinerKeyboardDevice,
        assignments: [KeyboardModifierAssignment],
        windowsKeyMapping: WindowsKeyMapping
    ) {
        lastError = nil
        do {
            var updatedMappings = keyboardMappings.filter { $0.device.id != device.id }
            updatedMappings.append(KeyboardMappingProfile(device: device, assignments: assignments))
            updatedMappings.sort { $0.device.name.localizedCaseInsensitiveCompare($1.device.name) == .orderedAscending }
            try writeKeyboardMappings(updatedMappings)

            if isEnabled {
                try replaceManagedRule(
                    mappings: updatedMappings,
                    windowsKeyMapping: windowsKeyMapping
                )
            }
            keyboardMappings = updatedMappings
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func updateWindowsKeyMapping(
        from previousMapping: WindowsKeyMapping,
        to updatedMapping: WindowsKeyMapping
    ) -> Bool {
        lastError = nil
        guard previousMapping != updatedMapping else { return true }
        let previousKeyboardMappings = keyboardMappings
        let updatedKeyboardMappings = keyboardMappings.map {
            $0.preservingLogicalOutputs(from: previousMapping, to: updatedMapping)
        }
        do {
            if isEnabled {
                try replaceManagedRule(
                    mappings: updatedKeyboardMappings,
                    windowsKeyMapping: updatedMapping
                )
            }
            try writeKeyboardMappings(updatedKeyboardMappings)
            keyboardMappings = updatedKeyboardMappings
            refresh()
            return true
        } catch {
            let updateError = error
            if isEnabled {
                try? replaceManagedRule(
                    mappings: previousKeyboardMappings,
                    windowsKeyMapping: previousMapping
                )
            }
            try? writeKeyboardMappings(previousKeyboardMappings)
            keyboardMappings = previousKeyboardMappings
            refresh()
            lastError = updateError.localizedDescription
            return false
        }
    }

    func disable(preferences: PreferencesStore) {
        lastError = nil
        do {
            let state = try readState()
            let currentRoot = try readConfiguration()
            let currentData = try canonicalData(currentRoot)
            guard currentData.base64EncodedString() == state.installedConfiguration else {
                throw IntegrationError.configurationChanged(backupPath: state.backupPath)
            }
            guard let originalData = Data(base64Encoded: state.originalConfiguration) else {
                throw IntegrationError.invalidRecoveryState
            }

            try writeConfiguration(originalData)
            state.previousPreferences.restore(to: preferences)
            try fileManager.removeItem(at: stateURL)
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func updateConfiguration(
        _ transform: ([String: Any]) throws -> [String: Any]
    ) throws {
        let currentRoot = try readConfiguration()
        let currentData = try canonicalData(currentRoot)
        let updatedData = try canonicalData(transform(currentRoot))

        guard fileManager.fileExists(atPath: stateURL.path) else {
            try writeConfiguration(updatedData)
            refresh()
            return
        }

        let state = try readState()
        guard currentData.base64EncodedString() == state.installedConfiguration else {
            throw IntegrationError.configurationChanged(backupPath: state.backupPath)
        }
        guard let originalData = Data(base64Encoded: state.originalConfiguration),
              let originalRoot = try JSONSerialization.jsonObject(with: originalData) as? [String: Any] else {
            throw IntegrationError.invalidRecoveryState
        }

        let updatedOriginalData = try canonicalData(transform(originalRoot))
        let updatedState = IntegrationState(
            originalConfiguration: updatedOriginalData.base64EncodedString(),
            installedConfiguration: updatedData.base64EncodedString(),
            backupPath: state.backupPath,
            previousPreferences: state.previousPreferences
        )
        try writeState(updatedState)
        do {
            try writeConfiguration(updatedData)
        } catch {
            try? writeState(state)
            throw error
        }
        refresh()
    }

    private func readConfiguration() throws -> [String: Any] {
        guard fileManager.fileExists(atPath: configURL.path) else {
            throw IntegrationError.configurationMissing
        }
        let data = try Data(contentsOf: configURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IntegrationError.invalidConfiguration
        }
        return root
    }

    private func canonicalData(_ root: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    private func writeConfiguration(_ data: Data) throws {
        let attributes = try fileManager.attributesOfItem(atPath: configURL.path)
        try data.write(to: configURL, options: .atomic)
        if let permissions = attributes[.posixPermissions] {
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: configURL.path)
        }
    }

    private func writeState(_ state: IntegrationState) throws {
        try fileManager.createDirectory(at: supportDirectoryURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        try data.write(to: stateURL, options: .atomic)
    }

    private func readState() throws -> IntegrationState {
        let data = try Data(contentsOf: stateURL)
        return try JSONDecoder().decode(IntegrationState.self, from: data)
    }

    private func readKeyboardMappings() throws -> [KeyboardMappingProfile] {
        guard fileManager.fileExists(atPath: keyboardMappingsURL.path) else { return [] }
        let data = try Data(contentsOf: keyboardMappingsURL)
        return try JSONDecoder().decode([KeyboardMappingProfile].self, from: data)
    }

    private func writeKeyboardMappings(_ mappings: [KeyboardMappingProfile]) throws {
        try fileManager.createDirectory(at: supportDirectoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(mappings).write(to: keyboardMappingsURL, options: .atomic)
    }

    private func replaceManagedRule(
        mappings: [KeyboardMappingProfile],
        windowsKeyMapping: WindowsKeyMapping
    ) throws {
        var root = try readConfiguration()
        guard var profiles = root["profiles"] as? [[String: Any]],
              let selectedIndex = profiles.firstIndex(where: { ($0["selected"] as? Bool) == true }) else {
            throw IntegrationError.selectedProfileMissing
        }
        let state = try readState()
        let currentData = try canonicalData(root)
        guard currentData.base64EncodedString() == state.installedConfiguration else {
            throw IntegrationError.configurationChanged(backupPath: state.backupPath)
        }

        var profile = profiles[selectedIndex]
        if var devices = profile["devices"] as? [[String: Any]] {
            let mappedDevices = mappings.map(\.device)
            for index in devices.indices {
                let identifiers = devices[index]["identifiers"] as? [String: Any] ?? [:]
                guard Self.targetsManagedKeyboard(identifiers, devices: mappedDevices) else { continue }
                let modifications = devices[index]["simple_modifications"] as? [[String: Any]] ?? []
                devices[index]["simple_modifications"] = modifications.filter {
                    !Self.simpleModificationTouchesManagedModifier($0)
                }
            }
            profile["devices"] = devices
        }

        var complexModifications = profile["complex_modifications"] as? [String: Any] ?? [:]
        var rules = complexModifications["rules"] as? [[String: Any]] ?? []
        rules.removeAll { Self.isManagedRule($0) }
        rules.insert(Self.managedRule(
            mappings: mappings,
            windowsKeyMapping: windowsKeyMapping
        ), at: 0)
        complexModifications["rules"] = rules
        profile["complex_modifications"] = complexModifications
        profiles[selectedIndex] = profile
        root["profiles"] = profiles

        let installedData = try canonicalData(root)
        let updatedState = IntegrationState(
            originalConfiguration: state.originalConfiguration,
            installedConfiguration: installedData.base64EncodedString(),
            backupPath: state.backupPath,
            previousPreferences: state.previousPreferences
        )
        try writeState(updatedState)
        try writeConfiguration(installedData)
    }

    private static func readKarabinerVersion() -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: karabinerCLIPath)
        process.arguments = ["--version"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private static func readConnectedKeyboards() throws -> [KarabinerKeyboardDevice] {
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
            throw IntegrationError.deviceDiscoveryFailed(message ?? "Karabiner CLI failed")
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        return try JSONDecoder().decode([ConnectedDevice].self, from: data)
            .filter {
                $0.deviceIdentifiers.isKeyboard == true
                    && $0.isVirtualDevice != true
                    && $0.deviceIdentifiers.isVirtualDevice != true
            }
            .map { device in
                let identifiers = device.deviceIdentifiers
                let isBuiltIn = device.isBuiltInKeyboard == true
                let identity: String
                if isBuiltIn {
                    identity = "built-in-keyboard"
                } else if let address = identifiers.deviceAddress, !address.isEmpty {
                    identity = "\(identifiers.vendorID ?? 0):\(identifiers.productID ?? 0):\(address)"
                } else {
                    identity = "\(identifiers.vendorID ?? 0):\(identifiers.productID ?? 0):\(device.locationID ?? 0)"
                }
                return KarabinerKeyboardDevice(
                    id: identity,
                    name: device.product.isEmpty ? "Keyboard" : device.product,
                    manufacturer: device.manufacturer,
                    vendorID: identifiers.vendorID,
                    productID: identifiers.productID,
                    locationID: device.locationID,
                    deviceAddress: identifiers.deviceAddress,
                    isBuiltIn: isBuiltIn
                )
            }
            .sorted {
                if $0.isBuiltIn != $1.isBuiltIn { return $0.isBuiltIn }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    private static func defaultBuiltInMapping(for device: KarabinerKeyboardDevice) -> KeyboardMappingProfile {
        KeyboardMappingProfile(
            device: device,
            assignments: [
                KeyboardModifierAssignment(side: .left, role: .control, physicalKey: "fn"),
                KeyboardModifierAssignment(side: .left, role: .function, physicalKey: "left_control"),
                KeyboardModifierAssignment(side: .left, role: .windows, physicalKey: "left_option"),
                KeyboardModifierAssignment(side: .left, role: .alt, physicalKey: "left_command")
            ]
        )
    }

    private static func selectedProfile(in root: [String: Any]) -> [String: Any]? {
        (root["profiles"] as? [[String: Any]])?.first { ($0["selected"] as? Bool) == true }
    }

    private static func containsManagedRule(_ profile: [String: Any]) -> Bool {
        let complexModifications = profile["complex_modifications"] as? [String: Any]
        let rules = complexModifications?["rules"] as? [[String: Any]] ?? []
        return rules.contains(where: isManagedRule)
    }

    private static func containsCurrentManagedRule(
        _ profile: [String: Any],
        mappings: [KeyboardMappingProfile],
        windowsKeyMapping: WindowsKeyMapping
    ) -> Bool {
        let complexModifications = profile["complex_modifications"] as? [String: Any]
        let rules = complexModifications?["rules"] as? [[String: Any]] ?? []
        guard let currentRule = rules.first(where: isManagedRule),
              let currentData = try? JSONSerialization.data(
                  withJSONObject: currentRule,
                  options: [.sortedKeys]
              ),
              let expectedData = try? JSONSerialization.data(
                  withJSONObject: managedRule(
                      mappings: mappings,
                      windowsKeyMapping: windowsKeyMapping
                  ),
                  options: [.sortedKeys]
              ) else { return false }
        return currentData == expectedData
    }

    private static func isManagedRule(_ rule: [String: Any]) -> Bool {
        (rule["description"] as? String)?.hasPrefix(managedRulePrefix) == true
    }

    private static func countConflicts(
        in profile: [String: Any],
        mappings: [KeyboardMappingProfile]
    ) -> Int {
        removingConflicts(from: profile, mappings: mappings).count
    }

    private static func removingConflicts(
        from profile: [String: Any],
        mappings: [KeyboardMappingProfile]
    ) -> (profile: [String: Any], count: Int) {
        var profile = profile
        var count = 0

        if var devices = profile["devices"] as? [[String: Any]] {
            for index in devices.indices {
                let identifiers = devices[index]["identifiers"] as? [String: Any] ?? [:]
                guard Self.targetsBuiltInOrGenericKeyboard(identifiers)
                        || Self.targetsManagedKeyboard(identifiers, devices: mappings.map(\.device)) else { continue }
                let modifications = devices[index]["simple_modifications"] as? [[String: Any]] ?? []
                let retained = modifications.filter { modification in
                    let conflicts = Self.simpleModificationTouchesManagedModifier(modification)
                    if conflicts { count += 1 }
                    return !conflicts
                }
                devices[index]["simple_modifications"] = retained
            }
            profile["devices"] = devices
        }

        var complexModifications = profile["complex_modifications"] as? [String: Any] ?? [:]
        let rules = complexModifications["rules"] as? [[String: Any]] ?? []
        var retainedRules: [[String: Any]] = []
        for var rule in rules where !Self.isManagedRule(rule) {
            let manipulators = rule["manipulators"] as? [[String: Any]] ?? []
            let retainedManipulators = manipulators.filter { manipulator in
                let conflicts = Self.manipulatorStartsWithManagedModifier(manipulator)
                if conflicts { count += 1 }
                return !conflicts
            }
            if !retainedManipulators.isEmpty {
                rule["manipulators"] = retainedManipulators
                retainedRules.append(rule)
            }
        }
        complexModifications["rules"] = retainedRules
        profile["complex_modifications"] = complexModifications
        return (profile, count)
    }

    private static func targetsBuiltInOrGenericKeyboard(_ identifiers: [String: Any]) -> Bool {
        guard (identifiers["is_keyboard"] as? Bool) == true else { return false }
        if (identifiers["is_built_in_keyboard"] as? Bool) == true { return true }
        return identifiers["vendor_id"] == nil && identifiers["product_id"] == nil
    }

    private static func targetsManagedKeyboard(
        _ identifiers: [String: Any],
        devices: [KarabinerKeyboardDevice]
    ) -> Bool {
        devices.contains { device in
            if device.isBuiltIn {
                return (identifiers["is_built_in_keyboard"] as? Bool) == true
            }
            guard identifiers["vendor_id"] as? Int == device.vendorID,
                  identifiers["product_id"] as? Int == device.productID else { return false }
            if let address = device.deviceAddress, !address.isEmpty {
                return identifiers["device_address"] as? String == address
            }
            if let locationID = device.locationID,
               let configuredLocation = identifiers["location_id"] as? Int {
                return configuredLocation == locationID
            }
            return true
        }
    }

    private static func simpleModificationTouchesManagedModifier(_ modification: [String: Any]) -> Bool {
        let from = modification["from"] as? [String: Any]
        if let keyCode = from?["key_code"] as? String, managedModifierKeys.contains(keyCode) { return true }
        let outputs = modification["to"] as? [[String: Any]] ?? []
        return outputs.contains { output in
            guard let keyCode = output["key_code"] as? String else { return false }
            return managedModifierKeys.contains(keyCode)
        }
    }

    private static func manipulatorStartsWithManagedModifier(_ manipulator: [String: Any]) -> Bool {
        let from = manipulator["from"] as? [String: Any]
        guard let keyCode = from?["key_code"] as? String else { return false }
        return managedModifierKeys.contains(keyCode)
    }

    private static func managedRule(
        mappings: [KeyboardMappingProfile],
        windowsKeyMapping: WindowsKeyMapping
    ) -> [String: Any] {
        var manipulators: [[String: Any]] = []
        let terminalCondition = applicationCondition(
            type: "frontmost_application_if",
            bundleIdentifiers: ["^com\\.apple\\.Terminal$", "^com\\.googlecode\\.iterm2$"]
        )
        let regularApplicationCondition = applicationCondition(
            type: "frontmost_application_unless",
            bundleIdentifiers: ["^com\\.microsoft\\.rdc\\.macos$"]
        )
        let windowsAppCondition = applicationCondition(
            type: "frontmost_application_if",
            bundleIdentifiers: ["^com\\.microsoft\\.rdc\\.macos$"]
        )

        for mapping in mappings {
            let deviceCondition = deviceCondition(for: mapping.device)
            for assignment in mapping.assignments {
                let localOutput = assignment.role.localOutput(
                    for: assignment.side,
                    windowsKeyMapping: windowsKeyMapping
                )
                let windowsOutput = assignment.role.windowsAppOutput(for: assignment.side)
                if localOutput == windowsOutput {
                    if assignment.physicalKey != localOutput {
                        manipulators.append(keyMapping(
                            from: assignment.physicalKey,
                            to: localOutput,
                            conditions: [deviceCondition]
                        ))
                    }
                } else {
                    if assignment.physicalKey != localOutput {
                        manipulators.append(keyMapping(
                            from: assignment.physicalKey,
                            to: localOutput,
                            conditions: [deviceCondition, regularApplicationCondition]
                        ))
                    }
                    guard assignment.physicalKey != windowsOutput else { continue }
                    manipulators.append(keyMapping(
                        from: assignment.physicalKey,
                        to: windowsOutput,
                        conditions: [deviceCondition, windowsAppCondition]
                    ))
                }
            }
        }

        for key in ["t", "n", "w", "c", "v", "f"] {
            manipulators.append(controlShiftShortcut(
                key: key,
                outputModifiers: ["left_command"],
                conditions: [terminalCondition]
            ))
        }

        return [
            "description": managedRuleDescription,
            "manipulators": manipulators
        ]
    }

    private static func deviceCondition(for device: KarabinerKeyboardDevice) -> [String: Any] {
        [
            "type": "device_if",
            "identifiers": [device.conditionIdentifier]
        ]
    }

    private static func applicationCondition(type: String, bundleIdentifiers: [String]) -> [String: Any] {
        ["type": type, "bundle_identifiers": bundleIdentifiers]
    }

    private static func keyMapping(from: String, to: String, conditions: [[String: Any]]) -> [String: Any] {
        [
            "type": "basic",
            "from": ["key_code": from, "modifiers": ["optional": ["any"]]],
            "to": [["key_code": to]],
            "conditions": conditions
        ]
    }

    private static func controlShiftShortcut(
        key: String,
        outputModifiers: [String],
        conditions: [[String: Any]]
    ) -> [String: Any] {
        [
            "type": "basic",
            "from": [
                "key_code": key,
                "modifiers": ["mandatory": ["control", "shift"]]
            ],
            "to": [["key_code": key, "modifiers": outputModifiers]],
            "conditions": conditions
        ]
    }

    private static func backupFileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "karabiner-\(formatter.string(from: Date())).json"
    }
}

private struct ConnectedDevice: Decodable {
    let deviceIdentifiers: ConnectedDeviceIdentifiers
    let isBuiltInKeyboard: Bool?
    let isVirtualDevice: Bool?
    let locationID: Int?
    let manufacturer: String?
    let product: String

    enum CodingKeys: String, CodingKey {
        case deviceIdentifiers = "device_identifiers"
        case isBuiltInKeyboard = "is_built_in_keyboard"
        case isVirtualDevice = "is_virtual_device"
        case locationID = "location_id"
        case manufacturer
        case product
    }
}

private struct ConnectedDeviceIdentifiers: Decodable {
    let vendorID: Int?
    let productID: Int?
    let deviceAddress: String?
    let isKeyboard: Bool?
    let isVirtualDevice: Bool?

    enum CodingKeys: String, CodingKey {
        case vendorID = "vendor_id"
        case productID = "product_id"
        case deviceAddress = "device_address"
        case isKeyboard = "is_keyboard"
        case isVirtualDevice = "is_virtual_device"
    }
}

private struct IntegrationState: Codable {
    let originalConfiguration: String
    let installedConfiguration: String
    let backupPath: String
    let previousPreferences: StoredPreferences
}

private struct StoredPreferences: Codable {
    let globalHotkeysEnabled: Bool
    let altTabSwitcherEnabled: Bool
    let altTabModifier: AltTabModifier
    let windowsKeyMapping: WindowsKeyMapping
    let windowsKeyOpensStart: Bool

    @MainActor
    init(preferences: PreferencesStore) {
        globalHotkeysEnabled = preferences.globalHotkeysEnabled
        altTabSwitcherEnabled = preferences.altTabSwitcherEnabled
        altTabModifier = preferences.altTabModifier
        windowsKeyMapping = preferences.windowsKeyMapping
        windowsKeyOpensStart = preferences.windowsKeyOpensStart
    }

    @MainActor
    func restore(to preferences: PreferencesStore) {
        preferences.globalHotkeysEnabled = globalHotkeysEnabled
        preferences.altTabSwitcherEnabled = altTabSwitcherEnabled
        preferences.altTabModifier = altTabModifier
        preferences.windowsKeyMapping = windowsKeyMapping
        preferences.windowsKeyOpensStart = windowsKeyOpensStart
    }
}

private enum IntegrationError: LocalizedError {
    case karabinerUnavailable
    case configurationMissing
    case invalidConfiguration
    case selectedProfileMissing
    case invalidRecoveryState
    case deviceDiscoveryFailed(String)
    case configurationChanged(backupPath: String)

    var errorDescription: String? {
        switch self {
        case .karabinerUnavailable:
            NSLocalizedString(
                "Karabiner-Elements is not installed or has not created a configuration yet.",
                comment: "Karabiner integration error"
            )
        case .configurationMissing:
            NSLocalizedString("Karabiner-Elements configuration was not found.", comment: "Karabiner integration error")
        case .invalidConfiguration:
            NSLocalizedString("Karabiner-Elements configuration is not valid JSON.", comment: "Karabiner integration error")
        case .selectedProfileMissing:
            NSLocalizedString("Karabiner-Elements has no selected profile.", comment: "Karabiner integration error")
        case .invalidRecoveryState:
            NSLocalizedString("WinTaskbar's Karabiner recovery data is invalid.", comment: "Karabiner integration error")
        case let .deviceDiscoveryFailed(message):
            String(
                format: NSLocalizedString(
                    "Karabiner keyboard discovery failed: %@",
                    comment: "Karabiner integration error"
                ),
                message
            )
        case let .configurationChanged(backupPath):
            String(
                format: NSLocalizedString(
                    "Karabiner settings changed after Windows keyboard mode was enabled. To protect those changes, WinTaskbar did not overwrite them. Original backup: %@",
                    comment: "Karabiner integration error with backup path"
                ),
                backupPath
            )
        }
    }
}
