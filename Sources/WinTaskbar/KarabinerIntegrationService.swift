import Combine
import Foundation

@MainActor
final class KarabinerIntegrationService: ObservableObject {
    static let shared = KarabinerIntegrationService()

    private static let managedRulePrefix = "WinTaskbar managed: Windows keyboard mode"
    private static let managedRuleDescription = "WinTaskbar managed: Windows keyboard mode v1"
    private static let karabinerCLIPath = "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"
    private static let managedModifierKeys: Set<String> = ["fn", "left_command", "left_control", "left_option"]

    @Published private(set) var isAvailable = false
    @Published private(set) var isEnabled = false
    @Published private(set) var version: String?
    @Published private(set) var conflictCount = 0
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
        supportDirectoryURL.appendingPathComponent("karabiner-integration-state.json")
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
            let root = try readConfiguration()
            guard let profile = Self.selectedProfile(in: root) else {
                isEnabled = false
                conflictCount = 0
                return
            }
            isEnabled = Self.containsManagedRule(profile)
            conflictCount = isEnabled ? 0 : Self.countConflicts(in: profile)
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
            let removal = Self.removingConflicts(from: profiles[selectedIndex])
            var profile = removal.profile
            var complexModifications = profile["complex_modifications"] as? [String: Any] ?? [:]
            var rules = complexModifications["rules"] as? [[String: Any]] ?? []
            rules.insert(Self.managedRule(), at: 0)
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
                  !Self.containsCurrentManagedRule(profiles[selectedIndex]) else { return }

            let state = try readState()
            let currentData = try canonicalData(root)
            guard currentData.base64EncodedString() == state.installedConfiguration else {
                throw IntegrationError.configurationChanged(backupPath: state.backupPath)
            }

            var profile = profiles[selectedIndex]
            var complexModifications = profile["complex_modifications"] as? [String: Any] ?? [:]
            var rules = complexModifications["rules"] as? [[String: Any]] ?? []
            rules.removeAll { Self.isManagedRule($0) }
            rules.insert(Self.managedRule(), at: 0)
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
            refresh()
        } catch {
            lastError = error.localizedDescription
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

    private static func selectedProfile(in root: [String: Any]) -> [String: Any]? {
        (root["profiles"] as? [[String: Any]])?.first { ($0["selected"] as? Bool) == true }
    }

    private static func containsManagedRule(_ profile: [String: Any]) -> Bool {
        let complexModifications = profile["complex_modifications"] as? [String: Any]
        let rules = complexModifications?["rules"] as? [[String: Any]] ?? []
        return rules.contains(where: isManagedRule)
    }

    private static func containsCurrentManagedRule(_ profile: [String: Any]) -> Bool {
        let complexModifications = profile["complex_modifications"] as? [String: Any]
        let rules = complexModifications?["rules"] as? [[String: Any]] ?? []
        return rules.contains { ($0["description"] as? String) == managedRuleDescription }
    }

    private static func isManagedRule(_ rule: [String: Any]) -> Bool {
        (rule["description"] as? String)?.hasPrefix(managedRulePrefix) == true
    }

    private static func countConflicts(in profile: [String: Any]) -> Int {
        removingConflicts(from: profile).count
    }

    private static func removingConflicts(from profile: [String: Any]) -> (profile: [String: Any], count: Int) {
        var profile = profile
        var count = 0

        if var devices = profile["devices"] as? [[String: Any]] {
            for index in devices.indices {
                let identifiers = devices[index]["identifiers"] as? [String: Any] ?? [:]
                guard Self.targetsBuiltInOrGenericKeyboard(identifiers) else { continue }
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

    private static func managedRule() -> [String: Any] {
        var manipulators: [[String: Any]] = []
        let builtInCondition = deviceCondition()
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

        manipulators.append(keyMapping(
            from: "left_option",
            to: "left_command",
            conditions: [builtInCondition, windowsAppCondition]
        ))
        manipulators.append(keyMapping(
            from: "left_option",
            to: "left_control",
            conditions: [builtInCondition, regularApplicationCondition]
        ))
        manipulators.append(keyMapping(from: "fn", to: "left_control", conditions: [builtInCondition, windowsAppCondition]))
        manipulators.append(keyMapping(from: "fn", to: "left_command", conditions: [builtInCondition, regularApplicationCondition]))
        manipulators.append(keyMapping(from: "left_control", to: "fn", conditions: [builtInCondition]))
        manipulators.append(keyMapping(from: "left_command", to: "left_option", conditions: [builtInCondition]))

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

    private static func deviceCondition() -> [String: Any] {
        [
            "type": "device_if",
            "identifiers": [["is_built_in_keyboard": true]]
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
