import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var permissions: PermissionsService
    let onFinish: (Bool, Bool, Bool) -> Void
    @State private var step = 0
    @State private var allTabEnabled = false
    @State private var taskbarEnabled = false
    @State private var hideSystemDock = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: step == 0 ? "switch.2" : step == 1 ? "accessibility" : "dock.rectangle")
                .font(.system(size: 52)).foregroundStyle(.tint)
            Group {
                if step == 0 {
                    Text("Welcome to WinTaskbar").font(.largeTitle.bold())
                    Text("Choose either feature, both, or neither. You can change this anytime in Settings.")
                    VStack(alignment: .leading, spacing: 16) {
                        onboardingFeature(
                            title: "Alt+Tab",
                            description: "Switch between open windows with a Windows-style Alt+Tab interface.",
                            isOn: $allTabEnabled
                        )
                        onboardingFeature(
                            title: "Taskbar",
                            description: "Show a Windows-style taskbar, Start menu, system tray, and taskbar shortcuts.",
                            isOn: $taskbarEnabled
                        )
                    }
                } else if step == 1 {
                    Text("Accessibility").font(.title.bold())
                    Text("Alt+Tab and Taskbar need Accessibility access to list and manage app windows.")
                    Button(permissions.accessibilityTrusted ? "Granted" : "Grant Accessibility") {
                        permissions.promptForAccessibility()
                    }
                } else {
                    Text("Hide system Dock").font(.title.bold())
                    if taskbarEnabled {
                        Text("Taskbar can hide the macOS Dock so only the Windows-style taskbar remains.")
                        Toggle("Hide the system Dock", isOn: $hideSystemDock)
                            .toggleStyle(.switch)
                    } else {
                        Text("Enable Taskbar on the first step to configure the system Dock.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .multilineTextAlignment(.center)
            Spacer()
            HStack {
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                Button(step == 2 ? "Get Started" : "Next") {
                    if step == 2 {
                        onFinish(allTabEnabled, taskbarEnabled, hideSystemDock)
                    } else {
                        step += 1
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(34).frame(width: 560, height: 440)
        .onAppear { permissions.refresh() }
    }

    private func onboardingFeature(
        title: LocalizedStringKey,
        description: LocalizedStringKey,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(14)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

@MainActor
final class OnboardingWindowController: NSWindowController {
    init(preferences: PreferencesStore) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to WinTaskbar"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = NSHostingView(rootView: OnboardingView(
            permissions: .shared,
            onFinish: { [weak self, weak preferences] allTabEnabled, taskbarEnabled, hideSystemDock in
                preferences?.altTabSwitcherEnabled = allTabEnabled
                preferences?.taskbarEnabled = taskbarEnabled
                if taskbarEnabled, hideSystemDock {
                    DockToggleService.shared.hideDock()
                } else if DockToggleService.shared.isDockHidden {
                    DockToggleService.shared.restoreDock()
                }
                preferences?.hasCompletedOnboarding = true
                self?.close()
            }
        ))
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
