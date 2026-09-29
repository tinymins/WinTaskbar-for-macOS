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
    }

    struct CountdownRow: Identifiable {
        let id: String
        let title: String
        let deadline: TimeInterval // ProcessInfo.systemUptime
        let duration: TimeInterval
        let color: NSColor
    }

    var onImportantDismiss: ((String) -> Void)?
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
            if old.centerFontSize != value.centerFontSize || old.largeFontSize != value.largeFontSize,
               let content = textContents[kind] {
                panel.contentView = NSHostingView(rootView: textOverlay(content.text, color: content.color, kind: kind))
            }
            position(panel, kind: kind == .center ? .center : .large)
            applyLevel(to: panel)
        }
        if let importantPanel {
            if old.importantWidth != value.importantWidth || old.importantHeight != value.importantHeight {
                importantPanel.setContentSize(NSSize(width: value.importantWidth, height: value.importantHeight))
            }
            position(importantPanel, kind: .important)
            applyLevel(to: importantPanel)
        }
        if let countdownPanel { position(countdownPanel, kind: .countdown); applyLevel(to: countdownPanel) }
    }

    func showText(_ text: String, large: Bool, color: NSColor, duration: TimeInterval) {
        guard !suspended, let screen = NSScreen.screens.first else { return }
        let kind: TextKind = large ? .large : .center
        textTasks[kind]?.cancel()
        textPanels[kind]?.close()
        textContents[kind] = (text, color)
        let view = textOverlay(text, color: color, kind: kind)
        let size = NSSize(width: min(screen.visibleFrame.width * 0.8, large ? 900 : 620), height: large ? 170 : 90)
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
            ? [ImportantRow(id: "preview", appName: "WinTaskbar", title: NSLocalizedString("Important message", comment: "Layout preview"), body: NSLocalizedString("Messages appear here.", comment: "Layout preview"))]
            : importantRows
        let view = NotificationImportantOverlay(rows: rows, icons: rows.map { appIcon($0.appName) },
            editing: layoutEditing, onDismiss: { [weak self] id in
                guard id != "preview" else { return }
                self?.onImportantDismiss?(id)
            }, onClear: { [weak self] in self?.onImportantClear?() },
            onMove: { [weak self] delta, ended in self?.move(.important, delta: delta, ended: ended) },
            onResize: { [weak self] delta, ended in self?.resizeImportant(delta: delta, ended: ended) })
        panel.contentView = NSHostingView(rootView: view)
        if importantPanel == nil { position(panel, kind: .important) }
        importantPanel = panel
        panel.orderFrontRegardless()
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
        guard layoutEditing, let panel = panel(for: kind), let screen = NSScreen.screens.first else { return }
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

    private func textOverlay(_ text: String, color: NSColor, kind: TextKind) -> NotificationTextOverlay {
        NotificationTextOverlay(text: text, color: Color(nsColor: color),
            fontSize: CGFloat(kind == .large ? preferences.largeFontSize : preferences.centerFontSize),
            large: kind == .large, editing: layoutEditing, onMove: { [weak self] delta, ended in
                self?.move(kind == .large ? .large : .center, delta: delta, ended: ended)
            })
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
    let onMove: (CGSize, Bool) -> Void

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .shadow(color: .black.opacity(0.8), radius: large ? 8 : 0)
            .background {
                if !large { RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial) }
            }
            .padding(4)
            .contentShape(Rectangle())
            .gesture(editing ? DragGesture(minimumDistance: 1)
                .onChanged { onMove($0.translation, false) }
                .onEnded { onMove($0.translation, true) } : nil)
    }
}

private struct NotificationImportantOverlay: View {
    let rows: [NotificationAlertPresenter.ImportantRow]
    let icons: [NSImage]
    let editing: Bool
    let onDismiss: (String) -> Void
    let onClear: () -> Void
    let onMove: (CGSize, Bool) -> Void
    let onResize: (CGSize, Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(NSLocalizedString("Important messages", comment: "Notification list title"))
                    .font(.headline)
                Spacer()
                if !editing {
                    Button(NSLocalizedString("Clear all", comment: "Clear important messages"), action: onClear)
                        .buttonStyle(.plain)
                }
            }
            .padding(12)
            .contentShape(Rectangle())
            .gesture(editing ? DragGesture(minimumDistance: 1)
                .onChanged { onMove($0.translation, false) }
                .onEnded { onMove($0.translation, true) } : nil)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        HStack(alignment: .top, spacing: 10) {
                            Image(nsImage: icons[index]).resizable().frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.title.isEmpty ? row.appName : row.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                                if !row.body.isEmpty { Text(row.body).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true) }
                            }
                            Spacer(minLength: 0)
                            if !editing {
                                Button { onDismiss(row.id) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(NSLocalizedString("Remove message", comment: "Remove important message"))
                            }
                        }
                        .padding(12)
                        if index < rows.count - 1 { Divider().padding(.leading, 50) }
                    }
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
