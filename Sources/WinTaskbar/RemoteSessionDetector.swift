import AppKit
import CoreGraphics

enum RemoteSessionDetector {
    static let screenSharingAgentBundleIdentifier = "com.apple.screensharing.agent"

    static func isActive(
        isOnConsole: Bool?,
        runningBundleIdentifiers: Set<String>
    ) -> Bool {
        if isOnConsole == false {
            return true
        }
        return runningBundleIdentifiers.contains(screenSharingAgentBundleIdentifier)
    }

    @MainActor
    static var isActive: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let isOnConsole = session?[kCGSessionOnConsoleKey as String] as? Bool
        let runningBundleIdentifiers = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        )
        return isActive(
            isOnConsole: isOnConsole,
            runningBundleIdentifiers: runningBundleIdentifiers
        )
    }
}
