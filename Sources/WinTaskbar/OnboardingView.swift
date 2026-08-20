import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var permissions: PermissionsService
    @ObservedObject var dockToggle: DockToggleService
    let onFinish: () -> Void
    @State private var step = 0

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: step == 0 ? "rectangle.bottomthird.inset.filled" : step == 1 ? "accessibility" : "dock.rectangle")
                .font(.system(size: 52)).foregroundStyle(.tint)
            Group {
                if step == 0 {
                    Text("Welcome to WinTaskbar").font(.largeTitle.bold())
                    Text("WinTaskbar replaces the Dock with a Windows-style taskbar.")
                } else if step == 1 {
                    Text("Accessibility").font(.title.bold())
                    Text("WinTaskbar needs Accessibility access to list and manage app windows.")
                    Button(permissions.accessibilityTrusted ? "Granted" : "Grant Accessibility") {
                        permissions.promptForAccessibility()
                    }
                } else {
                    Text("Hide system Dock").font(.title.bold())
                    Text("WinTaskbar can hide the macOS Dock so only the taskbar shows. You can restore it anytime in Settings.")
                    Toggle("Hide the system Dock", isOn: Binding(
                        get: { dockToggle.isDockHidden },
                        set: { $0 ? dockToggle.hideDock() : dockToggle.restoreDock() }
                    ))
                    .toggleStyle(.switch)
                }
            }
            .multilineTextAlignment(.center)
            Spacer()
            HStack {
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                Button(step == 2 ? "Get Started" : "Next") {
                    if step == 2 { onFinish() } else { step += 1 }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(34).frame(width: 520, height: 410)
        .onAppear { permissions.refresh() }
    }
}

@MainActor
final class OnboardingWindowController: NSWindowController {
    init(preferences: PreferencesStore) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 410),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to WinTaskbar"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = NSHostingView(rootView: OnboardingView(
            permissions: .shared,
            dockToggle: .shared,
            onFinish: { [weak self, weak preferences] in
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
