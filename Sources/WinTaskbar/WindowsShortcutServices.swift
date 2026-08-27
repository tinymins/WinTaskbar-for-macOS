import AppKit
import ApplicationServices
import Combine
import SwiftUI

enum WindowPlacement: String, CaseIterable, Identifiable {
    case leftHalf
    case rightHalf
    case maximized
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leftHalf: "Left"
        case .rightHalf: "Right"
        case .maximized: "Maximize"
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        }
    }
}

enum WindowPlacementGeometry {
    static func frame(for placement: WindowPlacement, in available: CGRect) -> CGRect {
        let halfWidth = (available.width / 2).rounded(.down)
        let halfHeight = (available.height / 2).rounded(.down)
        switch placement {
        case .leftHalf:
            return CGRect(x: available.minX, y: available.minY, width: halfWidth, height: available.height)
        case .rightHalf:
            return CGRect(x: available.minX + halfWidth, y: available.minY, width: available.width - halfWidth, height: available.height)
        case .maximized:
            return available
        case .topLeft:
            return CGRect(x: available.minX, y: available.minY + halfHeight, width: halfWidth, height: available.height - halfHeight)
        case .topRight:
            return CGRect(x: available.minX + halfWidth, y: available.minY + halfHeight, width: available.width - halfWidth, height: available.height - halfHeight)
        case .bottomLeft:
            return CGRect(x: available.minX, y: available.minY, width: halfWidth, height: halfHeight)
        case .bottomRight:
            return CGRect(x: available.minX + halfWidth, y: available.minY, width: available.width - halfWidth, height: halfHeight)
        }
    }
}

enum WindowArrangement {
    case cascade
    case stacked
    case sideBySide
}

enum WindowArrangementGeometry {
    static func frames(for arrangement: WindowArrangement, count: Int, in available: CGRect) -> [CGRect] {
        guard count > 0 else { return [] }
        switch arrangement {
        case .stacked:
            return partition(available, count: count, vertically: true)
        case .sideBySide:
            return partition(available, count: count, vertically: false)
        case .cascade:
            let offset = min(CGFloat(28), min(available.width, available.height) / CGFloat(count + 5))
            let width = max(
                WindowFittingGeometry.minimumWindowSize.width,
                available.width - offset * CGFloat(max(count - 1, 0))
            )
            let height = max(
                WindowFittingGeometry.minimumWindowSize.height,
                available.height - offset * CGFloat(max(count - 1, 0))
            )
            return (0..<count).map { index in
                CGRect(
                    x: available.minX + offset * CGFloat(index),
                    y: available.maxY - height - offset * CGFloat(index),
                    width: width,
                    height: height
                )
            }
        }
    }

    private static func partition(_ available: CGRect, count: Int, vertically: Bool) -> [CGRect] {
        (0..<count).map { index in
            if vertically {
                let start = (available.height * CGFloat(index) / CGFloat(count)).rounded(.down)
                let end = (available.height * CGFloat(index + 1) / CGFloat(count)).rounded(.down)
                return CGRect(
                    x: available.minX,
                    y: available.maxY - end,
                    width: available.width,
                    height: end - start
                )
            }
            let start = (available.width * CGFloat(index) / CGFloat(count)).rounded(.down)
            let end = (available.width * CGFloat(index + 1) / CGFloat(count)).rounded(.down)
            return CGRect(
                x: available.minX + start,
                y: available.minY,
                width: end - start,
                height: available.height
            )
        }
    }
}

@MainActor
final class WindowArrangementService {
    private let preferences: PreferencesStore
    private var minimizedWindows: [AXUIElement] = []

    init(preferences: PreferencesStore) {
        self.preferences = preferences
    }

    func arrange(_ arrangement: WindowArrangement, on screen: NSScreen) {
        guard ensureAccessibility() else { return }
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height
            ?? screen.frame.height
        let windows = candidateWindows(on: screen, primaryHeight: primaryHeight)
        let available = WindowFittingGeometry.freeRect(
            on: WindowFittingScreenBox(frame: screen.frame, visibleFrame: screen.visibleFrame),
            position: preferences.position,
            barHeight: preferences.autoHideTaskbar ? 0 : CGFloat(preferences.barHeight)
        )
        for (window, frame) in zip(
            windows,
            WindowArrangementGeometry.frames(for: arrangement, count: windows.count, in: available)
        ) {
            setFrame(frame, for: window, primaryHeight: primaryHeight)
        }
    }

    func minimizeAll(on screen: NSScreen) {
        guard minimizedWindows.isEmpty, ensureAccessibility() else { return }
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height
            ?? screen.frame.height
        for window in candidateWindows(on: screen, primaryHeight: primaryHeight) {
            if AXUIElementSetAttributeValue(
                window,
                kAXMinimizedAttribute as CFString,
                true as CFBoolean
            ) == .success {
                minimizedWindows.append(window)
            }
        }
    }

    func restoreMinimized() {
        minimizedWindows.forEach {
            _ = AXUIElementSetAttributeValue(
                $0,
                kAXMinimizedAttribute as CFString,
                false as CFBoolean
            )
        }
        minimizedWindows.removeAll()
    }

    private func ensureAccessibility() -> Bool {
        guard !AXIsProcessTrusted() else { return true }
        return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    private func candidateWindows(on screen: NSScreen, primaryHeight: CGFloat) -> [AXUIElement] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter {
                $0.activationPolicy == .regular
                    && !$0.isTerminated
                    && $0.processIdentifier != ownPID
            }
            .flatMap { application -> [AXUIElement] in
                let element = AXUIElementCreateApplication(application.processIdentifier)
                return windows(of: element).filter { window in
                    guard string(window, attribute: kAXSubroleAttribute as CFString) == kAXStandardWindowSubrole,
                          !bool(window, attribute: kAXMinimizedAttribute as CFString),
                          let frame = cocoaFrame(of: window, primaryHeight: primaryHeight) else { return false }
                    return screen.frame.contains(CGPoint(x: frame.midX, y: frame.midY))
                }
            }
    }

    private func setFrame(_ frame: CGRect, for window: AXUIElement, primaryHeight: CGFloat) {
        var position = WindowFittingGeometry.axPosition(cocoaFrame: frame, primaryHeight: primaryHeight)
        var size = frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else { return }
        _ = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        _ = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
    }

    private func cocoaFrame(of window: AXUIElement, primaryHeight: CGFloat) -> CGRect? {
        guard let position = point(window, attribute: kAXPositionAttribute as CFString),
              let size = size(window, attribute: kAXSizeAttribute as CFString) else { return nil }
        return WindowFittingGeometry.cocoaFrame(
            axPosition: position,
            size: size,
            primaryHeight: primaryHeight
        )
    }

    private func windows(of application: AXUIElement) -> [AXUIElement] {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &raw) == .success else {
            return []
        }
        return raw as? [AXUIElement] ?? []
    }

    private func string(_ element: AXUIElement, attribute: CFString) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success else { return nil }
        return raw as? String
    }

    private func bool(_ element: AXUIElement, attribute: CFString) -> Bool {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success else { return false }
        return raw as? Bool ?? false
    }

    private func point(_ element: AXUIElement, attribute: CFString) -> CGPoint? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success,
              let value = raw as! AXValue? else { return nil }
        var result = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &result) ? result : nil
    }

    private func size(_ element: AXUIElement, attribute: CFString) -> CGSize? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success,
              let value = raw as! AXValue? else { return nil }
        var result = CGSize.zero
        return AXValueGetValue(value, .cgSize, &result) ? result : nil
    }
}

@MainActor
final class ActiveWindowShortcutService {
    private struct WindowKey: Hashable {
        let pid: pid_t
        let elementHash: CFHashCode
    }

    private struct FocusedWindow {
        let key: WindowKey
        let element: AXUIElement
        let frame: CGRect
        let screen: NSScreen
        let primaryHeight: CGFloat
    }

    private let preferences: PreferencesStore
    private var restoreFrames: [WindowKey: CGRect] = [:]

    init(preferences: PreferencesStore) {
        self.preferences = preferences
    }

    func place(_ placement: WindowPlacement) {
        guard let focused = focusedWindow() else { return }
        if restoreFrames[focused.key] == nil,
           placement != .maximized || !approximatelyEqual(
               focused.frame,
               WindowPlacementGeometry.frame(for: .maximized, in: availableFrame(on: focused.screen))
           ) {
            restoreFrames[focused.key] = focused.frame
        }
        setFrame(
            WindowPlacementGeometry.frame(for: placement, in: availableFrame(on: focused.screen)),
            for: focused
        )
    }

    func restoreOrMinimize() {
        guard let focused = focusedWindow() else { return }
        if let restoreFrame = restoreFrames.removeValue(forKey: focused.key) {
            setFrame(restoreFrame, for: focused)
        } else {
            _ = AXUIElementSetAttributeValue(
                focused.element,
                kAXMinimizedAttribute as CFString,
                true as CFBoolean
            )
        }
    }

    func moveToAdjacentDisplay(step: Int) {
        guard let focused = focusedWindow(), NSScreen.screens.count > 1 else { return }
        let screens = NSScreen.screens.sorted {
            if $0.frame.minX == $1.frame.minX { return $0.frame.minY < $1.frame.minY }
            return $0.frame.minX < $1.frame.minX
        }
        guard let currentIndex = screens.firstIndex(where: { $0 === focused.screen }) else { return }
        let targetIndex = (currentIndex + step + screens.count) % screens.count
        let source = availableFrame(on: focused.screen)
        let target = availableFrame(on: screens[targetIndex])
        let relativeX = source.width > focused.frame.width
            ? (focused.frame.minX - source.minX) / (source.width - focused.frame.width)
            : 0
        let relativeY = source.height > focused.frame.height
            ? (focused.frame.minY - source.minY) / (source.height - focused.frame.height)
            : 0
        let size = CGSize(
            width: min(focused.frame.width, target.width),
            height: min(focused.frame.height, target.height)
        )
        let destination = CGRect(
            x: target.minX + max(0, target.width - size.width) * relativeX,
            y: target.minY + max(0, target.height - size.height) * relativeY,
            width: size.width,
            height: size.height
        )
        setFrame(destination, for: focused)
    }

    private func focusedWindow() -> FocusedWindow? {
        guard AXIsProcessTrusted(),
              let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let window: AXUIElement = attribute(applicationElement, kAXFocusedWindowAttribute),
              let positionValue: AXValue = attribute(window, kAXPositionAttribute),
              let sizeValue: AXValue = attribute(window, kAXSizeAttribute) else { return nil }
        var axPosition = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &axPosition),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height
            ?? NSScreen.screens[0].frame.height
        let frame = WindowFittingGeometry.cocoaFrame(
            axPosition: axPosition,
            size: size,
            primaryHeight: primaryHeight
        )
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) })
                ?? NSScreen.main else { return nil }
        return FocusedWindow(
            key: WindowKey(pid: application.processIdentifier, elementHash: CFHash(window)),
            element: window,
            frame: frame,
            screen: screen,
            primaryHeight: primaryHeight
        )
    }

    private func availableFrame(on screen: NSScreen) -> CGRect {
        WindowFittingGeometry.freeRect(
            on: WindowFittingScreenBox(frame: screen.frame, visibleFrame: screen.visibleFrame),
            position: preferences.position,
            barHeight: CGFloat(preferences.barHeight)
        )
    }

    private func setFrame(_ frame: CGRect, for focused: FocusedWindow) {
        var position = WindowFittingGeometry.axPosition(
            cocoaFrame: frame,
            primaryHeight: focused.primaryHeight
        )
        var size = frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else { return }
        _ = AXUIElementSetAttributeValue(focused.element, kAXPositionAttribute as CFString, positionValue)
        _ = AXUIElementSetAttributeValue(focused.element, kAXSizeAttribute as CFString, sizeValue)
        _ = AXUIElementSetAttributeValue(focused.element, kAXPositionAttribute as CFString, positionValue)
    }

    private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 3 && abs(lhs.minY - rhs.minY) < 3
            && abs(lhs.width - rhs.width) < 3 && abs(lhs.height - rhs.height) < 3
    }
}

@MainActor
final class SystemShortcutService {
    enum DesktopDirection { case left, right }

    func showTaskView() { postKey(keyCode: 126, flags: .maskControl) }
    func switchDesktop(_ direction: DesktopDirection) {
        postKey(keyCode: direction == .left ? 123 : 124, flags: .maskControl)
    }
    func showCharacterPalette() { postKey(keyCode: 49, flags: [.maskCommand, .maskControl]) }

    func captureScreenRegion() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i"]
        try? process.run()
    }

    func openAccessibilitySettings() {
        openSettings("com.apple.Accessibility-Settings.extension")
    }

    func openDisplaySettings() {
        openSettings("com.apple.Displays-Settings.extension")
    }

    func createDesktop() {
        performMissionControlButton(
            matching: ["add desktop", "add space", "添加桌面", "添加空间"]
        )
    }

    func closeDesktop() {
        performMissionControlButton(
            matching: ["remove desktop", "close desktop", "删除桌面", "关闭桌面"]
        )
    }

    func postPaste() { postKey(keyCode: 9, flags: .maskCommand) }

    private func openSettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func postKey(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func performMissionControlButton(matching labels: [String]) {
        showTaskView()
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(800)) {
            guard let dock = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.dock"
            ).first else {
                NSSound.beep()
                return
            }
            let root = AXUIElementCreateApplication(dock.processIdentifier)
            guard let button = Self.findButton(in: root, matching: labels, depth: 0) else {
                NSSound.beep()
                return
            }
            _ = AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
    }

    private nonisolated static func findButton(
        in element: AXUIElement,
        matching labels: [String],
        depth: Int
    ) -> AXUIElement? {
        guard depth < 12 else { return nil }
        let role: String? = attribute(element, kAXRoleAttribute)
        if role == kAXButtonRole {
            let values: [String?] = [
                attribute(element, kAXTitleAttribute),
                attribute(element, kAXDescriptionAttribute),
                attribute(element, kAXHelpAttribute),
            ]
            let searchable = values.compactMap { $0 }.joined(separator: " ").lowercased()
            if labels.contains(where: searchable.contains) { return element }
        }
        let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
        for child in children {
            if let match = findButton(in: child, matching: labels, depth: depth + 1) { return match }
        }
        return nil
    }

    private nonisolated static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}

struct ClipboardHistoryEntry: Identifiable, Equatable {
    let id: UUID
    let text: String

    init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}

@MainActor
final class ClipboardHistoryService: ObservableObject {
    @Published private(set) var entries: [ClipboardHistoryEntry] = []
    private let pasteboard: NSPasteboard
    private var lastChangeCount: Int
    private var timer: AnyCancellable?

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        if let currentText = pasteboard.string(forType: .string) {
            record(currentText)
        }
        timer = Timer.publish(every: 0.6, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.captureCurrentItem() }
    }

    func copy(_ entry: ClipboardHistoryEntry) {
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
        lastChangeCount = pasteboard.changeCount
        record(entry.text)
    }

    func clear() {
        entries.removeAll()
    }

    static func recording(_ text: String, in values: [String], limit: Int = 20) -> [String] {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return values }
        return Array(([normalized] + values.filter { $0 != normalized }).prefix(limit))
    }

    private func captureCurrentItem() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string) else { return }
        record(text)
    }

    private func record(_ text: String) {
        let values = Self.recording(text, in: entries.map(\.text))
        let existing = Dictionary(uniqueKeysWithValues: entries.map { ($0.text, $0.id) })
        entries = values.map { ClipboardHistoryEntry(id: existing[$0] ?? UUID(), text: $0) }
    }
}

@MainActor
final class RunWindowController: NSWindowController, NSWindowDelegate {
    private let executor = RunCommandExecutor()
    private let model = RunDialogModel()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 398, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Run"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        guard let window else { return }
        model.prepareForPresentation()
        window.contentView = NSHostingView(rootView: RunDialogView(
            model: model,
            onRun: { [weak self] command in
                guard let self else { return "Run is unavailable." }
                let error = executor.run(command)
                if error == nil {
                    model.remember(command)
                    close()
                }
                return error
            },
            onBrowse: { [weak self] in
                if let path = Self.chooseItem() { self?.model.command = path }
            },
            onCancel: { [weak self] in self?.close() }
        ))
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private static func chooseItem() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Browse"
        panel.prompt = "Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

@MainActor
private final class RunDialogModel: ObservableObject {
    private static let historyKey = "wintaskbar.runHistory"
    @Published var command = ""
    @Published var errorMessage: String?
    @Published private(set) var history: [String]

    init(defaults: UserDefaults = .standard) {
        history = defaults.stringArray(forKey: Self.historyKey) ?? []
    }

    func prepareForPresentation() {
        command = ""
        errorMessage = nil
    }

    func remember(_ rawCommand: String, defaults: UserDefaults = .standard) {
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        history = Array(([command] + history.filter { $0 != command }).prefix(12))
        defaults.set(history, forKey: Self.historyKey)
    }
}

@MainActor
private final class RunCommandExecutor {
    func run(_ rawCommand: String) -> String? {
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return "Type a program, folder, document, or Internet resource." }

        if let url = URL(string: command), let scheme = url.scheme, !scheme.isEmpty {
            return NSWorkspace.shared.open(url) ? nil : "The resource could not be opened."
        }

        let expandedPath = NSString(string: command).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expandedPath) {
            return NSWorkspace.shared.open(URL(fileURLWithPath: expandedPath))
                ? nil
                : "The item could not be opened."
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", command]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
                ? nil
                : "macOS cannot find “\(command)”."
        } catch {
            return "macOS cannot find “\(command)”."
        }
    }
}

private struct RunDialogView: View {
    @ObservedObject var model: RunDialogModel
    let onRun: @MainActor (String) -> String?
    let onBrowse: @MainActor () -> Void
    let onCancel: @MainActor () -> Void
    @FocusState private var commandFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: "rectangle.on.rectangle.angled")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(Color.cyan)
                        .frame(width: 38)
                    Text("Type the name of a program, folder, document, or Internet resource, and WinTaskbar will open it for you.")
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Text("Open:")
                        .font(.system(size: 12))
                    HStack(spacing: 0) {
                        TextField("", text: $model.command)
                            .textFieldStyle(.plain)
                            .focused($commandFocused)
                            .onSubmit(run)
                            .padding(.horizontal, 7)
                        if !model.history.isEmpty {
                            Divider().frame(height: 20)
                            Menu {
                                ForEach(model.history, id: \.self) { value in
                                    Button(value) { model.command = value }
                                }
                            } label: {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                                    .frame(width: 25, height: 24)
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                        }
                    }
                    .frame(height: 25)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay {
                        Rectangle().stroke(commandFocused ? Color.accentColor : Color.secondary, lineWidth: 1)
                    }
                }
                if let errorMessage = model.errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 13)
            .padding(.bottom, 12)

            HStack {
                Spacer()
                Button("OK", action: run)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .frame(width: 80)
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .frame(width: 80)
                Button("Browse…", action: onBrowse)
                    .frame(width: 80)
            }
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.75))
        }
        .frame(width: 398, height: 180)
        .onAppear { commandFocused = true }
    }

    private func run() {
        model.errorMessage = onRun(model.command)
    }
}

struct SnapLayoutsView: View {
    let onSelect: (WindowPlacement) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Snap layouts").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(WindowPlacement.allCases) { placement in
                    Button {
                        onSelect(placement)
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: symbol(for: placement))
                                .font(.system(size: 22))
                            Text(placement.title).font(.caption2)
                        }
                        .frame(maxWidth: .infinity, minHeight: 52)
                    }
                }
            }
        }
        .padding(12)
    }

    private func symbol(for placement: WindowPlacement) -> String {
        switch placement {
        case .leftHalf: "rectangle.lefthalf.inset.filled"
        case .rightHalf: "rectangle.righthalf.inset.filled"
        case .maximized: "rectangle.inset.filled"
        case .topLeft: "rectangle.tophalf.inset.filled"
        case .topRight: "rectangle.tophalf.inset.filled"
        case .bottomLeft: "rectangle.bottomhalf.inset.filled"
        case .bottomRight: "rectangle.bottomhalf.inset.filled"
        }
    }
}

struct ClipboardHistoryView: View {
    @ObservedObject var service: ClipboardHistoryService
    let onSelect: (ClipboardHistoryEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Clipboard history").font(.headline)
                Spacer()
                Button("Clear") { service.clear() }
                    .buttonStyle(.borderless)
                    .disabled(service.entries.isEmpty)
            }
            if service.entries.isEmpty {
                Text("Copy text to add it to history.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 70)
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(service.entries) { entry in
                            Button {
                                onSelect(entry)
                            } label: {
                                Text(entry.text)
                                    .lineLimit(3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                            }
                            .buttonStyle(.plain)
                            .background(Color.primary.opacity(0.07))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }
            }
        }
        .padding(12)
    }
}
