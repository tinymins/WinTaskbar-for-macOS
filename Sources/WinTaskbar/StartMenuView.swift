import AppKit
import SwiftUI

struct StartMenuView: View {
    @ObservedObject var apps: AppDiscoveryService
    @ObservedObject var actions: AppActions
    @ObservedObject var preferences: PreferencesStore
    @State private var query = ""
    @State private var showingSettings = false

    private var filteredApps: [DiscoveredApp] {
        guard !query.isEmpty else { return apps.installedApps }
        return apps.installedApps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var groupedBundleIDs: Set<String> {
        Set(preferences.appFolders.flatMap(\.bundleIDs))
    }

    var body: some View {
        HStack(spacing: 0) {
            if preferences.menuActionsSide == .left { actionRail; Divider() }
            Group {
                if showingSettings { settingsPanel }
                else { appsPanel }
            }
            if preferences.menuActionsSide == .right { Divider(); actionRail }
        }
        .frame(width: 480, height: preferences.menuHeightMode == .full ? 760 : 560)
        .background(.ultraThinMaterial)
        .onExitCommand { actions.closeStartMenu() }
    }

    private var appsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if preferences.searchFieldPosition == .top { searchField }
            HStack {
                Text(query.isEmpty ? "Apps" : "Search results").font(.headline)
                Spacer()
                Button { addFolder() } label: { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(.plain).help("New folder")
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if query.isEmpty {
                        ForEach(Array(preferences.appFolders.enumerated()), id: \.element.id) { index, folder in
                            folderSection(folder, index: index)
                        }
                    }

                    if preferences.groupStartMenuByCategory && query.isEmpty {
                        ForEach(categoryGroups, id: \.0) { category, categoryApps in
                            DisclosureGroup(category) {
                                ForEach(categoryApps) { appRow($0, currentFolderID: nil) }
                            }.padding(.vertical, 3)
                        }
                    } else {
                        ForEach(ungroupedApps) { appRow($0, currentFolderID: nil) }
                    }
                }
            }

            if filteredApps.isEmpty {
                Text("No apps found").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if preferences.searchFieldPosition == .bottom { searchField }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var settingsPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Button { showingSettings = false } label: { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.plain)
                Spacer()
            }
            .padding(12)
            Divider()
            SettingsView(preferences: preferences)
        }
    }

    private var searchField: some View {
        TextField("Search apps", text: $query)
            .textFieldStyle(.roundedBorder)
            .onSubmit {
                if let first = filteredApps.first { open(first) }
            }
    }

    private var ungroupedApps: [DiscoveredApp] {
        if !query.isEmpty { return filteredApps }
        return filteredApps.filter { app in
            guard let bundleID = app.bundleIdentifier else { return true }
            return !groupedBundleIDs.contains(bundleID)
        }
    }

    private var categoryGroups: [(String, [DiscoveredApp])] {
        let source = filteredApps.filter { app in
            guard let bundleID = app.bundleIdentifier else { return true }
            return !groupedBundleIDs.contains(bundleID)
        }
        let grouped = Dictionary(grouping: source) { app -> String in
            guard let category = app.category?.split(separator: ".").last else { return "Other" }
            return String(category).replacingOccurrences(of: "-", with: " ").capitalized
        }
        return grouped.sorted { $0.key < $1.key }
    }

    @ViewBuilder
    private func folderSection(_ folder: AppFolder, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Button {
                    preferences.appFolders[index].isExpanded.toggle()
                } label: {
                    Image(systemName: folder.isExpanded ? "chevron.down" : "chevron.right")
                    Image(systemName: "folder")
                    Text(folder.name).fontWeight(.medium)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { bundleIDs, _ in
                guard let bundleID = bundleIDs.first else { return false }
                move(bundleID: bundleID, to: folder.id)
                return true
            }
            .contextMenu {
                Button("Rename folder") { renameFolder(index) }
                Button("Delete folder") { preferences.appFolders.remove(at: index) }
            }

            if folder.isExpanded {
                ForEach(folder.bundleIDs.compactMap { apps.app(bundleIdentifier: $0) }) {
                    appRow($0, currentFolderID: folder.id)
                }
            }
        }
    }

    private func appRow(_ app: DiscoveredApp, currentFolderID: String?) -> some View {
        Button { open(app) } label: {
            HStack(spacing: 9) {
                Image(nsImage: app.icon).resizable().interpolation(.high).frame(width: 24, height: 24)
                Text(app.name).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .draggable(app.bundleIdentifier ?? app.url.path)
        .contextMenu {
            if let bundleID = app.bundleIdentifier {
                Menu("Add to folder") {
                    ForEach(preferences.appFolders) { folder in
                        Button(folder.name) { move(bundleID: bundleID, to: folder.id) }
                    }
                }
                if currentFolderID != nil { Button("Remove from folder") { move(bundleID: bundleID, to: nil) } }
                Divider()
                if preferences.pinnedBundleIDs.contains(bundleID) { Button("Unpin") { preferences.unpin(bundleID) } }
                else { Button("Pin to Taskbar") { preferences.pin(bundleID) } }
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
        }
    }

    private var actionRail: some View {
        VStack(spacing: 17) {
            Button { showingSettings = true } label: { Image(systemName: "gearshape") }.help("Settings")
            Button { actions.fitWindows(); actions.closeStartMenu() } label: { Image(systemName: "rectangle.arrowtriangle.2.inward") }.help("Fit windows")
            menuShortcuts
            Spacer()
            Button { actions.performPower(.lockScreen) } label: { Image(systemName: "lock.fill") }.help("Lock Screen")
            Button { actions.performPower(.sleep) } label: { Image(systemName: "moon.fill") }.help("Sleep")
            Button { actions.performPower(.logOut) } label: { Image(systemName: "rectangle.portrait.and.arrow.right") }.help("Log Out")
            Button { actions.performPower(.restart) } label: { Image(systemName: "arrow.clockwise") }.help("Restart")
            Button { actions.performPower(.shutDown) } label: { Image(systemName: "power") }.help("Shut Down")
        }
        .buttonStyle(.plain)
        .font(.system(size: 16))
        .padding(.vertical, 18)
        .frame(width: 54)
    }

    private var menuShortcuts: some View {
        VStack(spacing: 10) {
            ForEach(preferences.menuShortcutPaths, id: \.self) { path in
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } label: {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 22, height: 22)
                }
                .help(URL(fileURLWithPath: path).lastPathComponent)
                .contextMenu { Button("Remove") { preferences.menuShortcutPaths.removeAll { $0 == path } } }
            }
            Image(systemName: "plus")
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3])))
                .help("Drop an app or file here to add a shortcut")
                .dropDestination(for: URL.self) { urls, _ in
                    for url in urls where !preferences.menuShortcutPaths.contains(url.path) {
                        preferences.menuShortcutPaths.append(url.path)
                    }
                    return !urls.isEmpty
                }
        }
    }

    private func open(_ app: DiscoveredApp) {
        apps.open(app)
        actions.closeStartMenu()
    }

    private func addFolder() {
        let number = preferences.appFolders.count + 1
        preferences.appFolders.append(AppFolder(name: "New Folder \(number)"))
    }

    private func move(bundleID: String, to folderID: String?) {
        for index in preferences.appFolders.indices {
            preferences.appFolders[index].bundleIDs.removeAll { $0 == bundleID }
        }
        if let folderID, let index = preferences.appFolders.firstIndex(where: { $0.id == folderID }) {
            preferences.appFolders[index].bundleIDs.append(bundleID)
            preferences.appFolders[index].isExpanded = true
        }
    }

    private func renameFolder(_ index: Int) {
        let alert = NSAlert()
        alert.messageText = "Rename folder"
        let field = NSTextField(string: preferences.appFolders[index].name)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
            preferences.appFolders[index].name = field.stringValue
        }
    }
}
