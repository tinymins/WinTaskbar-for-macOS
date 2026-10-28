import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MouseEnhancementSettingsView: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject private var service = MouseEnhancementService.shared
    @ObservedObject private var permissions = PermissionsService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("Mouse Enhancement") {
                Toggle("Enable mouse enhancement", isOn: $preferences.mouseEnhancement.enabled)
                    .toggleStyle(.switch)
                Text("Works independently of the taskbar. Trackpad and continuous scrolling keep their original behavior.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(LocalizedStringKey(service.statusKey))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(LocalizedStringKey(service.isPaused ? "Resume mouse enhancement" : "Pause mouse enhancement")) {
                        service.setPaused(!service.isPaused)
                    }
                    .disabled(!preferences.mouseEnhancement.enabled)
                    Button("Refresh") { refresh() }
                }
                if !permissions.accessibilityTrusted {
                    Button("Open Accessibility Settings") { permissions.openAccessibilitySettings() }
                }
            }

            SettingsSection("Wheel behavior") {
                Toggle("Smooth mouse scrolling", isOn: $preferences.mouseEnhancement.smoothScrolling)
                HStack {
                    Text("Scroll speed")
                    Slider(value: $preferences.mouseEnhancement.speed, in: 0.25...4, step: 0.05)
                    Text(preferences.mouseEnhancement.effectiveSpeed.formatted(.number.precision(.fractionLength(2))) + "×")
                        .monospacedDigit().frame(width: 52, alignment: .trailing)
                }
                HStack {
                    Text("Smoothing duration")
                    Slider(value: $preferences.mouseEnhancement.duration, in: 0.05...0.5, step: 0.01)
                    Text(String(format: "%.0f ms", preferences.mouseEnhancement.effectiveDuration * 1_000))
                        .monospacedDigit().frame(width: 62, alignment: .trailing)
                }.disabled(!preferences.mouseEnhancement.smoothScrolling)
                Toggle("Reverse vertical scrolling", isOn: $preferences.mouseEnhancement.reverseVertical)
                    .disabled(service.verticalReversalBlocked)
                Toggle("Reverse horizontal scrolling", isOn: $preferences.mouseEnhancement.reverseHorizontal)
                    .disabled(service.horizontalReversalBlocked)
                if service.verticalReversalBlocked || service.horizontalReversalBlocked {
                    Text("Reversal is unavailable on axes already reversed by Karabiner, or when its configuration cannot be read. Existing Karabiner settings are kept. Refresh after changing them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(!preferences.mouseEnhancement.enabled)

            SettingsSection("Remote control") {
                Text("Identifiable injected input, including ToDesk input, passes through without smoothing or reversal. Some remote tools hide its origin; pause mouse enhancement if scrolling changes while this Mac is remotely controlled.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Pause lasts until you resume or quit WinTaskbar. Avoid running another scrolling enhancer at the same time.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            SettingsSection("Use original scrolling in these apps") {
                Text("Excluded apps receive unmodified scrolling. This list applies to the app being scrolled, not to the source of a remote-control connection.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(preferences.mouseEnhancement.excludedApps) { app in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name)
                            Text(app.bundleID).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove") {
                            preferences.mouseEnhancement.excludedApps.removeAll { $0.id == app.id }
                        }
                    }
                }
                Button("Add application…") { addApplication() }
            }
            .disabled(!preferences.mouseEnhancement.enabled)
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        permissions.refresh()
        service.refresh()
    }

    private func addApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier,
                  !preferences.mouseEnhancement.excludedApps.contains(where: { $0.bundleID == bundleID }) else { continue }
            preferences.mouseEnhancement.excludedApps.append(MouseEnhancementExcludedApp(
                bundleID: bundleID,
                name: FileManager.default.displayName(atPath: url.path)
            ))
        }
    }
}
