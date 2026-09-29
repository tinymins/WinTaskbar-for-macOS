import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NotificationSettingsView: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var apps: AppDiscoveryService
    @ObservedObject var service: SystemNotificationService = .shared
    @ObservedObject private var permissions = PermissionsService.shared
    @State private var editingRule: NotificationCaptureRule?
    @State private var settingsOpenFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("Desktop alerts") {
                Toggle("Capture system notifications", isOn: $preferences.notifications.enabled)
                Text("Rules can trigger several outputs for one notification. Messages and countdowns are kept in memory only and disappear when WinTaskbar quits.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(LocalizedStringKey(service.statusKey))
                    .font(.caption).foregroundStyle(.secondary)
                Button("Clear current alerts") { service.clearAllAlerts() }
            }

            SettingsSection("Trigger rules") {
                Text("Rules are checked from top to bottom. The first enabled match decides which outputs run. Unmatched notifications use the fallback below.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach($preferences.notifications.rules) { $rule in
                    HStack(alignment: .top, spacing: 10) {
                        Toggle("Enabled", isOn: $rule.enabled).labelsHidden()
                        VStack(alignment: .leading, spacing: 4) {
                            Text(rule.appName.isEmpty ? NSLocalizedString("Any app", comment: "Notification rule") : rule.appName)
                                .font(.body.weight(.medium))
                            if !rule.messagePattern.isEmpty {
                                Text(rule.messagePattern).font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                            Text(outputSummary(rule.outputs))
                                .font(.caption).foregroundStyle(.secondary)
                            if let error = rule.patternError {
                                Text(error).font(.caption).foregroundStyle(.red)
                            }
                        }
                        Spacer()
                        Button { moveRule(rule.id, offset: -1) } label: { Image(systemName: "arrow.up") }
                            .disabled(preferences.notifications.rules.first?.id == rule.id).help("Move rule up")
                            .accessibilityLabel("Move rule up")
                        Button { moveRule(rule.id, offset: 1) } label: { Image(systemName: "arrow.down") }
                            .disabled(preferences.notifications.rules.last?.id == rule.id).help("Move rule down")
                            .accessibilityLabel("Move rule down")
                        Button("Edit") { editingRule = rule }
                        Button {
                            preferences.notifications.rules.removeAll { $0.id == rule.id }
                        } label: { Image(systemName: "trash") }
                            .help("Delete rule")
                    }.padding(.vertical, 4)
                }
                Button("Add capture rule") { editingRule = NotificationCaptureRule() }
                Divider()
                Label("Default rule (fallback)", systemImage: "arrow.turn.down.right")
                    .font(.body.weight(.semibold))
                Text("Always applies when no rule matches. This rule stays last and cannot be disabled or deleted.")
                    .font(.caption).foregroundStyle(.secondary)
                NotificationOutputsEditor(outputs: $preferences.notifications.fallback)
                Button("Preview fallback") { service.showPreview() }
            }

            SettingsSection("Display styles") {
                Text("Each rule chooses its outputs and their text, timing, glow, countdown, and sound. These display settings apply to every rule.")
                    .font(.caption).foregroundStyle(.secondary)
                NotificationNumberSetting("Center text size", value: $preferences.notifications.presentation.centerFontSize, range: 12...72, suffix: "pt")
                NotificationNumberSetting("Large text size", value: $preferences.notifications.presentation.largeFontSize, range: 24...160, suffix: "pt")
                Toggle("Show above other windows", isOn: $preferences.notifications.presentation.alwaysOnTop)
                Toggle("Show over fullscreen apps", isOn: $preferences.notifications.presentation.showInFullscreen)
                Divider()
                Text("Preview one output").font(.body.weight(.medium))
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                          alignment: .leading) {
                    ForEach(NotificationOutputKind.allCases, id: \.self) { kind in
                        Button(LocalizedStringKey(kind.label)) { service.showOutputPreview(kind) }
                    }
                }
            }

            SettingsSection("Layout editing") {
                Text("Drag the sample overlays to place them. The important-message frame is visible in layout editing even when its list is empty.")
                    .font(.caption).foregroundStyle(.secondary)
                Button(service.isLayoutEditing ? "Finish layout editing" : "Edit layout") {
                    if service.isLayoutEditing {
                        service.endLayoutEditing()
                    } else {
                        service.beginLayoutEditing()
                    }
                }
                NotificationPositionSettings("Center reminder", x: $preferences.notifications.presentation.centerX,
                                             y: $preferences.notifications.presentation.centerY)
                NotificationPositionSettings("Large text", x: $preferences.notifications.presentation.largeX,
                                             y: $preferences.notifications.presentation.largeY)
                NotificationPositionSettings("Countdown bar", x: $preferences.notifications.presentation.countdownX,
                                             y: $preferences.notifications.presentation.countdownY)
                NotificationPositionSettings("Important message list", x: $preferences.notifications.presentation.importantX,
                                             y: $preferences.notifications.presentation.importantY)
                NotificationNumberSetting("List width", value: $preferences.notifications.presentation.importantWidth,
                                          range: 200...800, suffix: "pt")
                NotificationNumberSetting("List height", value: $preferences.notifications.presentation.importantHeight,
                                          range: 100...900, suffix: "pt")
            }

            SettingsSection("System setup") {
                Label(LocalizedStringKey(permissions.accessibilityTrusted ? "Accessibility access granted" : "Accessibility access required"),
                      systemImage: permissions.accessibilityTrusted ? "checkmark.circle" : "exclamationmark.triangle")
                Button("Open Accessibility settings") { permissions.openAccessibilitySettings() }
                Divider()
                Text("In System Settings > Notifications, set “when mirroring or sharing the display” to “Allow Notifications”. Also enable Desktop notifications for the apps you want to capture.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("This allows notification content to appear in shared screens. Focus modes can still suppress banners; notifications without a visible system banner may not be captured.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open system notification settings") {
                    guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
                    settingsOpenFailed = !NSWorkspace.shared.open(url)
                }
                if settingsOpenFailed {
                    Text("Open System Settings manually and choose Notifications.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { permissions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
        .onDisappear { service.endLayoutEditing() }
        .sheet(item: $editingRule) { rule in
            NotificationRuleEditor(rule: rule, apps: apps, service: service) { updated in
                if let index = preferences.notifications.rules.firstIndex(where: { $0.id == updated.id }) {
                    preferences.notifications.rules[index] = updated
                } else {
                    preferences.notifications.rules.append(updated)
                }
                editingRule = nil
            } onCancel: { editingRule = nil }
        }
    }

    private func moveRule(_ id: UUID, offset: Int) {
        guard let index = preferences.notifications.rules.firstIndex(where: { $0.id == id }),
              preferences.notifications.rules.indices.contains(index + offset) else { return }
        preferences.notifications.rules.swapAt(index, index + offset)
    }

    private func outputSummary(_ outputs: NotificationOutputs) -> String {
        let labels = NotificationOutputKind.allCases
            .filter { outputs.enabled.contains($0) }
            .map { NSLocalizedString($0.label, comment: "Notification output") }
        return labels.isEmpty
            ? NSLocalizedString("Ignore notification", comment: "Notification output")
            : labels.joined(separator: " · ")
    }
}

private struct NotificationRuleEditor: View {
    @State var rule: NotificationCaptureRule
    @ObservedObject var apps: AppDiscoveryService
    @ObservedObject var service: SystemNotificationService
    let onSave: (NotificationCaptureRule) -> Void
    let onCancel: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Capture rule").font(.title2.weight(.semibold))
                HStack {
                    NotificationAppNameField(text: $rule.appName, names: applicationNames)
                        .frame(height: 24)
                    Button("Choose application…", action: chooseApplication)
                }
                Text("Matches the notification's app name, ignoring case. Leave empty to match any app.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Message regular expression", text: $rule.messagePattern).textFieldStyle(.roundedBorder)
                Text("Matches title and body together. Example: meeting|urgent. Use (?i) to ignore case. Leave empty to match any message.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = rule.patternError {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                Divider()
                NotificationOutputsEditor(outputs: $rule.outputs)
                HStack {
                    Button("Preview rule outputs") { service.showPreview(outputs: rule.outputs) }
                    Spacer()
                    Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(rule) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(rule.isEmpty || rule.patternError != nil || rule.outputs.countdownPatternError != nil)
                }
            }
            .padding(24)
        }
        .frame(width: 560)
        .frame(maxHeight: 760)
        .onAppear { apps.reloadInstalledApps() }
    }

    private var applicationNames: [String] {
        Array(Set((apps.installedApps + apps.runningApps).map(\.name)))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString("Choose application…", comment: "Notification rule application picker")
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let bundle = Bundle(url: url)
        rule.appName = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
    }
}

private struct NotificationOutputsEditor: View {
    @Binding var outputs: NotificationOutputs

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Outputs").font(.body.weight(.semibold))
            Text("Select any combination. Selecting none ignores the notification.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(NotificationOutputKind.allCases, id: \.self) { kind in
                Toggle(LocalizedStringKey(kind.label), isOn: enabledBinding(kind))
            }
            if outputs.enabled.contains(.card) {
                Picker("Card lifetime", selection: $outputs.card.mode) {
                    Text("Hide after a delay").tag(NotificationDisplayBehavior.Mode.timed)
                    Text("Keep until dismissed").tag(NotificationDisplayBehavior.Mode.persistent)
                }
                if outputs.card.mode == .timed {
                    HStack {
                        Text("Card display time (seconds)")
                        Spacer()
                        TextField("Seconds", value: $outputs.card.seconds, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 70)
                            .onChange(of: outputs.card.seconds) { value in
                                outputs.card.seconds = min(3600, max(1, value))
                            }
                    }
                }
            }
            if !outputs.enabled.isEmpty {
                TextField("Output text template", text: $outputs.textTemplate)
                    .textFieldStyle(.roundedBorder)
                Text("Leave empty to use the notification text. Use {app}, {title}, {body}, or regex captures such as {1}.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !outputs.enabled.isDisjoint(with: [.centerText, .largeText, .glow])
                || (outputs.enabled.contains(.countdown)
                    && !outputs.completionOutputs.isDisjoint(with: [.centerText, .largeText, .glow])) {
                NotificationNumberSetting("Effect duration", value: $outputs.durationSeconds,
                                          range: 0.5...3600, suffix: "s")
            }
            if !outputs.enabled.isDisjoint(with: [.centerText, .largeText, .glow, .countdown])
                || (outputs.enabled.contains(.countdown)
                    && !outputs.completionOutputs.isDisjoint(with: [.centerText, .largeText, .glow])) {
                ColorPicker("Alert color", selection: Binding(
                    get: { Color(hex: outputs.colorHex) ?? .yellow },
                    set: { value in
                        guard let color = NSColor(value).usingColorSpace(.genericRGB) else { return }
                        outputs.colorHex = String(
                            format: "#%02X%02X%02X",
                            Int((min(1, max(0, color.redComponent)) * 255).rounded()),
                            Int((min(1, max(0, color.greenComponent)) * 255).rounded()),
                            Int((min(1, max(0, color.blueComponent)) * 255).rounded())
                        )
                    }
                ), supportsOpacity: false)
            }
            if outputs.enabled.contains(.countdown) {
                NotificationNumberSetting("Countdown duration", value: $outputs.countdownSeconds,
                                          range: 1...86400, suffix: "s")
                TextField("Countdown regex", text: $outputs.countdownPattern)
                    .textFieldStyle(.roundedBorder)
                Text("Optional regex: capture a number of seconds in group 1. If it does not match, no countdown starts.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = outputs.countdownPatternError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Text("When countdown ends").font(.body.weight(.medium))
                ForEach(NotificationOutputKind.allCases.filter { $0 != .countdown }, id: \.self) { kind in
                    Toggle(LocalizedStringKey(kind.label), isOn: completionBinding(kind))
                }
            }
            if outputs.enabled.contains(.sound)
                || (outputs.enabled.contains(.countdown) && outputs.completionOutputs.contains(.sound)) {
                Picker("Alert sound", selection: $outputs.soundName) {
                    ForEach(["Glass", "Hero", "Morse", "Ping", "Pop", "Submarine", "Tink"], id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                Toggle("Speak the message", isOn: $outputs.speechEnabled)
            }
            if !outputs.enabled.isEmpty {
                NotificationNumberSetting("Repeat cooldown", value: $outputs.cooldownSeconds,
                                          range: 0...300, suffix: "s")
            }
        }
    }

    private func enabledBinding(_ kind: NotificationOutputKind) -> Binding<Bool> {
        Binding(
            get: { outputs.enabled.contains(kind) },
            set: { enabled in
                if enabled { outputs.enabled.insert(kind) } else { outputs.enabled.remove(kind) }
            }
        )
    }

    private func completionBinding(_ kind: NotificationOutputKind) -> Binding<Bool> {
        Binding(
            get: { outputs.completionOutputs.contains(kind) },
            set: { enabled in
                if enabled { outputs.completionOutputs.insert(kind) } else { outputs.completionOutputs.remove(kind) }
            }
        )
    }
}

private extension NotificationOutputs {
    var countdownPatternError: String? {
        guard enabled.contains(.countdown), !countdownPattern.isEmpty else { return nil }
        guard let expression = try? NSRegularExpression(pattern: countdownPattern) else {
            return NSLocalizedString("Invalid countdown regex.", comment: "Notification countdown rule")
        }
        guard expression.numberOfCaptureGroups > 0 else {
            return NSLocalizedString("Countdown regex must capture seconds in group 1.", comment: "Notification countdown rule")
        }
        return nil
    }
}

private struct NotificationPositionSettings: View {
    let title: LocalizedStringKey
    @Binding var x: Double
    @Binding var y: Double

    init(_ title: LocalizedStringKey, x: Binding<Double>, y: Binding<Double>) {
        self.title = title
        _x = x
        _y = y
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.body.weight(.medium))
            NotificationNumberSetting("Horizontal position", value: $x, range: 0...1, suffix: "%", scale: 100)
            NotificationNumberSetting("Vertical position", value: $y, range: 0...1, suffix: "%", scale: 100)
        }
    }
}

private struct NotificationNumberSetting: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let suffix: String
    var scale: Double = 1

    init(_ title: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>,
         suffix: String, scale: Double = 1) {
        self.title = title
        _value = value
        self.range = range
        self.suffix = suffix
        self.scale = scale
    }

    var body: some View {
        HStack {
            Text(title).frame(width: 180, alignment: .leading)
            Slider(value: $value, in: range)
            if scale == 1 {
                TextField("Value", value: $value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 68)
                    .onChange(of: value) { newValue in
                        value = newValue.isFinite ? min(range.upperBound, max(range.lowerBound, newValue)) : range.lowerBound
                    }
            }
            Text("\(Int((value * scale).rounded()))\(suffix)")
                .monospacedDigit().frame(width: 58, alignment: .trailing)
        }
    }
}
