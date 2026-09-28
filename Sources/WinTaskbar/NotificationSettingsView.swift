import AppKit
import SwiftUI

struct NotificationSettingsView: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject private var service = SystemNotificationService.shared
    @ObservedObject private var permissions = PermissionsService.shared
    @State private var editingRule: NotificationCaptureRule?
    @State private var settingsOpenFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("Windows-style notifications") {
                Toggle("Show notifications at the bottom right", isOn: $preferences.notifications.enabled)
                Text("Enlarge captured system notifications and stack them above the taskbar. Original macOS notifications remain enabled.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Timing starts when a card is shown and pauses while you hover over it. Overflow cards wait in the queue. Closing WinTaskbar clears the cards.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Preview fallback") { service.showPreview() }
                    Button("Clear notification cards") { service.clearCards() }
                }
                Text(LocalizedStringKey(service.statusKey))
                    .font(.caption).foregroundStyle(.secondary)
            }

            SettingsSection("Capture rules") {
                Text("Rules are checked from top to bottom. The first enabled match decides how to show the notification. Unmatched notifications use the fallback below.")
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
                            Text(rule.behavior.summary).font(.caption).foregroundStyle(.secondary)
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
                NotificationBehaviorEditor(behavior: $preferences.notifications.fallback)
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
        .sheet(item: $editingRule) { rule in
            NotificationRuleEditor(rule: rule) { updated in
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
}

private struct NotificationRuleEditor: View {
    @State var rule: NotificationCaptureRule
    let onSave: (NotificationCaptureRule) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Capture rule").font(.title2.weight(.semibold))
            TextField("App name contains", text: $rule.appName).textFieldStyle(.roundedBorder)
            Text("Matches the notification's app name, ignoring case. Leave empty to match any app.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Message regular expression", text: $rule.messagePattern).textFieldStyle(.roundedBorder)
            Text("Matches title and body together. Example: meeting|urgent. Use (?i) to ignore case. Leave empty to match any message.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = rule.patternError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            Divider()
            NotificationBehaviorEditor(behavior: $rule.behavior)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(rule) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(rule.isEmpty || rule.patternError != nil)
            }
        }.padding(24).frame(width: 480)
    }
}

private struct NotificationBehaviorEditor: View {
    @Binding var behavior: NotificationDisplayBehavior

    var body: some View {
        Picker("Display behavior", selection: $behavior.mode) {
            ForEach(NotificationDisplayBehavior.Mode.allCases, id: \.self) { mode in
                Text(LocalizedStringKey(mode.label)).tag(mode)
            }
        }
        if behavior.mode == .timed {
            HStack {
                Text("Display time (seconds)")
                Spacer()
                TextField("Seconds", value: $behavior.seconds, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 70)
                    .onChange(of: behavior.seconds) { value in
                        behavior.seconds = min(3600, max(1, value))
                    }
                Stepper("Display time (seconds)", value: $behavior.seconds, in: 1...3600)
                    .labelsHidden()
            }
        }
    }
}
