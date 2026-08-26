import AppKit
import Combine
import Foundation

struct TaskbarItemOrder {
    private(set) var bundleIDs: [String] = []

    mutating func reconcile(pinnedBundleIDs: [String], runningBundleIDs: [String]) -> [String] {
        let eligible = Set(pinnedBundleIDs + runningBundleIDs)
        bundleIDs.removeAll { !eligible.contains($0) }

        var included = Set(bundleIDs)
        for bundleID in pinnedBundleIDs + runningBundleIDs where included.insert(bundleID).inserted {
            bundleIDs.append(bundleID)
        }
        return bundleIDs
    }

    mutating func move(_ bundleID: String, relativeTo destination: String, after: Bool) -> Bool {
        guard bundleID != destination,
              let sourceIndex = bundleIDs.firstIndex(of: bundleID),
              bundleIDs.contains(destination) else { return false }
        let previous = bundleIDs
        let value = bundleIDs.remove(at: sourceIndex)
        guard let destinationIndex = bundleIDs.firstIndex(of: destination) else { return false }
        bundleIDs.insert(value, at: after ? destinationIndex + 1 : destinationIndex)
        return bundleIDs != previous
    }
}

@MainActor
final class AppDiscoveryService: ObservableObject {
    @Published private(set) var runningApps: [DiscoveredApp] = []
    @Published private(set) var installedApps: [DiscoveredApp] = []

    private let workspace: NSWorkspace
    private var observers: [NSObjectProtocol] = []
    private var knownAppsByID: [String: DiscoveredApp] = [:]
    private var taskbarItemOrder = TaskbarItemOrder()

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
        let discovered = workspace.runningApplications
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
        remember(discovered)
        runningApps = discovered
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
        let discovered = appsByID.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        remember(discovered)
        installedApps = discovered
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
            ?? knownApp(bundleIdentifier: bundleIdentifier)
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

        let pinnedSet = Set(pinnedBundleIDs)
        let availablePinnedBundleIDs = pinnedBundleIDs.filter { knownApp(bundleIdentifier: $0) != nil }
        var visibleRunningBundleIDs: [String] = []
        var includedRunning = Set<String>()
        for app in runningApps {
            guard let bundleID = app.bundleIdentifier,
                  includedRunning.insert(bundleID).inserted else { continue }
            if !showFinder && bundleID == "com.apple.finder" && !pinnedSet.contains(bundleID) { continue }
            visibleRunningBundleIDs.append(bundleID)
        }

        let orderedBundleIDs = taskbarItemOrder.reconcile(
            pinnedBundleIDs: availablePinnedBundleIDs,
            runningBundleIDs: visibleRunningBundleIDs
        )
        return orderedBundleIDs.compactMap { bundleID in
            guard let app = runningByID[bundleID] ?? installedByID[bundleID] ?? knownAppsByID[bundleID] else {
                return nil
            }
            let running = runningByID[bundleID]
            return TaskbarItem(
                bundleIdentifier: bundleID,
                name: app.name,
                url: app.url,
                isPinned: pinnedSet.contains(bundleID),
                isRunning: running != nil,
                isActive: running?.isActive ?? false,
                processIdentifier: running?.processIdentifier,
                badge: badges[bundleID]
            )
        }
    }

    @discardableResult
    func reorderTaskbarItem(_ bundleID: String, relativeTo destination: String, after: Bool) -> Bool {
        taskbarItemOrder.move(bundleID, relativeTo: destination, after: after)
    }

    var taskbarBundleOrder: [String] { taskbarItemOrder.bundleIDs }

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

    private func remember(_ apps: [DiscoveredApp]) {
        for app in apps {
            guard let bundleID = app.bundleIdentifier else { continue }
            knownAppsByID[bundleID] = app
        }
    }

    private func knownApp(bundleIdentifier: String) -> DiscoveredApp? {
        if let app = knownAppsByID[bundleIdentifier] { return app }
        guard let url = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        let bundle = Bundle(url: url)
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let app = DiscoveredApp(
            name: name,
            bundleIdentifier: bundleIdentifier,
            url: url,
            isRunning: false
        )
        knownAppsByID[bundleIdentifier] = app
        return app
    }
}
