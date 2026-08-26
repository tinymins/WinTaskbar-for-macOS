import AppKit
import SwiftUI

enum ShortcutEditorMetrics {
    static let width: CGFloat = 540
    static let emptyHeight: CGFloat = 206
    static let populatedHeight: CGFloat = 360
    static let listHeight: CGFloat = 160

    static func contentSize(shortcutCount: Int) -> CGSize {
        CGSize(width: width, height: shortcutCount == 0 ? emptyHeight : populatedHeight)
    }
}

struct ShortcutEditorValidation {
    static func canAdd(name: String, target: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

@MainActor
final class ShortcutEditorController: NSWindowController {
    private let preferences: PreferencesStore

    init(preferences: PreferencesStore) {
        self.preferences = preferences
        let window = NSWindow(
            contentRect: NSRect(
                origin: .zero,
                size: ShortcutEditorMetrics.contentSize(shortcutCount: 0)
            ),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "WinTaskbar Shortcuts"
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { nil }

    func present(bundleID: String, appName: String) {
        guard let window else { return }
        let shortcutCount = preferences.pinnedShortcuts[bundleID]?.count ?? 0
        window.contentView = NSHostingView(rootView: ShortcutEditorView(
            bundleID: bundleID,
            appName: appName,
            preferences: preferences,
            onContentSizeChange: { [weak self] count in
                self?.window?.setContentSize(ShortcutEditorMetrics.contentSize(shortcutCount: count))
            },
            onDone: { [weak self] in self?.close() }
        ))
        window.setContentSize(ShortcutEditorMetrics.contentSize(shortcutCount: shortcutCount))
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}

private struct ShortcutEditorView: View {
    let bundleID: String
    let appName: String
    @ObservedObject var preferences: PreferencesStore
    let onContentSizeChange: (Int) -> Void
    let onDone: () -> Void
    @State private var shortcuts: [PinnedShortcut]
    @State private var newName = ""
    @State private var newTarget = ""

    init(
        bundleID: String,
        appName: String,
        preferences: PreferencesStore,
        onContentSizeChange: @escaping (Int) -> Void,
        onDone: @escaping () -> Void
    ) {
        self.bundleID = bundleID
        self.appName = appName
        self.preferences = preferences
        self.onContentSizeChange = onContentSizeChange
        self.onDone = onDone
        _shortcuts = State(initialValue: preferences.pinnedShortcuts[bundleID] ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Shortcuts for \(appName)")
                .font(.headline)

            Text("Files, folders, or links (https://…) added to this app's right-click menu. They open with the app.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if shortcuts.isEmpty {
                Text("No shortcuts yet — add one below.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            } else {
                List {
                    ForEach($shortcuts) { $shortcut in
                        HStack(spacing: 8) {
                            TextField("Name", text: $shortcut.name)
                                .textFieldStyle(.roundedBorder)
                            TextField("Path or URL", text: $shortcut.target)
                                .textFieldStyle(.roundedBorder)
                            Button {
                                shortcuts.removeAll { $0.id == shortcut.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove")
                        }
                    }
                }
                .frame(height: ShortcutEditorMetrics.listHeight)
            }

            Divider()

            HStack(spacing: 8) {
                TextField("Name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                TextField("Path or URL", text: $newTarget)
                    .textFieldStyle(.roundedBorder)
                Button("Choose…", action: choose)
                Button("Add", action: add)
                    .disabled(!ShortcutEditorValidation.canAdd(name: newName, target: newTarget))
            }

            HStack {
                Spacer()
                Button("Done", action: finish)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(
            width: ShortcutEditorMetrics.width,
            height: ShortcutEditorMetrics.contentSize(shortcutCount: shortcuts.count).height,
            alignment: .topLeading
        )
        .onChange(of: shortcuts.isEmpty) { _ in onContentSizeChange(shortcuts.count) }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        newTarget = url.path
        if newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            newName = url.lastPathComponent
        }
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = newTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ShortcutEditorValidation.canAdd(name: name, target: target) else { return }
        shortcuts.append(PinnedShortcut(name: name, target: target))
        newName = ""
        newTarget = ""
    }

    private func finish() {
        persist(shortcuts)
        onDone()
    }

    private func persist(_ values: [PinnedShortcut]) {
        preferences.pinnedShortcuts[bundleID] = values.filter {
            ShortcutEditorValidation.canAdd(name: $0.name, target: $0.target)
        }
    }
}
