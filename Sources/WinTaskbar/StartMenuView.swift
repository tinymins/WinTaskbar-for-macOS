import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum FileURLDropLoader {
    static func matchingProviders(in providers: [NSItemProvider]) -> [NSItemProvider] {
        providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
    }

    static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: NSURL.self) { object, _ in
                continuation.resume(returning: object as? URL)
            }
        }
    }
}

struct StartMenuView: View {
    @ObservedObject var apps: AppDiscoveryService
    @ObservedObject var actions: AppActions
    @ObservedObject var preferences: PreferencesStore
    @State private var query = ""
    @State private var showingSettings = false
    @State private var shortcutIsDropTarget = false

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
            mainPanel
            if preferences.menuActionsSide == .right { Divider(); actionRail }
        }
        .frame(width: 400)
        .frame(maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.18), value: showingSettings)
        .onExitCommand { actions.closeStartMenu() }
    }

    private var mainPanel: some View {
        ZStack {
            appsPanel
                .opacity(showingSettings ? 0 : 1)
                .allowsHitTesting(!showingSettings)
            settingsPanel
                .opacity(showingSettings ? 1 : 0)
                .allowsHitTesting(showingSettings)
        }
    }

    private var appsPanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            if preferences.searchFieldPosition == .top { searchField }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if query.isEmpty {
                        ForEach(preferences.appFolders) { folder in
                            folderSection(folder)
                        }
                    }

                    appsHeader

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
            .padding(.horizontal, -6)

            if filteredApps.isEmpty {
                Text("No apps found").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if preferences.searchFieldPosition == .bottom { searchField }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 5)
    }

    private var appsHeader: some View {
        HStack {
            Text(query.isEmpty ? "Apps" : "Search results")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button { addFolder() } label: { Image(systemName: "folder.badge.plus") }
                .buttonStyle(.plain)
                .help("New folder")
        }
        .padding(.horizontal, 8)
    }

    private var settingsPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Button { showingSettings = false } label: { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.plain)
                Spacer()
            }
            .padding(8)
            Divider()
            SettingsView(preferences: preferences)
        }
    }

    private var searchField: some View {
        MenuSearchField(text: $query, placeholder: "Search apps") {
            if let first = filteredApps.first { open(first) }
        }
            .frame(height: 22)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            }
            .padding(.horizontal, -4)
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
    private func folderSection(_ folder: AppFolder) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            StartMenuFolderHeader(
                folder: Binding(
                    get: { preferences.appFolders.first(where: { $0.id == folder.id }) ?? folder },
                    set: { updated in
                        guard let currentIndex = preferences.appFolders.firstIndex(where: { $0.id == folder.id }) else { return }
                        preferences.appFolders[currentIndex] = updated
                    }
                ),
                onDrop: { url in
                    guard let bundleID = Bundle(url: url)?.bundleIdentifier else { return false }
                    move(bundleID: bundleID, to: folder.id)
                    return true
                },
                onDelete: { preferences.appFolders.removeAll { $0.id == folder.id } }
            )

            if folder.isExpanded {
                ForEach(folder.bundleIDs.compactMap { apps.app(bundleIdentifier: $0) }) {
                    appRow($0, currentFolderID: folder.id)
                        .padding(.leading, 12)
                }
            }
        }
    }

    private func appRow(_ app: DiscoveredApp, currentFolderID: String?) -> some View {
        StartMenuAppRow(app: app)
        .onTapGesture { open(app) }
        .onDrag { NSItemProvider(contentsOf: app.url) ?? NSItemProvider() }
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
        VStack(spacing: 4) {
            HoveringIconButton(systemName: "gearshape", help: "Settings") {
                showingSettings = true
            }
            HoveringIconButton(systemName: "rectangle.arrowtriangle.2.inward", help: "Fit windows") {
                actions.fitWindows()
                actions.closeStartMenu()
            }
            menuShortcuts
                .frame(maxHeight: .infinity)
                .padding(.vertical, 8)
            HoveringIconButton(systemName: "lock.fill", help: "Lock Screen") {
                actions.performPower(.lockScreen)
            }
            HoveringIconButton(systemName: "moon.fill", help: "Sleep") {
                actions.performPower(.sleep)
            }
            HoveringIconButton(systemName: "rectangle.portrait.and.arrow.right", help: "Log Out") {
                actions.performPower(.logOut)
            }
            HoveringIconButton(systemName: "arrow.clockwise", help: "Restart") {
                actions.performPower(.restart)
            }
            HoveringIconButton(systemName: "power", help: "Shut Down") {
                actions.performPower(.shutDown)
            }
        }
        .padding(.vertical, 10)
        .frame(width: 52)
        .frame(maxHeight: .infinity)
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
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(shortcutIsDropTarget ? Color.accentColor.opacity(0.18) : .clear)
                }
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3])))
                .help("Drop an app or file here to add a shortcut")
                .onDrop(of: [UTType.fileURL], isTargeted: $shortcutIsDropTarget, perform: handleShortcutDrop)
        }
    }

    private func open(_ app: DiscoveredApp) {
        apps.open(app)
        actions.closeStartMenu()
    }

    private func addFolder() {
        preferences.appFolders.append(AppFolder(name: "New Folder"))
    }

    private func handleShortcutDrop(_ providers: [NSItemProvider]) -> Bool {
        let matching = FileURLDropLoader.matchingProviders(in: providers)
        guard !matching.isEmpty else { return false }
        Task {
            for provider in matching {
                guard let url = await FileURLDropLoader.loadFileURL(from: provider) else { continue }
                await MainActor.run {
                    if !preferences.menuShortcutPaths.contains(url.path) {
                        preferences.menuShortcutPaths.append(url.path)
                    }
                }
            }
        }
        return true
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

}

private struct StartMenuFolderHeader: View {
    @Binding var folder: AppFolder
    let onDrop: (URL) -> Bool
    let onDelete: () -> Void

    @State private var isEditing = false
    @State private var isHovering = false
    @State private var isDropTarget = false
    @State private var draftName = ""
    @FocusState private var nameIsFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: folder.isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 14)
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            if isEditing {
                TextField("Folder", text: $draftName)
                    .textFieldStyle(.plain)
                    .focused($nameIsFocused)
                    .onSubmit { commitName() }
                Spacer()
                Button { commitName() } label: { Image(systemName: "checkmark") }
                    .buttonStyle(.plain)
                    .help("Done")
            } else {
                Text(folder.name).lineLimit(1)
                Spacer()
                if isHovering {
                    Button { startEditing() } label: { Image(systemName: "pencil") }
                        .buttonStyle(.plain)
                        .help("Rename folder")
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isDropTarget ? Color.accentColor.opacity(0.18) : Color.primary.opacity(isHovering ? 0.08 : 0))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isEditing else { return }
            folder.isExpanded.toggle()
        }
        .onHover { isHovering = $0 }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTarget) { providers in
            guard let provider = FileURLDropLoader.matchingProviders(in: providers).first else { return false }
            Task {
                guard let url = await FileURLDropLoader.loadFileURL(from: provider) else { return }
                await MainActor.run { _ = onDrop(url) }
            }
            return true
        }
        .contextMenu {
            Button("Rename folder") { startEditing() }
            Button("Delete folder") { onDelete() }
        }
        .onChange(of: nameIsFocused) { focused in
            if !focused, isEditing { commitName() }
        }
    }

    private func startEditing() {
        draftName = folder.name
        isEditing = true
        nameIsFocused = true
    }

    private func commitName() {
        let value = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { folder.name = value }
        isEditing = false
        nameIsFocused = false
    }
}

private struct StartMenuAppRow: View {
    let app: DiscoveredApp
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 28, height: 28)
            Text(app.name).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovering ? Color.primary.opacity(0.08) : .clear)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

private struct MenuSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit)
        field.placeholderString = placeholder
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
        field.placeholderString = placeholder
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void

        init(text: Binding<String>, onSubmit: @escaping () -> Void = {}) {
            self.text = text
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        @objc func submit() {
            onSubmit()
        }
    }
}

private struct HoveringIconButton: View {
    let systemName: String
    let help: LocalizedStringKey
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .imageScale(.medium)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(width: 50, height: 50)
                .background {
                    if isHovering {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .padding(.vertical, -5)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }
}
