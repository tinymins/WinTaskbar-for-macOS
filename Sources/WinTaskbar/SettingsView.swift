import SwiftUI

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case appearance = "Appearance"
    case startMenu = "Start Menu"
    case features = "Features"
    case permissions = "Permissions"
    case hotkeys = "Hotkeys"
    case about = "About"

    var id: String { rawValue }
}

struct SettingsView: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject private var dockToggle = DockToggleService.shared
    @ObservedObject private var loginItem = LoginItemService.shared
    @ObservedObject private var permissions = PermissionsService.shared
    @State private var tab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings", selection: $tab) {
                ForEach(SettingsTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(tab.rawValue).font(.title2.bold())
                    tabContent
                }
                .padding(22)
            }
        }
        .frame(minWidth: 420, minHeight: 520)
        .onAppear {
            permissions.refresh()
            loginItem.refresh()
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .general: general
        case .appearance: appearance
        case .startMenu: startMenu
        case .features: features
        case .permissions: permissionSettings
        case .hotkeys: hotkeys
        case .about: about
        }
    }

    private var general: some View {
        VStack(spacing: 18) {
            SettingsSection(title: "Taskbar") {
            Picker("Position", selection: $preferences.position) {
                ForEach(TaskbarPosition.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Show on", selection: $preferences.displayMode) {
                ForEach(DisplayMode.allCases) { Text($0.rawValue).tag($0) }
            }
            slider("Height", value: $preferences.barHeight, range: 40...80)
            slider("Icon size", value: $preferences.iconScale, range: 24...52)
            slider("Icon padding", value: $preferences.iconPadding, range: 0...14)
            Picker("Menu button", selection: $preferences.menuButtonPlacement) {
                ForEach(MenuButtonPlacement.allCases) { Text($0.rawValue).tag($0) }
            }
            LabeledContent("Start button label") {
                TextField("None", text: $preferences.startButtonLabel).frame(width: 150)
            }
            Toggle("Start button at opposite end", isOn: $preferences.startButtonAtEnd)
            Toggle("Show Finder in running apps", isOn: $preferences.showFinder)
            }

            SettingsSection(title: "System") {
            Toggle("Launch at login", isOn: Binding(
                get: { loginItem.isEnabled },
                set: { enabled in
                    loginItem.setEnabled(enabled)
                    preferences.launchAtLogin = enabled
                }
            ))
            Toggle("Hide system Dock", isOn: Binding(
                get: { dockToggle.isDockHidden },
                set: { $0 ? dockToggle.hideDock() : dockToggle.restoreDock() }
            ))
            }
        }
    }

    private var appearance: some View {
        VStack(spacing: 18) {
            SettingsSection(title: "Appearance") {
                Picker("Theme", selection: $preferences.theme) {
                    ForEach(AppTheme.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Translucency", selection: $preferences.translucency) {
                    ForEach(Translucency.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Active app indicator", selection: $preferences.activeIndicator) {
                    ForEach(ActiveIndicatorStyle.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Highlight style", selection: $preferences.highlightStyle) {
                    ForEach(HighlightStyle.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Show running indicators", isOn: $preferences.showRunningIndicators)
                Toggle("Show app labels under icons", isOn: $preferences.showAppLabels)
            }
            SettingsSection(title: "Background") {
                Toggle("Transparency", isOn: $preferences.transparencyEnabled)
                slider("Panel opacity", value: $preferences.panelOpacity, range: 0.25...1, step: 0.01)
                slider("Blur", value: $preferences.panelBlurRadius, range: 0...30)
                LabeledContent("Panel color") {
                    TextField("Automatic", text: $preferences.panelTintHex).frame(width: 150)
                }
            }
        }
    }

    private var startMenu: some View {
        SettingsSection(title: "Start menu") {
            Picker("Window style", selection: $preferences.menuWindowStyle) {
                ForEach(HighlightStyle.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Height", selection: $preferences.menuHeightMode) {
                ForEach(MenuHeightMode.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Search field", selection: $preferences.searchFieldPosition) {
                ForEach(SearchFieldPosition.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Actions side", selection: $preferences.menuActionsSide) {
                ForEach(MenuActionsSide.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("Show recent items", isOn: $preferences.showRecentInMenu)
            Toggle("Show shortcuts", isOn: $preferences.showShortcutsInMenu)
            Toggle("Group apps by category", isOn: $preferences.groupStartMenuByCategory)
        }
    }

    private var features: some View {
        VStack(spacing: 18) {
            SettingsSection(title: "Features") {
                Toggle("Window Previews", isOn: $preferences.windowPreviewsEnabled)
                Toggle("Show Desktop", isOn: $preferences.showDesktopEnabled)
                Toggle("Global Hotkeys", isOn: $preferences.globalHotkeysEnabled)
            }
            SettingsSection(title: "System Tray") {
                Toggle("Clock", isOn: $preferences.trayClockEnabled)
                Toggle("Battery", isOn: $preferences.trayBatteryEnabled)
                Toggle("Input source", isOn: $preferences.trayInputSourceEnabled)
                Toggle("Volume", isOn: $preferences.trayVolumeEnabled)
                Toggle("Wi-Fi", isOn: $preferences.trayWifiEnabled)
            }
        }
    }

    private var permissionSettings: some View {
        SettingsSection(title: "Permissions") {
            permissionRow(
                "Accessibility",
                granted: permissions.accessibilityTrusted,
                grant: permissions.promptForAccessibility,
                open: permissions.openAccessibilitySettings
            )
            permissionRow(
                "Screen Recording",
                granted: permissions.screenRecordingGranted,
                grant: permissions.requestScreenRecording,
                open: permissions.openScreenRecordingSettings
            )
            LabeledContent("Automation") {
                Button("Open System Settings", action: permissions.openAutomationSettings)
            }
            HStack {
                Spacer()
                Button("Refresh", action: permissions.refresh)
            }
        }
    }

    private var hotkeys: some View {
        SettingsSection(title: "Global Hotkeys") {
            hotkeyRow("Toggle Start Menu", shortcut: "⌘⌥Space")
            hotkeyRow("Show Desktop", shortcut: "⌘⌥D")
            ForEach(1...9, id: \.self) { number in
                hotkeyRow("Launch pinned app \(number)", shortcut: "⌘⌥\(number)")
            }
            Text("Global shortcuts can be enabled or disabled in Features.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var about: some View {
        VStack(spacing: 18) {
            SettingsSection(title: "WinTaskbar") {
                LabeledContent("Version", value: AppMetadata.version)
                LabeledContent("Architecture", value: AppMetadata.architecture)
                Text("A Windows-style taskbar for macOS.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Restore Defaults") { preferences.reset() }
            }
        }
    }

    private func slider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double = 1
    ) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: step)
                Text(value.wrappedValue.formatted(.number.precision(.fractionLength(step < 1 ? 2 : 0))))
                    .frame(width: 38)
            }
        }
    }

    private func permissionRow(
        _ title: String,
        granted: Bool,
        grant: @escaping () -> Void,
        open: @escaping () -> Void
    ) -> some View {
        LabeledContent(title) {
            HStack {
                Label(granted ? "Granted" : "Not granted", systemImage: granted ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(granted ? .green : .secondary)
                Button(granted ? "Open Settings" : "Grant permission", action: granted ? open : grant)
            }
        }
    }

    private func hotkeyRow(_ title: String, shortcut: String) -> some View {
        LabeledContent(title) {
            Text(shortcut).font(.system(.body, design: .monospaced)).padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.primary.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(14)
                .background(Color.primary.opacity(0.055))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}
