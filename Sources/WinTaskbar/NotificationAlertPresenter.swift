import AppKit
import SwiftUI

/// Owns only on-screen notification views. The service owns their in-memory contents.
@MainActor
final class NotificationAlertPresenter {
    struct ImportantRow: Identifiable, Equatable {
        let id: String
        let appName: String
        let title: String
        let body: String
        let receivedAt: Date
    }

    struct CountdownRow: Identifiable {
        let id: String
        let title: String
        let deadline: TimeInterval // ProcessInfo.systemUptime
        let duration: TimeInterval
        let color: NSColor
    }

    var onImportantDismiss: ((String) -> Void)?
    var onImportantOpen: ((String) -> Void)?
    var onImportantClear: (() -> Void)?
    var onCountdownDismiss: ((String) -> Void)?
    var onLayoutChanged: ((NotificationPresentationPreferences) -> Void)?

    private var preferences = NotificationPresentationPreferences()
    private let glow = NotificationGlow()
    private var textPanels: [TextKind: NotificationAlertPanel] = [:]
    private var textTasks: [TextKind: Task<Void, Never>] = [:]
    private var textContents: [TextKind: (text: String, color: NSColor)] = [:]
    private var importantPanel: NotificationAlertPanel?
    private var countdownPanel: NotificationAlertPanel?
    private var importantRows: [ImportantRow] = []
    private var countdownRows: [CountdownRow] = []
    private lazy var sourceApps = AppDiscoveryService()
    private let speechSynthesizer = NSSpeechSynthesizer()
    private var layoutEditing = false
    private var suspended = false
    private var moveSession: LayoutPointerSession?
    private var resizeSession: LayoutPointerSession?

    @MainActor
    private struct LayoutPointerSession {
        let panel: NSPanel
        let frame: NSRect
        let mouseOrigin: NSPoint

        init(panel: NSPanel, firstTranslation: CGSize, mouse: NSPoint) {
            self.panel = panel
            frame = panel.frame
            // SwiftUI's local translation is safe only before the panel first moves.
            mouseOrigin = NSPoint(x: mouse.x - firstTranslation.width,
                                  y: mouse.y + firstTranslation.height)
        }

        func displacement(to mouse: NSPoint) -> NSPoint {
            NSPoint(x: mouse.x - mouseOrigin.x, y: mouse.y - mouseOrigin.y)
        }
    }

    private enum TextKind: Hashable { case center, large }
    private enum PanelKind { case center, large, countdown, important }

    func configure(_ value: NotificationPresentationPreferences) {
        let old = preferences
        preferences = value
        for (kind, panel) in textPanels {
            if let content = textContents[kind] {
                if old.centerFontSize != value.centerFontSize || old.largeFontSize != value.largeFontSize {
                    panel.contentView = NSHostingView(rootView: textOverlay(content.text, color: content.color, kind: kind))
                }
                panel.setContentSize(textSize(content.text, kind: kind))
            }
            position(panel, kind: kind == .center ? .center : .large)
            applyLevel(to: panel)
        }
        if let importantPanel {
            if old.importantWidth != value.importantWidth || old.importantHeight != value.importantHeight {
                renderImportant()
            }
            if old.importantX != value.importantX || old.importantY != value.importantY {
                position(importantPanel, kind: .important)
            }
            applyLevel(to: importantPanel)
        }
        if let countdownPanel { position(countdownPanel, kind: .countdown); applyLevel(to: countdownPanel) }
    }

    func showText(_ text: String, large: Bool, color: NSColor, duration: TimeInterval) {
        guard !suspended, NSScreen.screens.first != nil else { return }
        let kind: TextKind = large ? .large : .center
        textTasks[kind]?.cancel()
        textPanels[kind]?.close()
        textContents[kind] = (text, color)
        let view = textOverlay(text, color: color, kind: kind)
        let size = textSize(text, kind: kind)
        let panel = makePanel(size: size, interactive: layoutEditing)
        panel.contentView = NSHostingView(rootView: view)
        textPanels[kind] = panel
        position(panel, kind: large ? .large : .center)
        panel.orderFrontRegardless()
        textTasks[kind] = Task { [weak self] in
            let interval = max(0.1, duration)
            let fade = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : min(0.25, interval)
            do { try await Task.sleep(for: .seconds(interval - fade)) } catch { return }
            guard self?.textPanels[kind] === panel, !Task.isCancelled else { return }
            if fade > 0 {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = fade
                    panel.animator().alphaValue = 0
                }, completionHandler: nil)
                do { try await Task.sleep(for: .seconds(fade)) } catch { return }
            }
            guard self?.textPanels[kind] === panel, !Task.isCancelled else { return }
            self?.textPanels[kind]?.close()
            self?.textPanels[kind] = nil
            self?.textContents[kind] = nil
            self?.textTasks[kind] = nil
        }
    }

    func showGlow(color: NSColor, duration: TimeInterval) {
        guard !suspended, let screen = NSScreen.screens.first else { return }
        glow.show(on: screen, color: color, duration: duration,
                  showInFullscreen: preferences.showInFullscreen, alwaysOnTop: preferences.alwaysOnTop)
    }

    func playSound(named name: String, speech: String?) {
        if let speech, !speech.isEmpty {
            speechSynthesizer.stopSpeaking()
            speechSynthesizer.startSpeaking(speech)
        } else if let sound = NSSound(named: NSSound.Name(name)) {
            sound.play()
        } else {
            NSSound.beep()
        }
    }

    func setImportant(_ rows: [ImportantRow]) {
        guard rows != importantRows else { return }
        importantRows = rows
        renderImportant()
    }

    func setCountdown(_ rows: [CountdownRow]) {
        countdownRows = rows
        renderCountdown()
    }

    func setLayoutEditing(_ enabled: Bool) {
        guard layoutEditing != enabled else { return }
        layoutEditing = enabled
        moveSession = nil
        resizeSession = nil
        renderImportant()
        renderCountdown()
        if enabled {
            showText(NSLocalizedString("Central reminder", comment: "Layout preview"), large: false, color: .white, duration: 3600)
            showText(NSLocalizedString("Large reminder", comment: "Layout preview"), large: true, color: .white, duration: 3600)
        } else {
            for kind in [TextKind.center, .large] {
                textTasks[kind]?.cancel()
                textTasks[kind] = nil
                textPanels[kind]?.close()
                textPanels[kind] = nil
                textContents[kind] = nil
            }
        }
    }

    func setSuspended(_ value: Bool) {
        suspended = value
        if value {
            moveSession = nil
            resizeSession = nil
            glow.stop()
            speechSynthesizer.stopSpeaking()
            textPanels.values.forEach { $0.orderOut(nil) }
            importantPanel?.orderOut(nil)
            countdownPanel?.orderOut(nil)
        } else {
            textPanels.values.forEach { $0.orderFrontRegardless() }
            renderImportant()
            renderCountdown()
        }
    }

    func stop() {
        moveSession = nil
        resizeSession = nil
        glow.stop()
        speechSynthesizer.stopSpeaking()
        textTasks.values.forEach { $0.cancel() }
        textTasks.removeAll()
        textPanels.values.forEach { $0.close() }
        textPanels.removeAll()
        textContents.removeAll()
        importantPanel?.close()
        importantPanel = nil
        countdownPanel?.close()
        countdownPanel = nil
        importantRows.removeAll()
        countdownRows.removeAll()
        layoutEditing = false
    }

    private func renderImportant() {
        guard !suspended, !importantRows.isEmpty || layoutEditing else {
            importantPanel?.close()
            importantPanel = nil
            return
        }
        let panel = importantPanel ?? makePanel(size: NSSize(width: preferences.importantWidth, height: preferences.importantHeight), interactive: true)
        let rows = importantRows.isEmpty && layoutEditing
            ? [ImportantRow(id: "preview", appName: "WinTaskbar", title: NSLocalizedString("Important message", comment: "Layout preview"), body: NSLocalizedString("Messages appear here.", comment: "Layout preview"), receivedAt: Date())]
            : importantRows
        let view = NotificationImportantOverlay(rows: rows, icons: rows.map { appIcon($0.appName) },
            editing: layoutEditing, onOpen: { [weak self] id in self?.onImportantOpen?(id) },
            onDismiss: { [weak self] id in
                guard id != "preview" else { return }
                self?.onImportantDismiss?(id)
            }, onClear: { [weak self] in self?.onImportantClear?() },
            onMove: { [weak self] in self?.saveImportantPosition() },
            onResize: { [weak self] delta, ended in self?.resizeImportant(delta: delta, ended: ended) })
        let width = CGFloat(preferences.importantWidth)
        let visibleFrame = (panel.screen ?? NSScreen.screens.first)?.visibleFrame
        let screenHeight = visibleFrame?.height ?? CGFloat(preferences.importantHeight)
        let defaultHeight = min(CGFloat(preferences.importantHeight), screenHeight)
        let height = layoutEditing ? defaultHeight
            : importantHeight(view, width: width, defaultHeight: defaultHeight, screenHeight: screenHeight)
        let top = panel.frame.maxY
        let bottom = max(top - height, visibleFrame?.minY ?? top - height)
        let left = visibleFrame.map { min(max(panel.frame.minX, $0.minX), $0.maxX - width) } ?? panel.frame.minX
        panel.setFrame(NSRect(x: left, y: bottom, width: width, height: height), display: true)
        if let hosting = panel.contentView as? NSHostingView<NotificationImportantOverlay> {
            hosting.rootView = view
        } else {
            panel.contentView = NSHostingView(rootView: view)
        }
        if importantPanel == nil { position(panel, kind: .important) }
        importantPanel = panel
        panel.orderFrontRegardless()
    }

    private func importantHeight(_ view: NotificationImportantOverlay, width: CGFloat,
                                 defaultHeight: CGFloat, screenHeight: CGFloat) -> CGFloat {
        func height(for count: Int) -> CGFloat {
            var measuredView = view
            measuredView.measuring = true
            measuredView.measuredRowCount = count
            let measurement = NSHostingView(rootView: measuredView.frame(width: width).fixedSize(horizontal: false, vertical: true))
            return ceil(measurement.fittingSize.height)
        }

        // Measure real wrapped rows; always round from the configured height, never the current frame.
        var lower = 1
        var upper = view.rows.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if height(for: middle) < defaultHeight { lower = middle + 1 } else { upper = middle }
        }
        let roundedHeight = height(for: lower)
        // If rounding would leave the screen, stop at the previous complete row. A single
        // oversized message still needs scrolling within the available screen height.
        let fittingHeight = roundedHeight <= screenHeight ? roundedHeight : height(for: max(1, lower - 1))
        return min(screenHeight, fittingHeight)
    }

    private func renderCountdown() {
        guard !suspended, !countdownRows.isEmpty || layoutEditing else {
            countdownPanel?.close()
            countdownPanel = nil
            return
        }
        let maxHeight = (NSScreen.screens.first?.visibleFrame.height ?? 800) * 0.55
        let initialHeight = min(maxHeight, CGFloat(max(1, countdownRows.count)) * 75 + 12)
        let panel = countdownPanel ?? makePanel(size: NSSize(width: 390, height: initialHeight), interactive: true)
        let rows = countdownRows.isEmpty && layoutEditing
            ? [CountdownRow(id: "preview", title: NSLocalizedString("Countdown", comment: "Layout preview"), deadline: ProcessInfo.processInfo.systemUptime + 45, duration: 60, color: .systemBlue)]
            : countdownRows
        let height = min(maxHeight, CGFloat(rows.count) * 75 + 12)
        if panel.frame.height != height { panel.setContentSize(NSSize(width: 390, height: height)) }
        panel.contentView = NSHostingView(rootView: NotificationCountdownOverlay(rows: rows, editing: layoutEditing,
            onDismiss: { [weak self] id in
                guard id != "preview" else { return }
                self?.onCountdownDismiss?(id)
            }, onMove: { [weak self] delta, ended in self?.move(.countdown, delta: delta, ended: ended) }))
        if countdownPanel == nil { position(panel, kind: .countdown) }
        countdownPanel = panel
        panel.orderFrontRegardless()
    }

    private func makePanel(size: NSSize, interactive: Bool) -> NotificationAlertPanel {
        let panel = NotificationAlertPanel(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.canReceiveKeys = interactive
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = interactive
        panel.ignoresMouseEvents = !interactive
        panel.hidesOnDeactivate = false
        applyLevel(to: panel)
        return panel
    }

    private func applyLevel(to panel: NSPanel) {
        panel.level = preferences.alwaysOnTop ? .statusBar : .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if preferences.showInFullscreen { panel.collectionBehavior.insert(.fullScreenAuxiliary) }
    }

    private func position(_ panel: NSPanel, kind: PanelKind) {
        guard let screen = NSScreen.screens.first else { return }
        let point: NSPoint
        switch kind {
        case .center: point = NSPoint(x: preferences.centerX, y: preferences.centerY)
        case .large: point = NSPoint(x: preferences.largeX, y: preferences.largeY)
        case .countdown: point = NSPoint(x: preferences.countdownX, y: preferences.countdownY)
        case .important: point = NSPoint(x: preferences.importantX, y: preferences.importantY)
        }
        let frame = screen.visibleFrame
        let x = frame.minX + point.x * frame.width - panel.frame.width / 2
        let y = frame.minY + point.y * frame.height - panel.frame.height / 2
        panel.setFrameOrigin(NSPoint(x: min(max(x, frame.minX), frame.maxX - panel.frame.width),
                                     y: min(max(y, frame.minY), frame.maxY - panel.frame.height)))
    }

    private func move(_ kind: PanelKind, delta: CGSize, ended: Bool) {
        guard layoutEditing || kind == .important, let panel = panel(for: kind), let screen = NSScreen.screens.first else { return }
        let mouse = NSEvent.mouseLocation
        if moveSession?.panel !== panel {
            moveSession = LayoutPointerSession(panel: panel, firstTranslation: delta, mouse: mouse)
        }
        guard let session = moveSession else { return }
        let displacement = session.displacement(to: mouse)
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: min(max(session.frame.minX + displacement.x, frame.minX), frame.maxX - panel.frame.width),
                                     y: min(max(session.frame.minY + displacement.y, frame.minY), frame.maxY - panel.frame.height)))
        guard ended else { return }
        moveSession = nil
        let x = (panel.frame.midX - frame.minX) / frame.width
        let y = (panel.frame.midY - frame.minY) / frame.height
        switch kind {
        case .center: preferences.centerX = x; preferences.centerY = y
        case .large: preferences.largeX = x; preferences.largeY = y
        case .countdown: preferences.countdownX = x; preferences.countdownY = y
        case .important: preferences.importantX = x; preferences.importantY = y
        }
        onLayoutChanged?(preferences)
    }

    private func saveImportantPosition() {
        guard let panel = importantPanel, let screen = NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        preferences.importantX = (panel.frame.midX - frame.minX) / frame.width
        preferences.importantY = (panel.frame.midY - frame.minY) / frame.height
        onLayoutChanged?(preferences)
    }

    private func resizeImportant(delta: CGSize, ended: Bool) {
        guard layoutEditing, let panel = importantPanel, let screen = NSScreen.screens.first else { return }
        let mouse = NSEvent.mouseLocation
        if resizeSession?.panel !== panel {
            resizeSession = LayoutPointerSession(panel: panel, firstTranslation: delta, mouse: mouse)
        }
        guard let session = resizeSession else { return }
        let start = session.frame
        let displacement = session.displacement(to: mouse)
        let size = NSSize(width: min(800, max(240, start.width + displacement.x)),
                          height: min(700, max(150, start.height - displacement.y)))
        panel.setFrame(NSRect(x: start.minX, y: start.maxY - size.height,
                              width: size.width, height: size.height), display: true)
        guard ended else { return }
        resizeSession = nil
        preferences.importantWidth = size.width
        preferences.importantHeight = size.height
        let frame = screen.visibleFrame
        preferences.importantX = (panel.frame.midX - frame.minX) / frame.width
        preferences.importantY = (panel.frame.midY - frame.minY) / frame.height
        onLayoutChanged?(preferences)
    }

    private func panel(for kind: PanelKind) -> NSPanel? {
        switch kind {
        case .center: return textPanels[.center]
        case .large: return textPanels[.large]
        case .countdown: return countdownPanel
        case .important: return importantPanel
        }
    }

    private func textSize(_ text: String, kind: TextKind) -> NSSize {
        let large = kind == .large
        let width = NotificationTextLayout.width(
            text: NotificationTextPresentation.displayText(text),
            fontSize: large ? preferences.largeFontSize : preferences.centerFontSize,
            maximum: large ? preferences.largeMaximumWidth : preferences.centerMaximumWidth,
            screenWidth: NSScreen.screens.first?.visibleFrame.width ?? 900,
            large: large, editing: layoutEditing)
        return NSSize(width: width, height: NotificationTextLayout.height(
            fontSize: large ? preferences.largeFontSize : preferences.centerFontSize, large: large))
    }

    private func saveTextLayout(_ kind: TextKind, frame: NSRect) {
        guard layoutEditing, let screen = NSScreen.screens.first else { return }
        let bounds = screen.visibleFrame
        let x = (frame.midX - bounds.minX) / bounds.width
        let y = (frame.midY - bounds.minY) / bounds.height
        if kind == .large {
            preferences.largeMaximumWidth = frame.width
            preferences.largeX = x
            preferences.largeY = y
        } else {
            preferences.centerMaximumWidth = frame.width
            preferences.centerX = x
            preferences.centerY = y
        }
        onLayoutChanged?(preferences)
    }

    private func textOverlay(_ text: String, color: NSColor, kind: TextKind) -> NotificationTextOverlay {
        NotificationTextOverlay(text: NotificationTextPresentation.displayText(text), color: Color(nsColor: color),
            fontSize: CGFloat(kind == .large ? preferences.largeFontSize : preferences.centerFontSize),
            large: kind == .large, editing: layoutEditing, onLayoutCommit: { [weak self] frame in
                self?.saveTextLayout(kind, frame: frame)
            })
    }

    func openSourceApplication(_ name: String) {
        let candidates = (sourceApps.runningApps + sourceApps.installedApps).map { app in
            let bundle = Bundle(url: app.url)
            let aliases = [app.name, app.url.deletingPathExtension().lastPathComponent]
                + ["CFBundleDisplayName", "CFBundleName"].flatMap { key in
                    [bundle?.object(forInfoDictionaryKey: key) as? String, bundle?.infoDictionary?[key] as? String].compactMap { $0 }
                }
            return NotificationSourceApplicationPolicy.Candidate(url: app.url, names: aliases)
        }
        guard let url = NotificationSourceApplicationPolicy.applicationURL(named: name, candidates: candidates) else {
            showSourceOpenError()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
            if error != nil { Task { @MainActor in self?.showSourceOpenError() } }
        }
    }

    private func showSourceOpenError() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Could not open the source app", comment: "Notification source")
        alert.informativeText = NSLocalizedString("The source app is unavailable or its name matches more than one app. Open it manually.", comment: "Notification source")
        if let importantPanel, importantPanel.isVisible {
            alert.beginSheetModal(for: importantPanel)
        } else {
            alert.runModal()
        }
    }

    private func appIcon(_ name: String) -> NSImage {
        NSWorkspace.shared.runningApplications.first {
            $0.localizedName?.localizedCaseInsensitiveCompare(name) == .orderedSame
        }?.icon ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil) ?? NSImage()
    }
}

private final class NotificationAlertPanel: NSPanel {
    var canReceiveKeys = false
    override var canBecomeKey: Bool { canReceiveKeys }
    override var canBecomeMain: Bool { false }
}

private struct NotificationTextOverlay: View {
    let text: String
    let color: Color
    let fontSize: CGFloat
    let large: Bool
    let editing: Bool
    let onLayoutCommit: (NSRect) -> Void

    var body: some View {
        Text(text)
            .font(Font(NotificationTextLayout.font(size: fontSize)))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 24)
            .padding(.vertical, large ? 16 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .shadow(color: .black.opacity(0.8), radius: large ? 8 : 0)
            .background {
                if !large { RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial) }
            }
            .padding(4)
            .overlay {
                if editing {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.tint, style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
                        .padding(4)
                        .overlay {
                            HStack {
                                Image(systemName: "arrow.left.and.right")
                                Spacer()
                                Image(systemName: "arrow.left.and.right")
                            }
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 4)
                        }
                        .allowsHitTesting(false)
                    NotificationTextFrameEditor(minimumWidth: NotificationTextLayout.minimumWidth(large: large),
                                                onCommit: onLayoutCommit)
                }
            }
    }
}

private struct NotificationTextFrameEditor: NSViewRepresentable {
    let minimumWidth: CGFloat
    let onCommit: (NSRect) -> Void

    func makeNSView(context: Context) -> Editor { Editor() }

    func updateNSView(_ view: Editor, context: Context) {
        view.minimumWidth = minimumWidth
        view.onCommit = onCommit
    }

    final class Editor: NSView {
        var minimumWidth: CGFloat = 240
        var onCommit: ((NSRect) -> Void)?
        private var start: (frame: NSRect, mouse: NSPoint, mode: NotificationTextLayout.DragMode)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
            addCursorRect(NSRect(x: 0, y: 0, width: 16, height: bounds.height), cursor: .resizeLeftRight)
            addCursorRect(NSRect(x: bounds.maxX - 16, y: 0, width: 16, height: bounds.height), cursor: .resizeLeftRight)
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            let point = convert(event.locationInWindow, from: nil)
            let mode: NotificationTextLayout.DragMode = point.x <= 16 ? .left
                : point.x >= bounds.width - 16 ? .right : .move
            start = (window.frame, window.convertPoint(toScreen: event.locationInWindow), mode)
        }

        override func mouseDragged(with event: NSEvent) { updateDrag(event) }

        override func mouseUp(with event: NSEvent) {
            guard start != nil, let window else { return }
            updateDrag(event)
            start = nil
            onCommit?(window.frame)
        }

        private func updateDrag(_ event: NSEvent) {
            guard let start, let window, let screen = window.screen else { return }
            let point = window.convertPoint(toScreen: event.locationInWindow)
            let delta = NSPoint(x: point.x - start.mouse.x, y: point.y - start.mouse.y)
            window.setFrame(NotificationTextLayout.draggedFrame(start: start.frame, delta: delta, mode: start.mode,
                                                                minimumWidth: minimumWidth, screen: screen.visibleFrame),
                            display: true)
        }
    }
}

private extension VerticalAlignment {
    enum ImportantMessageHeader: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[VerticalAlignment.center] }
    }

    static let importantMessageHeader = VerticalAlignment(ImportantMessageHeader.self)
}

private struct NotificationImportantOverlay: View {
    let rows: [NotificationAlertPresenter.ImportantRow]
    let icons: [NSImage]
    let editing: Bool
    var measuring = false
    var measuredRowCount: Int?
    let onOpen: (String) -> Void
    let onDismiss: (String) -> Void
    let onClear: () -> Void
    let onMove: () -> Void
    let onResize: (CGSize, Bool) -> Void
    @State private var hoveredRowID: String?
    @State private var hoverLocation: CGPoint?
    @State private var rowFrames: [String: CGRect] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack {
                    Text(NSLocalizedString("Important messages", comment: "Notification list title"))
                        .font(.headline)
                    Spacer()
                }
                .padding(12)
                .overlay(NotificationImportantTitleDrag(onMoved: onMove))
                if !editing {
                    Button(NSLocalizedString("Clear all", comment: "Clear important messages"), action: onClear)
                        .buttonStyle(.plain)
                        .padding(.trailing, 12)
                }
            }
            Divider()
            if measuring {
                messageList
            } else {
                ScrollView {
                    messageList.background(NotificationImportantScrollStyle())
                }
                .coordinateSpace(name: "importantMessageList")
                .onContinuousHover(coordinateSpace: .named("importantMessageList")) { phase in
                    switch phase {
                    case .active(let location): hoverLocation = location
                    case .ended: hoverLocation = nil
                    }
                    updateHoveredRow()
                }
                .onPreferenceChange(NotificationImportantRowFrames.self) { frames in
                    rowFrames = frames
                    updateHoveredRow()
                }
            }
            if editing {
                HStack {
                    Spacer()
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .padding(8)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 1)
                            .onChanged { onResize($0.translation, false) }
                            .onEnded { onResize($0.translation, true) })
                }
            }
        }
        .foregroundStyle(.primary)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(4)
    }

    private var messageList: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.prefix(measuredRowCount ?? rows.count).enumerated()), id: \.element.id) { index, row in
                let showsClose = !editing && hoveredRowID == row.id
                ZStack(alignment: Alignment(horizontal: .trailing, vertical: .importantMessageHeader)) {
                    Button { onOpen(row.id) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(nsImage: icons[index]).resizable().frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(alignment: .center, spacing: 8) {
                                    Text(row.title.isEmpty ? row.appName : row.title)
                                        .font(.system(size: 13, weight: .semibold)).lineLimit(2)
                                    Spacer(minLength: 0)
                                    Text(row.receivedAt, format: .dateTime.hour().minute().second())
                                        .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                                        .fixedSize()
                                        .alignmentGuide(.importantMessageHeader) {
                                            // Align the close glyph to the digits, excluding the font's descender space.
                                            $0[.firstTextBaseline] - NSFont.systemFont(ofSize: 10).capHeight / 2
                                        }
                                        .help(row.receivedAt.formatted(date: .complete, time: .standard))
                                        .opacity(showsClose ? 0 : 1)
                                        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: showsClose)
                                }
                                if !row.body.isEmpty { Text(row.body).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true) }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                        .padding(.leading, 12)
                        .padding(.trailing, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(NotificationImportantButtonStyle())
                    .disabled(editing)
                    .help("Open notification, then remove this item. Falls back to the source app if needed.")
                    .accessibilityAction(named: Text("Remove message")) { if !editing { onDismiss(row.id) } }
                    if !editing {
                        Button { onDismiss(row.id) } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                                .offset(y: -1)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(NSLocalizedString("Remove message", comment: "Remove important message"))
                        .padding(.trailing, 12)
                        .alignmentGuide(.importantMessageHeader) { $0[VerticalAlignment.center] }
                        .opacity(showsClose ? 1 : 0)
                        .allowsHitTesting(showsClose)
                        .accessibilityHidden(!showsClose)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: showsClose)
                    }
                }
                .background {
                    if !measuring {
                        GeometryReader { geometry in
                            Color.clear.preference(key: NotificationImportantRowFrames.self,
                                                   value: [row.id: geometry.frame(in: .named("importantMessageList"))])
                        }
                    }
                }
                if index < (measuredRowCount ?? rows.count) - 1 { Divider().padding(.leading, 50) }
            }
        }
    }

    private func updateHoveredRow() {
        // Both the pointer and row bounds use the stationary scroll viewport's coordinates.
        // Re-evaluate after layout even when the pointer has not moved.
        hoveredRowID = hoverLocation.flatMap { point in
            rows.first { rowFrames[$0.id]?.contains(point) == true }?.id
        }
    }
}

private struct NotificationImportantRowFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct NotificationImportantButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Feedback(configuration: configuration)
    }

    private struct Feedback: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .background(.primary.opacity(isEnabled ? (configuration.isPressed ? 0.14 : hovered ? 0.07 : 0) : 0),
                            in: RoundedRectangle(cornerRadius: 6))
                .onHover { hovered = $0 }
        }
    }
}

private struct NotificationImportantTitleDrag: NSViewRepresentable {
    let onMoved: () -> Void

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.onMoved = onMoved
        return view
    }

    func updateNSView(_ nsView: DragView, context: Context) { nsView.onMoved = onMoved }

    final class DragView: NSView {
        var onMoved: (() -> Void)?
        private var start: (frame: NSRect, mouse: NSPoint)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            start = (window.frame, window.convertPoint(toScreen: event.locationInWindow))
        }

        override func mouseDragged(with event: NSEvent) { updateDrag(event) }

        override func mouseUp(with event: NSEvent) {
            guard start != nil else { return }
            updateDrag(event)
            start = nil
            onMoved?()
        }

        private func updateDrag(_ event: NSEvent) {
            guard let start, let window, let screen = window.screen else { return }
            // Use the event's screen position, not the live pointer, which may belong to
            // another input source or have advanced while the event was queued.
            let mouse = window.convertPoint(toScreen: event.locationInWindow)
            let area = screen.visibleFrame
            let x = start.frame.minX + mouse.x - start.mouse.x
            let y = start.frame.minY + mouse.y - start.mouse.y
            window.setFrameOrigin(NSPoint(x: min(max(x, area.minX), area.maxX - window.frame.width),
                                          y: min(max(y, area.minY), area.maxY - window.frame.height)))
        }
    }
}

private struct NotificationImportantScrollStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ nsView: Probe, context: Context) { nsView.configure() }

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configure()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func configure() {
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let scrollView = self?.enclosingScrollView else { return }
                scrollView.scrollerStyle = .overlay
                scrollView.autohidesScrollers = true
                scrollView.hasHorizontalScroller = false
                scrollView.verticalScroller?.controlSize = .small
            }
        }
    }
}

private struct NotificationCountdownOverlay: View {
    let rows: [NotificationAlertPresenter.CountdownRow]
    let editing: Bool
    let onDismiss: (String) -> Void
    let onMove: (CGSize, Bool) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        let remaining = max(0, row.deadline - ProcessInfo.processInfo.systemUptime)
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Image(systemName: "timer").foregroundStyle(Color(nsColor: row.color))
                                Text(row.title).lineLimit(1)
                                Spacer()
                                Text(timeString(remaining)).monospacedDigit()
                                Button { onDismiss(row.id) } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.plain)
                            }
                            ProgressView(value: max(0, min(1, remaining / max(1, row.duration))))
                                .tint(Color(nsColor: row.color))
                        }
                        .padding(12)
                        .contentShape(Rectangle())
                        .gesture(editing ? DragGesture(minimumDistance: 1)
                            .onChanged { onMove($0.translation, false) }
                            .onEnded { onMove($0.translation, true) } : nil)
                    }
                }
            }
            .font(.system(size: 13, weight: .medium))
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(4)
        }
    }

    private func timeString(_ interval: TimeInterval) -> String {
        let seconds = Int(ceil(interval))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
