import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NotificationSettingsView: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var apps: AppDiscoveryService
    @ObservedObject var service: SystemNotificationService = .shared
    @ObservedObject private var permissions = PermissionsService.shared
    @State private var editingRule: NotificationCaptureRule?
    @State private var editingFallback = false
    @State private var expandedOutput: NotificationOutputKind?
    @State private var settingsOpenFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("Desktop alerts") {
                Toggle("Enable desktop alerts", isOn: $preferences.notifications.enabled)
                    .toggleStyle(.switch)
                Text("Turning this off stops receiving, clears current alerts, and disables all settings below. Your configuration is kept.")
                    .font(.caption).foregroundStyle(.secondary)
                if preferences.notifications.enabled {
                    Text(LocalizedStringKey(service.statusKey))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Notification receiving is off.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let systemBannerStatusKey = service.systemBannerStatusKey {
                    Text(LocalizedStringKey(systemBannerStatusKey))
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("Current alerts are kept in memory and disappear when WinTaskbar quits.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Clear current alerts") { service.clearAllAlerts() }
                    .disabled(!preferences.notifications.enabled)
            }

            Group {
                SettingsSection("Trigger rules") {
                    Text("Rules are checked from top to bottom. The first enabled match chooses the output combination. Unmatched notifications use the fallback.")
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
                                Text(outputSummary(rule.outputs)).font(.caption).foregroundStyle(.secondary)
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
                    Text(outputSummary(preferences.notifications.fallback))
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Always applies when no rule matches. It stays last and cannot be disabled or deleted.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Edit fallback") { editingFallback = true }
                        Button("Preview fallback") { service.showPreview() }
                    }
                    Text("Preview shows only WinTaskbar output and never closes a real system notification.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                SettingsSection("Shared output settings") {
                    Text("Rules use these settings unless Customize for this rule is checked. Changes apply to every rule that inherits the output, including the fallback.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(NotificationOutputKind.allCases) { kind in
                        DisclosureGroup(isExpanded: expansionBinding(kind)) {
                            VStack(alignment: .leading, spacing: 14) {
                                NotificationChannelSettingsEditor(
                                    kind: kind, settings: defaultSettingsBinding(kind)
                                )
                                outputPlacement(kind)
                                Button("Preview this output") { service.showOutputPreview(kind) }
                            }
                            .padding(.top, 10)
                            .padding(.leading, 18)
                            .padding(.bottom, 6)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(kind.label).font(.body.weight(.medium))
                                Text((preferences.notifications.outputDefaults[kind] ?? NotificationOutputSettings())
                                    .summary(for: kind))
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .disclosureGroupStyle(NotificationOutputDisclosureStyle())
                        if kind != NotificationOutputKind.allCases.last { Divider() }
                    }
                    Text("Preview shows only WinTaskbar output and never closes a real system notification.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                SettingsSection("Window behavior and layout") {
                    Toggle("Show above other windows", isOn: $preferences.notifications.presentation.alwaysOnTop)
                    Toggle("Show over fullscreen apps", isOn: $preferences.notifications.presentation.showInFullscreen)
                    Divider()
                    Text("Drag the sample overlays to place them. The important-message frame appears here even when its list is empty.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(service.isLayoutEditing ? "Finish layout editing" : "Edit layout") {
                        if service.isLayoutEditing {
                            service.endLayoutEditing()
                        } else {
                            service.beginLayoutEditing()
                        }
                    }
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
            .disabled(!preferences.notifications.enabled)
            .opacity(preferences.notifications.enabled ? 1 : 0.5)
        }
        .onAppear { permissions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
        .onDisappear { service.endLayoutEditing() }
        .onChange(of: preferences.notifications.enabled) { enabled in
            if !enabled {
                editingRule = nil
                editingFallback = false
            }
        }
        .sheet(item: $editingRule) { rule in
            NotificationRuleEditor(rule: rule, defaults: preferences.notifications.outputDefaults,
                                   apps: apps, service: service) { updated in
                if let index = preferences.notifications.rules.firstIndex(where: { $0.id == updated.id }) {
                    preferences.notifications.rules[index] = updated
                } else {
                    preferences.notifications.rules.append(updated)
                }
                editingRule = nil
            } onCancel: { editingRule = nil }
        }
        .sheet(isPresented: $editingFallback) {
            NotificationFallbackEditor(outputs: preferences.notifications.fallback,
                                       defaults: preferences.notifications.outputDefaults,
                                       service: service) { updated in
                preferences.notifications.fallback = updated
                editingFallback = false
            } onCancel: { editingFallback = false }
        }
    }

    @ViewBuilder
    private func outputPlacement(_ kind: NotificationOutputKind) -> some View {
        switch kind {
        case .centerText:
            NotificationPositionSettings("Center reminder", x: $preferences.notifications.presentation.centerX,
                                         y: $preferences.notifications.presentation.centerY)
            NotificationNumberSetting("Maximum width", value: $preferences.notifications.presentation.centerMaximumWidth,
                                      range: 240...max(240, NSScreen.screens.first?.visibleFrame.width ?? 1600), suffix: "pt")
            Text("Drag either edge in Edit layout to set the maximum width. Short messages shrink automatically.")
                .font(.caption).foregroundStyle(.secondary)
            NotificationNumberSetting("Center text size", value: $preferences.notifications.presentation.centerFontSize,
                                      range: 12...72, suffix: "pt")
        case .largeText:
            NotificationPositionSettings("Large text", x: $preferences.notifications.presentation.largeX,
                                         y: $preferences.notifications.presentation.largeY)
            NotificationNumberSetting("Maximum width", value: $preferences.notifications.presentation.largeMaximumWidth,
                                      range: 320...max(320, NSScreen.screens.first?.visibleFrame.width ?? 1600), suffix: "pt")
            Text("Drag either edge in Edit layout to set the maximum width. Short messages shrink automatically.")
                .font(.caption).foregroundStyle(.secondary)
            NotificationNumberSetting("Large text size", value: $preferences.notifications.presentation.largeFontSize,
                                      range: 24...160, suffix: "pt")
        case .countdown:
            NotificationPositionSettings("Countdown bar", x: $preferences.notifications.presentation.countdownX,
                                         y: $preferences.notifications.presentation.countdownY)
        case .important:
            NotificationPositionSettings("Important message list", x: $preferences.notifications.presentation.importantX,
                                         y: $preferences.notifications.presentation.importantY)
            NotificationNumberSetting("List width", value: $preferences.notifications.presentation.importantWidth,
                                      range: 200...800, suffix: "pt")
            NotificationNumberSetting("Default list height", value: $preferences.notifications.presentation.importantHeight,
                                      range: 100...900, suffix: "pt")
            Text("Height rounds up to a complete message from this default each time. Fewer messages shrink the list; an empty list hides its frame.")
                .font(.caption).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    private func expansionBinding(_ kind: NotificationOutputKind) -> Binding<Bool> {
        Binding(
            get: { expandedOutput == kind },
            set: { expandedOutput = $0 ? kind : nil }
        )
    }

    private func defaultSettingsBinding(_ kind: NotificationOutputKind) -> Binding<NotificationOutputSettings> {
        Binding(
            get: { preferences.notifications.outputDefaults[kind] ?? NotificationOutputSettings() },
            set: { preferences.notifications.outputDefaults[kind] = $0 }
        )
    }

    private func moveRule(_ id: UUID, offset: Int) {
        guard let index = preferences.notifications.rules.firstIndex(where: { $0.id == id }),
              preferences.notifications.rules.indices.contains(index + offset) else { return }
        preferences.notifications.rules.swapAt(index, index + offset)
    }

    private func outputSummary(_ outputs: NotificationOutputs) -> String {
        var labels = NotificationOutputKind.allCases.filter { outputs.enabled.contains($0) }.map(\.label)
        if outputs.dismissSystemNotification {
            labels.append(NSLocalizedString("Hide original macOS banner", comment: "Notification rule summary"))
        }
        return labels.isEmpty
            ? NSLocalizedString("Ignore notification", comment: "Notification output")
            : labels.joined(separator: " · ")
    }
}

private struct NotificationOutputDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .frame(width: 12)
                        .foregroundStyle(.secondary)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(NotificationOutputHeaderButtonStyle())
            .accessibilityValue(Text(configuration.isExpanded ? "Expanded" : "Collapsed"))
            if configuration.isExpanded { configuration.content }
        }
    }
}

private struct NotificationOutputHeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Feedback(configuration: configuration)
    }

    private struct Feedback: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .background(Color.primary.opacity(isEnabled ? (configuration.isPressed ? 0.12 : hovered ? 0.06 : 0) : 0),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .onHover { hovered = $0 }
        }
    }
}

private struct NotificationRuleEditor: View {
    @State var rule: NotificationCaptureRule
    let defaults: [NotificationOutputKind: NotificationOutputSettings]
    @ObservedObject var apps: AppDiscoveryService
    @ObservedObject var service: SystemNotificationService
    let onSave: (NotificationCaptureRule) -> Void
    let onCancel: () -> Void

    var body: some View {
        NotificationEditorSheet {
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
                NotificationOutputsEditor(outputs: $rule.outputs, defaults: defaults)
            }
        } actions: {
                HStack {
                    Button("Preview rule outputs") { service.showPreview(outputs: rule.outputs) }
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(rule) }
                    .keyboardShortcut(.defaultAction)
                        .disabled(rule.isEmpty || rule.patternError != nil || rule.outputs.countdownPatternError(defaults: defaults) != nil)
                }
                Text("Preview shows only WinTaskbar output and never closes a real system notification.")
                    .font(.caption).foregroundStyle(.secondary)
        }
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

private struct NotificationFallbackEditor: View {
    @State var outputs: NotificationOutputs
    let defaults: [NotificationOutputKind: NotificationOutputSettings]
    @ObservedObject var service: SystemNotificationService
    let onSave: (NotificationOutputs) -> Void
    let onCancel: () -> Void

    var body: some View {
        NotificationEditorSheet {
            VStack(alignment: .leading, spacing: 16) {
                Text("Default rule (fallback)").font(.title2.weight(.semibold))
                Text("This rule applies whenever no enabled rule matches.")
                    .font(.caption).foregroundStyle(.secondary)
                NotificationOutputsEditor(outputs: $outputs, defaults: defaults)
            }
        } actions: {
                HStack {
                    Button("Preview fallback") { service.showPreview(outputs: outputs) }
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(outputs) }
                    .keyboardShortcut(.defaultAction)
                        .disabled(outputs.countdownPatternError(defaults: defaults) != nil)
                }
                Text("Preview shows only WinTaskbar output and never closes a real system notification.")
                    .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct NotificationEditorSheet<Content: View, Actions: View>: View {
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions
    @State private var contentHeight: CGFloat = 440

    private var maximumContentHeight: CGFloat {
        min(620, max(180, (NSScreen.main?.visibleFrame.height ?? 800) - 180))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: NotificationEditorHeight.self, value: geometry.size.height)
                    })
            }
            .frame(height: min(contentHeight, maximumContentHeight))
            Divider()
            actions
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
        .frame(width: 560)
        .onPreferenceChange(NotificationEditorHeight.self) { contentHeight = $0 }
    }
}

private struct NotificationEditorHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct NotificationOutputsEditor: View {
    @Binding var outputs: NotificationOutputs
    let defaults: [NotificationOutputKind: NotificationOutputSettings]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Output combination").font(.body.weight(.semibold))
            Text("Each checkbox controls a WinTaskbar output for this rule.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(NotificationOutputKind.allCases, id: \.self) { kind in
                NotificationRuleOutputEditor(kind: kind, outputs: $outputs, defaults: defaults)
            }
            if outputs.enabled.contains(.countdown) {
                let completion = outputs.overrides[.countdown]?.completionOutputs
                    ?? defaults[.countdown]?.completionOutputs
                    ?? NotificationOutputSettings().completionOutputs
                ForEach(NotificationOutputKind.allCases.filter {
                    completion.contains($0) && $0 != .countdown && !outputs.enabled.contains($0)
                },
                        id: \.self) { kind in
                    NotificationRuleOutputEditor(kind: kind, outputs: $outputs, defaults: defaults,
                                                 afterCountdown: true)
                }
            }
            Divider()
            Toggle(isOn: $outputs.dismissSystemNotification) {
                HStack(spacing: 6) {
                    Text("Hide original macOS banner (keep in Notification Center)")
                    if outputs.warnsAboutHiddenNotification(defaults: defaults) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .accessibilityLabel(Text("Warning: notifications may be missed"))
                    }
                }
            }
            if outputs.warnsAboutHiddenNotification(defaults: defaults) {
                Label("No bottom-right card will be shown, but the macOS banner will be hidden. The notification remains in Notification Center, but you may miss its arrival.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)
            }
            Text("Hide only the banner; keep the notification in Notification Center. Shared windows are hidden only when all their notifications allow it. Unsupported banners remain visible.")
                .font(.caption).foregroundStyle(.secondary)
            if !outputs.enabled.isEmpty {
                NotificationNumberSetting("Repeat cooldown", value: $outputs.cooldownSeconds,
                                          range: 0...300, suffix: "s")
            }
        }
    }
}

private struct NotificationRuleOutputEditor: View {
    let kind: NotificationOutputKind
    @Binding var outputs: NotificationOutputs
    let defaults: [NotificationOutputKind: NotificationOutputSettings]
    var afterCountdown = false

    private var isActive: Bool { afterCountdown || outputs.enabled.contains(kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                if afterCountdown {
                    Text(String(format: NSLocalizedString("%@ after countdown", comment: "Notification output"),
                                kind.label))
                        .font(.body.weight(.medium))
                } else {
                    Toggle(kind.label, isOn: enabledBinding)
                }
                Spacer(minLength: 12)
                if isActive {
                    Toggle("Customize for this rule", isOn: overrideBinding)
                        .font(.caption)
                }
            }
            if isActive {
                if outputs.overrides[kind] != nil {
                    NotificationChannelSettingsEditor(kind: kind, settings: settingsBinding)
                        .padding(.leading, 18)
                } else {
                    Text(String(format: NSLocalizedString("Uses shared output settings: %@", comment: "Notification rule inheritance"),
                                settingsBinding.wrappedValue.summary(for: kind)))
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 18)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { outputs.enabled.contains(kind) },
            set: { enabled in
                if enabled { outputs.enabled.insert(kind) } else { outputs.enabled.remove(kind) }
            }
        )
    }

    private var overrideBinding: Binding<Bool> {
        Binding(
            get: { outputs.overrides[kind] != nil },
            set: { custom in
                if custom {
                    outputs.overrides[kind] = defaults[kind] ?? NotificationOutputSettings()
                } else {
                    outputs.overrides.removeValue(forKey: kind)
                }
            }
        )
    }

    private var settingsBinding: Binding<NotificationOutputSettings> {
        Binding(
            get: { outputs.overrides[kind] ?? defaults[kind] ?? NotificationOutputSettings() },
            set: { outputs.overrides[kind] = $0 }
        )
    }
}

private struct NotificationChannelSettingsEditor: View {
    let kind: NotificationOutputKind
    @Binding var settings: NotificationOutputSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if kind == .card {
                Picker("Card lifetime", selection: $settings.card.mode) {
                    Text("Hide after a delay").tag(NotificationDisplayBehavior.Mode.timed)
                    Text("Keep until dismissed").tag(NotificationDisplayBehavior.Mode.persistent)
                }
                if settings.card.mode == .timed {
                    HStack {
                        Text("Card display time (seconds)")
                        Spacer()
                        TextField("Seconds", value: $settings.card.seconds, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 70)
                            .onChange(of: settings.card.seconds) { value in
                                settings.card.seconds = min(3600, max(1, value))
                            }
                    }
                }
            }
            if [.card, .centerText, .largeText, .countdown, .sound, .important].contains(kind) {
                TextField("Output text template", text: $settings.textTemplate)
                    .textFieldStyle(.roundedBorder)
                Text("Leave empty to use the notification text. Use {app}, {title}, {body}, or regex captures such as {1}.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if [.centerText, .largeText, .glow].contains(kind) {
                NotificationNumberSetting("Effect duration", value: $settings.durationSeconds,
                                          range: 0.5...3600, suffix: "s")
            }
            if kind == .glow {
                Stepper(value: flashCountBinding, in: 1...20) {
                    HStack {
                        Text("Flash count")
                        Spacer()
                        Text("\(settings.effectiveGlowFlashCount)").monospacedDigit()
                    }
                }
                .accessibilityLabel("Flash count")
                Text("Flashes finish within the effect duration. With Reduce Motion enabled, one gentle glow is shown instead.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if [.centerText, .largeText, .glow, .countdown].contains(kind) {
                ColorPicker("Alert color", selection: colorBinding, supportsOpacity: false)
            }
            if kind == .countdown {
                NotificationNumberSetting("Countdown duration", value: $settings.countdownSeconds,
                                          range: 1...86400, suffix: "s")
                TextField("Countdown regex", text: $settings.countdownPattern)
                    .textFieldStyle(.roundedBorder)
                Text("Optional regex: capture a number of seconds in group 1. If it does not match, no countdown starts.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = settings.countdownPatternError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Text("When countdown ends").font(.body.weight(.medium))
                ForEach(NotificationOutputKind.allCases.filter { $0 != .countdown }, id: \.self) { completion in
                    Toggle(completion.label, isOn: completionBinding(completion))
                }
            }
            if kind == .sound {
                Picker("Alert sound", selection: $settings.soundName) {
                    ForEach(["Glass", "Hero", "Morse", "Ping", "Pop", "Submarine", "Tink"], id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .disabled(settings.speechEnabled)
                Toggle("Speak the message", isOn: $settings.speechEnabled)
            }
        }
    }

    private var flashCountBinding: Binding<Int> {
        Binding(
            get: { settings.effectiveGlowFlashCount },
            set: { settings.glowFlashCount = $0 }
        )
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: settings.colorHex) ?? .yellow },
            set: { value in
                guard let color = NSColor(value).usingColorSpace(.genericRGB) else { return }
                settings.colorHex = String(
                    format: "#%02X%02X%02X",
                    Int((min(1, max(0, color.redComponent)) * 255).rounded()),
                    Int((min(1, max(0, color.greenComponent)) * 255).rounded()),
                    Int((min(1, max(0, color.blueComponent)) * 255).rounded())
                )
            }
        )
    }

    private func completionBinding(_ completion: NotificationOutputKind) -> Binding<Bool> {
        Binding(
            get: { settings.completionOutputs.contains(completion) },
            set: { enabled in
                if enabled { settings.completionOutputs.insert(completion) }
                else { settings.completionOutputs.remove(completion) }
            }
        )
    }
}

private extension NotificationOutputSettings {
    func summary(for kind: NotificationOutputKind) -> String {
        var parts: [String] = []
        switch kind {
        case .card:
            parts.append(card.summary)
        case .centerText, .largeText, .glow:
            parts.append(String(format: NSLocalizedString("Effect duration: %@ s", comment: "Notification output summary"),
                                durationSeconds.formatted()))
        case .countdown:
            parts.append(countdownPattern.isEmpty
                ? String(format: NSLocalizedString("Countdown duration: %@ s", comment: "Notification output summary"),
                         countdownSeconds.formatted())
                : String(format: NSLocalizedString("Countdown regex: %@", comment: "Notification output summary"),
                         countdownPattern))
        case .sound:
            parts.append(speechEnabled ? NSLocalizedString("Speak the message", comment: "Notification output summary") : soundName)
        case .important:
            break
        }
        if kind == .glow {
            parts.append(String(format: NSLocalizedString("Flash count: %ld", comment: "Notification output summary"),
                                effectiveGlowFlashCount))
        }
        if [.centerText, .largeText, .glow, .countdown].contains(kind) { parts.append(colorHex) }
        if kind != .glow {
            parts.append(textTemplate.isEmpty
                ? NSLocalizedString("Notification text", comment: "Notification output summary") : textTemplate)
        }
        return parts.joined(separator: " · ")
    }

    var countdownPatternError: String? {
        guard !countdownPattern.isEmpty else { return nil }
        guard let expression = try? NSRegularExpression(pattern: countdownPattern) else {
            return NSLocalizedString("Invalid countdown regex.", comment: "Notification countdown rule")
        }
        guard expression.numberOfCaptureGroups > 0 else {
            return NSLocalizedString("Countdown regex must capture seconds in group 1.", comment: "Notification countdown rule")
        }
        return nil
    }
}

private extension NotificationOutputs {
    func countdownPatternError(defaults: [NotificationOutputKind: NotificationOutputSettings]) -> String? {
        guard enabled.contains(.countdown) else { return nil }
        return (overrides[.countdown] ?? defaults[.countdown] ?? NotificationOutputSettings()).countdownPatternError
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
