import AppKit
import Combine
import Foundation

@MainActor
final class AppDiscoveryService: ObservableObject {
    @Published private(set) var runningApps: [DiscoveredApp] = []
    @Published private(set) var installedApps: [DiscoveredApp] = []

    private let workspace: NSWorkspace
    private var observers: [NSObjectProtocol] = []

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
        reloadRunningApps()
        reloadInstalledApps()

        let center = workspace.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reloadRunningApps()
                }
            })
        }
    }

    func reloadRunningApps() {
        runningApps = workspace.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .compactMap { app -> DiscoveredApp? in
                guard let url = app.bundleURL, let name = app.localizedName else { return nil }
                return DiscoveredApp(
                    name: name,
                    bundleIdentifier: app.bundleIdentifier,
                    url: url,
                    isRunning: true,
                    isActive: app.isActive,
                    processIdentifier: app.processIdentifier
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func reloadInstalledApps() {
        var appsByID: [String: DiscoveredApp] = [:]
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        ]

        for root in roots {
            scanApps(in: root, depth: 0, into: &appsByID)
        }
        installedApps = appsByID.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func scanApps(in directory: URL, depth: Int, into result: inout [String: DiscoveredApp]) {
        guard depth <= 2,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isApplicationKey],
                options: [.skipsHiddenFiles]
              ) else { return }

        for url in urls {
            if url.pathExtension == "app" {
                let bundle = Bundle(url: url)
                let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                let identifier = bundle?.bundleIdentifier
                let category = bundle?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
                let app = DiscoveredApp(
                    name: name,
                    bundleIdentifier: identifier,
                    url: url,
                    category: category,
                    isRunning: false
                )
                result[identifier ?? url.path] = app
            } else {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    scanApps(in: url, depth: depth + 1, into: &result)
                }
            }
        }
    }

    func open(_ app: DiscoveredApp) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.openApplication(at: app.url, configuration: configuration)
    }

    func app(bundleIdentifier: String) -> DiscoveredApp? {
        runningApps.first { $0.bundleIdentifier == bundleIdentifier }
            ?? installedApps.first { $0.bundleIdentifier == bundleIdentifier }
    }

    func taskbarItems(pinnedBundleIDs: [String], badges: [String: String], showFinder: Bool) -> [TaskbarItem] {
        var installedByID: [String: DiscoveredApp] = [:]
        for app in installedApps {
            if let bundleID = app.bundleIdentifier, installedByID[bundleID] == nil { installedByID[bundleID] = app }
        }
        var runningByID: [String: DiscoveredApp] = [:]
        for app in runningApps {
            if let bundleID = app.bundleIdentifier, runningByID[bundleID] == nil { runningByID[bundleID] = app }
        }

        var items: [TaskbarItem] = []
        var included = Set<String>()
        for bundleID in pinnedBundleIDs {
            guard let app = runningByID[bundleID] ?? installedByID[bundleID] else { continue }
            let running = runningByID[bundleID]
            items.append(TaskbarItem(
                bundleIdentifier: bundleID,
                name: app.name,
                url: app.url,
                isPinned: true,
                isRunning: running != nil,
                isActive: running?.isActive ?? false,
                processIdentifier: running?.processIdentifier,
                badge: badges[bundleID]
            ))
            included.insert(bundleID)
        }
        for app in runningApps {
            guard let bundleID = app.bundleIdentifier, !included.contains(bundleID) else { continue }
            if !showFinder && bundleID == "com.apple.finder" { continue }
            items.append(TaskbarItem(
                bundleIdentifier: bundleID,
                name: app.name,
                url: app.url,
                isPinned: false,
                isRunning: true,
                isActive: app.isActive,
                processIdentifier: app.processIdentifier,
                badge: badges[bundleID]
            ))
        }
        return items
    }

    func open(_ item: TaskbarItem) {
        if let pid = item.processIdentifier,
           let running = NSRunningApplication(processIdentifier: pid) {
            running.activate(options: [.activateIgnoringOtherApps])
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.openApplication(at: item.url, configuration: configuration)
    }

    func quit(_ item: TaskbarItem) {
        guard let pid = item.processIdentifier else { return }
        NSRunningApplication(processIdentifier: pid)?.terminate()
    }

    func showInFinder(_ item: TaskbarItem) {
        workspace.activateFileViewerSelecting([item.url])
    }
}
