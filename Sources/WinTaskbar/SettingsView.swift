import AppKit
import Carbon
import SwiftUI
import UniformTypeIdentifiers

enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General"
    case appearance = "Appearance"
    case startMenu = "Start Menu"
    case taskbar = "Taskbar & Tray"
    case hotkeys = "Hotkeys"
    case shortcutMappings = "Shortcut Mappings"
    case about = "About"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .startMenu: "square.grid.2x2"
        case .taskbar: "dock.rectangle"
        case .hotkeys: "keyboard"
        case .shortcutMappings: "command"
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject private var dockToggle = DockToggleService.shared
    @ObservedObject private var loginItem = LoginItemService.shared
    @ObservedObject private var globalHotkeys = GlobalHotkeysService.shared
    @State private var selectedPage = SettingsPage.general

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsPage.allCases, selection: $selectedPage) { page in
                Label(page.rawValue, systemImage: page.symbol)
                    .tag(page)
            }
            .listStyle(.sidebar)
            .frame(width: 190)

            Divider()

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: selectedPage.symbol)
                        .foregroundStyle(.secondary)
                    Text(selectedPage.rawValue)
                        .font(.title2.weight(.semibold))
                    Spacer()
                }
                .padding(.horizontal, 22)
                .frame(height: 58)
                Divider()
                selectedPageContent
            }
        }
        .onAppear {
            loginItem.refresh()
        }
    }

    @ViewBuilder
    private var selectedPageContent: some View {
        switch selectedPage {
        case .general: settingsPage(general)
        case .appearance: settingsPage(appearance)
        case .startMenu: settingsPage(startMenu)
        case .taskbar: settingsPage(features)
        case .hotkeys: settingsPage(hotkeySettings)
        case .shortcutMappings: settingsPage(shortcutMappings)
        case .about: settingsPage(about)
        }
    }

    private func settingsPage<Content: View>(_ content: Content) -> some View {
        ScrollView {
            content
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var general: some View {
        SettingsSection("Taskbar") {
            Picker("Position", selection: $preferences.position) {
                ForEach(TaskbarPosition.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Show on", selection: $preferences.displayMode) {
                ForEach(DisplayMode.allCases) { Text($0.rawValue).tag($0) }
            }
            Slider(
                value: $preferences.barHeight,
                in: 40...72,
                step: 1,
                label: { Text("Height") },
                minimumValueLabel: { Text("40").foregroundStyle(.secondary) },
                maximumValueLabel: { Text("72").foregroundStyle(.secondary) }
            )
            Slider(
                value: $preferences.iconScale,
                in: 0.6...1.2,
                label: { Text("Icon size") },
                minimumValueLabel: { Image(systemName: "smallcircle.filled.circle") },
                maximumValueLabel: { Image(systemName: "largecircle.fill.circle") }
            )
            Slider(
                value: $preferences.iconPadding,
                in: 0...0.2,
                label: { Text("Icon padding") },
                minimumValueLabel: { Image(systemName: "square.fill") },
                maximumValueLabel: { Image(systemName: "square.dashed") }
            )
            Picker("Menu button", selection: $preferences.menuButtonPlacement) {
                ForEach(MenuButtonPlacement.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Start button label", selection: $preferences.startButtonLabel) {
                ForEach(["", "Start", "Menu"], id: \.self) { value in
                    Text(value.isEmpty ? "None" : value).tag(value)
                }
            }
            Toggle("Show Finder in running apps", isOn: $preferences.showFinder)
            Toggle("Launch at login", isOn: Binding(
                get: { loginItem.isEnabled },
                set: { enabled in
                    loginItem.setEnabled(enabled)
                    preferences.launchAtLogin = enabled
                }
            ))
        }
    }

    private var appearance: some View {
        SettingsSection("Visual style") {
            Picker("Theme", selection: $preferences.theme) {
                ForEach(AppTheme.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("Show running indicators", isOn: $preferences.showRunningIndicators)
            Picker("Active app indicator", selection: $preferences.activeIndicator) {
                ForEach(ActiveIndicatorStyle.allCases) { Text($0.rawValue).tag($0) }
            }
            .disabled(!preferences.showRunningIndicators)
            Picker("Highlight style", selection: $preferences.highlightStyle) {
                ForEach(HighlightStyle.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("Show app labels under icons", isOn: $preferences.showAppLabels)
            Toggle("Transparency", isOn: $preferences.transparencyEnabled)
            if preferences.transparencyEnabled {
                Slider(value: $preferences.panelOpacity, in: 0.25...1, step: 0.01) {
                    Text("Panel opacity")
                }
                Slider(value: $preferences.panelBlurRadius, in: 0...30, step: 1) {
                    Text("Blur")
                }
            }
            panelColor
        }
    }

    private var panelColor: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Panel color")
                Spacer()
                Button(preferences.panelTintHex.isEmpty ? "Automatic" : preferences.panelTintHex.uppercased()) {
                    preferences.panelTintHex = ""
                }
                .buttonStyle(.borderless)
                .disabled(preferences.panelTintHex.isEmpty)
            }
            PanelTintPicker(hex: $preferences.panelTintHex)
            HStack(spacing: 9) {
                tintSwatch(hex: "", isNone: true)
                ForEach(["#1F2937", "#334155", "#3B82F6", "#7C3AED", "#BE123C", "#15803D"], id: \.self) {
                    tintSwatch(hex: $0, isNone: false)
                }
            }
        }
        .padding(.top, 2)
    }

    private func tintSwatch(hex: String, isNone: Bool) -> some View {
        Button {
            preferences.panelTintHex = hex
        } label: {
            ZStack {
                Circle().fill(isNone ? Color.clear : Color(hex: hex) ?? .clear)
                if isNone {
                    Circle().stroke(Color.secondary, lineWidth: 1)
                    Rectangle().fill(Color.red).frame(width: 2, height: 20).rotationEffect(.degrees(45))
                }
                if preferences.panelTintHex.caseInsensitiveCompare(hex) == .orderedSame {
                    Circle().stroke(Color.accentColor, lineWidth: 2).padding(-3)
                }
            }
            .frame(width: 21, height: 21)
        }
        .buttonStyle(.plain)
        .help(isNone ? "Clear color" : hex)
    }

    private var startMenu: some View {
        SettingsSection("Behavior") {
            Picker("Windows style", selection: $preferences.menuWindowStyle) {
                ForEach(HighlightStyle.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Window height", selection: $preferences.menuHeightMode) {
                ForEach(MenuHeightMode.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Search field", selection: $preferences.searchFieldPosition) {
                ForEach(SearchFieldPosition.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Actions panel", selection: $preferences.menuActionsSide) {
                ForEach(MenuActionsSide.allCases) { Text($0.rawValue).tag($0) }
            }
        }
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("Features") {
                Toggle("Window Previews", isOn: $preferences.windowPreviewsEnabled)
                Toggle("Show Desktop", isOn: $preferences.showDesktopEnabled)
            }
            SettingsSection("Taskbar menu") {
                Toggle("Recent items", isOn: $preferences.showRecentInMenu)
                Toggle("Shortcuts", isOn: $preferences.showShortcutsInMenu)
            }
            SettingsSection("System Tray") {
                Toggle("Clock", isOn: $preferences.trayClockEnabled)
                Toggle("Battery", isOn: $preferences.trayBatteryEnabled)
                Toggle("Input source", isOn: $preferences.trayInputSourceEnabled)
                Toggle("Volume", isOn: $preferences.trayVolumeEnabled)
                Toggle("Wi-Fi", isOn: $preferences.trayWifiEnabled)
            }
        }
    }

    private var hotkeySettings: some View {
        SettingsSection("Windows Global Shortcuts") {
            Toggle("Enable global shortcuts", isOn: $preferences.globalHotkeysEnabled)
            Picker("Windows key", selection: $preferences.windowsKeyMapping) {
                ForEach(WindowsKeyMapping.allCases) { mapping in
                    Text(mapping.rawValue).tag(mapping)
                }
            }
            Toggle("Press Windows key alone to open Start", isOn: $preferences.windowsKeyOpensStart)
                .disabled(!preferences.globalHotkeysEnabled)
            if let issue = globalHotkeys.windowsKeyIssue,
               preferences.globalHotkeysEnabled,
               preferences.windowsKeyOpensStart {
                Text(issue)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text("Option preserves the existing WinTaskbar behavior. Command matches the Windows-logo key on most PC keyboards connected to a Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Enabled mappings override matching macOS and application shortcuts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var shortcutMappings: some View {
        SettingsSection("Shortcut mappings") {
            ForEach(Array(preferences.globalShortcutConfigurations.enumerated()), id: \.element.id) { index, configuration in
                GlobalShortcutRow(
                    configuration: configurationBinding(id: configuration.id),
                    windowsKeyMapping: preferences.windowsKeyMapping,
                    globalEnabled: preferences.globalHotkeysEnabled,
                    registrationIssue: globalHotkeys.registrationIssues[configuration.id],
                    onChooseApplication: { chooseApplication(for: configuration.id) },
                    onResetTrigger: { resetTrigger(for: configuration.id) }
                )
                if index < preferences.globalShortcutConfigurations.count - 1 {
                    Divider()
                }
            }
        }
    }

    private var about: some View {
        SettingsSection("Application") {
            LabeledContent("Version", value: AppMetadata.version)
            Button("Check for Updates") {
                if let url = URL(string: "https://github.com/tinymins/WinTaskbar-for-macOS/releases") {
                    NSWorkspace.shared.open(url)
                }
            }
            HStack {
                Button(dockToggle.isDockHidden ? "Restore system Dock" : "Hide system Dock") {
                    dockToggle.isDockHidden ? dockToggle.restoreDock() : dockToggle.hideDock()
                }
                Button("Exit", role: .destructive) {
                    confirmExit()
                }
            }
        }
    }

    private func confirmExit() {
        let alert = NSAlert()
        alert.messageText = "Exit WinTaskbar?"
        alert.informativeText = "WinTaskbar will exit and restore the system Dock."
        alert.alertStyle = .warning

        let exitButton = alert.addButton(withTitle: "Exit")
        exitButton.hasDestructiveAction = true
        let cancelButton = alert.addButton(withTitle: "Cancel")
        cancelButton.keyEquivalent = "\u{1b}"

        alert.window.level = .modalPanel
        if let screen = NSApp.keyWindow?.screen ?? NSScreen.main {
            let alertSize = alert.window.frame.size
            alert.window.setFrameOrigin(NSPoint(
                x: screen.visibleFrame.midX - alertSize.width / 2,
                y: screen.visibleFrame.midY - alertSize.height / 2
            ))
        }

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
    }

    private func configurationBinding(id: String) -> Binding<GlobalShortcutConfiguration> {
        Binding(
            get: {
                preferences.globalShortcutConfigurations.first { $0.id == id }
                    ?? GlobalShortcutCatalog.defaults(
                        legacyShortcuts: GlobalShortcutCatalog.defaultLegacyShortcuts
                    )[0]
            },
            set: { updated in
                guard let index = preferences.globalShortcutConfigurations.firstIndex(where: { $0.id == id }) else { return }
                preferences.globalShortcutConfigurations[index] = updated
            }
        )
    }

    private func chooseApplication(for id: String) {
        let panel = NSOpenPanel()
        panel.title = "Choose Application"
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK,
              let url = panel.url,
              let target = ShortcutApplicationTarget(url: url),
              let index = preferences.globalShortcutConfigurations.firstIndex(where: { $0.id == id }) else { return }
        preferences.globalShortcutConfigurations[index].applicationTarget = target
    }

    private func resetTrigger(for id: String) {
        guard let index = preferences.globalShortcutConfigurations.firstIndex(where: { $0.id == id }),
              let defaultConfiguration = GlobalShortcutCatalog.defaultConfiguration(
                id: id,
                legacyShortcuts: GlobalShortcutCatalog.defaultLegacyShortcuts
              ) else { return }
        preferences.globalShortcutConfigurations[index].shortcut = defaultConfiguration.shortcut
        preferences.globalShortcutConfigurations[index].usesWindowsKey = defaultConfiguration.usesWindowsKey
    }
}

private struct SettingsSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).padding(.horizontal, 10)
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

private struct GlobalShortcutRow: View {
    @Binding var configuration: GlobalShortcutConfiguration
    let windowsKeyMapping: WindowsKeyMapping
    let globalEnabled: Bool
    let registrationIssue: String?
    let onChooseApplication: () -> Void
    let onResetTrigger: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Toggle("", isOn: $configuration.isEnabled)
                    .labelsHidden()
                VStack(alignment: .leading, spacing: 2) {
                    Text(configuration.title)
                    Text(configuration.windowsShortcutLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                GlobalHotkeyRecorder(
                    configuration: $configuration,
                    windowsKeyMapping: windowsKeyMapping,
                    onResetTrigger: onResetTrigger
                )
            }

            HStack(spacing: 8) {
                Picker("Action", selection: actionBinding) {
                    ForEach(GlobalShortcutAction.allCases) { action in
                        Text(action.title).tag(action)
                    }
                }
                if configuration.action == .launchPinned {
                    Picker("Pinned app", selection: pinnedIndexBinding) {
                        ForEach(0..<9, id: \.self) { index in
                            Text("#\(index + 1)").tag(index)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 64)
                }
                if configuration.action.supportsApplicationTarget {
                    Button(applicationTargetTitle, action: onChooseApplication)
                        .contextMenu {
                            if configuration.applicationTarget != nil {
                                Button(configuration.action.defaultApplicationName == nil ? "Clear Application" : "Use Default") {
                                    configuration.applicationTarget = nil
                                }
                            }
                        }
                }
                Spacer()
                if let effectiveIssue, globalEnabled, configuration.isEnabled {
                    Text(effectiveIssue)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.leading, 30)
        }
        .opacity(globalEnabled ? 1 : 0.65)
    }

    private var actionBinding: Binding<GlobalShortcutAction> {
        Binding(
            get: { configuration.action },
            set: { action in
                configuration.action = action
                configuration.applicationTarget = nil
                if action == .launchPinned, configuration.pinnedIndex == nil {
                    configuration.pinnedIndex = 0
                }
            }
        )
    }

    private var pinnedIndexBinding: Binding<Int> {
        Binding(
            get: { configuration.pinnedIndex ?? 0 },
            set: { configuration.pinnedIndex = $0 }
        )
    }

    private var effectiveIssue: String? {
        if configuration.action == .openApplication, configuration.applicationTarget == nil {
            return "Choose an application"
        }
        if let target = configuration.applicationTarget, target.resolvedURL == nil {
            return "Application not found"
        }
        return registrationIssue
    }

    private var applicationTargetTitle: String {
        configuration.applicationTarget?.name
            ?? configuration.action.defaultApplicationName
            ?? "Choose Application…"
    }
}

private struct GlobalHotkeyRecorder: View {
    @Binding var configuration: GlobalShortcutConfiguration
    let windowsKeyMapping: WindowsKeyMapping
    let onResetTrigger: () -> Void
    @State private var isRecording = false

    var body: some View {
        Button(isRecording ? "Type shortcut" : configuration.displayValue(mapping: windowsKeyMapping)) {
            isRecording = true
        }
        .font(.system(.body, design: .monospaced))
        .contextMenu {
            Button("Restore default shortcut", action: onResetTrigger)
        }
        .background(ShortcutCaptureView(isRecording: isRecording) { captured in
            if let captured {
                configuration.shortcut = captured
                configuration.usesWindowsKey = false
            }
            isRecording = false
        })
    }
}

private struct ShortcutCaptureView: NSViewRepresentable {
    let isRecording: Bool
    let onCapture: (HotkeyShortcut?) -> Void

    func makeNSView(context: Context) -> ShortcutCaptureNSView {
        let view = ShortcutCaptureNSView()
        view.onCapture = onCapture
        return view
    }

    func updateNSView(_ nsView: ShortcutCaptureNSView, context: Context) {
        nsView.onCapture = onCapture
        guard isRecording else { return }
        DispatchQueue.main.async { nsView.window?.makeFirstResponder(nsView) }
    }
}

private final class ShortcutCaptureNSView: NSView {
    var onCapture: ((HotkeyShortcut?) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCapture?(nil)
            return
        }
        let modifiers = Self.carbonModifiers(event.modifierFlags)
        guard modifiers != 0 else { NSSound.beep(); return }
        let label = Self.keyLabel(for: event)
        onCapture?(HotkeyShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyLabel: label))
    }

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }

    private static func keyLabel(for event: NSEvent) -> String {
        switch event.keyCode {
        case 36: return "↩"
        case 48: return "⇥"
        case 49: return "Space"
        case 51: return "⌫"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return event.charactersIgnoringModifiers?.uppercased() ?? "?"
        }
    }
}

private struct PanelTintPicker: View {
    @Binding var hex: String

    private var components: HSB {
        HSB(hex: hex) ?? HSB(hue: 0.58, saturation: 0.55, brightness: 0.65)
    }

    var body: some View {
        VStack(spacing: 7) {
            GradientSlider(value: binding(\.hue), gradient: Self.hueGradient)
            GradientSlider(
                value: binding(\.saturation),
                gradient: Gradient(colors: [.white, color(hue: components.hue, saturation: 1, brightness: components.brightness)])
            )
            GradientSlider(
                value: binding(\.brightness),
                gradient: Gradient(colors: [.black, color(hue: components.hue, saturation: components.saturation, brightness: 1)])
            )
        }
    }

    private func binding(_ keyPath: WritableKeyPath<HSB, Double>) -> Binding<Double> {
        Binding(
            get: { components[keyPath: keyPath] },
            set: { value in
                var updated = components
                updated[keyPath: keyPath] = value
                hex = updated.hex
            }
        )
    }

    private func color(hue: Double, saturation: Double, brightness: Double) -> Color {
        Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    private static let hueGradient = Gradient(colors: stride(from: 0.0, through: 1.0, by: 0.1).map {
        Color(hue: $0, saturation: 1, brightness: 1)
    })
}

private struct GradientSlider: View {
    @Binding var value: Double
    let gradient: Gradient

    var body: some View {
        GeometryReader { geometry in
            let knob: CGFloat = 12
            ZStack(alignment: .leading) {
                LinearGradient(gradient: gradient, startPoint: .leading, endPoint: .trailing)
                    .frame(height: 7)
                    .clipShape(Capsule())
                Circle()
                    .fill(.white)
                    .overlay(Circle().stroke(.black.opacity(0.35), lineWidth: 1))
                    .shadow(radius: 1)
                    .frame(width: knob, height: knob)
                    .offset(x: max(0, min(geometry.size.width - knob, value * (geometry.size.width - knob))))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                value = max(0, min(1, drag.location.x / max(1, geometry.size.width)))
            })
        }
        .frame(height: 14)
    }
}

private struct HSB {
    var hue: Double
    var saturation: Double
    var brightness: Double

    init(hue: Double, saturation: Double, brightness: Double) {
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
    }

    init?(hex: String) {
        guard let color = NSColor(hex: hex)?.usingColorSpace(.deviceRGB) else { return nil }
        hue = color.hueComponent
        saturation = color.saturationComponent
        brightness = color.brightnessComponent
    }

    var hex: String {
        let color = NSColor(calibratedHue: hue, saturation: saturation, brightness: brightness, alpha: 1)
        return String(
            format: "#%02X%02X%02X",
            Int(color.redComponent * 255),
            Int(color.greenComponent * 255),
            Int(color.blueComponent * 255)
        )
    }
}

extension NSColor {
    convenience init?(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6, let rgb = Int(value, radix: 16) else { return nil }
        self.init(
            calibratedRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Color {
    init?(hex: String) {
        guard let color = NSColor(hex: hex) else { return nil }
        self.init(nsColor: color)
    }
}
