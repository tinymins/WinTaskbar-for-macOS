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
                Group {
                    HStack {
                        Text("Fast scrolling multiplier")
                        Slider(value: sliderBinding($preferences.mouseEnhancement.speed, bounds: 1...10), in: 1...10)
                        MouseScrollTuningField(value: $preferences.mouseEnhancement.speed, bounds: 1...10, label: "Fast scrolling multiplier")
                        Text("×")
                    }
                    Text("Slow scrolling moves one line at a time. Fast scrolling preserves system acceleration and applies this multiplier.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text("Scroll response")
                        Slider(value: sliderBinding($preferences.mouseEnhancement.response, bounds: 1...5), in: 1...5)
                        MouseScrollTuningField(value: $preferences.mouseEnhancement.response, bounds: 1...5, label: "Scroll response")
                    }
                    Text("A larger response value gives a softer, longer transition. It is a response scale, not a duration in seconds.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Reset scroll tuning") { preferences.mouseEnhancement.resetTuning() }
                }
                .disabled(!preferences.mouseEnhancement.smoothScrolling)
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
                Text("Recognized ToDesk and Screen Sharing input passes through without smoothing or reversal. Local mouse-driver input can be enhanced. Some remote tools hide their origin; pause mouse enhancement if scrolling changes while this Mac is remotely controlled.")
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

    private func sliderBinding(_ value: Binding<Double>, bounds: ClosedRange<Double>) -> Binding<Double> {
        Binding(
            get: { value.wrappedValue },
            set: { value.wrappedValue = min(bounds.upperBound, max(bounds.lowerBound, ($0 * 100).rounded() / 100)) }
        )
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

@MainActor
private struct MouseScrollTuningField: View {
    @Binding var value: Double
    let bounds: ClosedRange<Double>
    let label: String
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(LocalizedStringKey(label), text: $draft)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: 76)
            .focused($focused)
            .onAppear { syncDraft() }
            .onChange(of: value) { _ in syncDraft() }
            .onChange(of: focused) { editing in if !editing { commit() } }
            .onSubmit { commit() }
    }

    private func syncDraft() {
        draft = value.formatted(.number.precision(.fractionLength(2)).grouping(.never))
    }

    private func commit() {
        value = Self.normalizedValue(draft, fallback: value, bounds: bounds)
        syncDraft()
    }

    static func normalizedValue(_ input: String, fallback: Double, bounds: ClosedRange<Double>) -> Double {
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .decimal
        formatter.isLenient = false
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let separator = NSRegularExpression.escapedPattern(for: formatter.decimalSeparator ?? ".")
        let pattern = "^[+-]?(?:\\p{Nd}+(?:\(separator)\\p{Nd}*)?|\(separator)\\p{Nd}+)$"
        guard text.range(of: pattern, options: .regularExpression) != nil,
              let parsed = formatter.number(from: text)?.doubleValue, parsed.isFinite else { return fallback }
        return min(bounds.upperBound, max(bounds.lowerBound, parsed))
    }
}
