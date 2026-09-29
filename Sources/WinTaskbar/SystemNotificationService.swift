import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI

@MainActor
final class SystemNotificationService: ObservableObject {
    static let shared = SystemNotificationService(preferences: .shared)
    @Published private(set) var isLayoutEditing = false
    @Published private(set) var systemBannerStatusKey: String?
    @Published private(set) var statusKey = "Notification capture is off."

    private struct Card {
        let id: UUID
        var content: SystemNotificationContent
        var renderedText: String?
        var behavior: NotificationDisplayBehavior
        var remaining: TimeInterval?

        var displayContent: SystemNotificationContent {
            SystemNotificationContent(sourceID: content.sourceID, appName: content.appName,
                                      title: content.title, body: renderedText ?? content.body)
        }
    }

    private let preferences: PreferencesStore
    private var configuration = NotificationPreferences()
    private var subscription: AnyCancellable?
    private let presenter = NotificationAlertPresenter()
    private var runtime = NotificationAlertRuntime()
    private var layoutSubscription: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
    private var captureTimer: Timer?
    private var expiryTimer: Timer?
    private let captureWorker = SystemNotificationCapture()
    private var dismissalAttempts: [String: (content: SystemNotificationContent, count: Int)] = [:]
    private var scanTask: Task<Void, Never>?
    private var generation = UUID()
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var suspended = false
    private var seen: [String: (content: SystemNotificationContent, time: TimeInterval)] = [:]
    private var cards: [Card] = []
    private var panels: [UUID: NSPanel] = [:]
    private var hovered: Set<UUID> = []
    private var expanded: Set<UUID> = []

    init(preferences: PreferencesStore) { self.preferences = preferences }

    func start() {
        guard subscription == nil else { return }
        presenter.onImportantDismiss = { [weak self] id in
            self?.runtime.removeImportant(id)
            self?.syncAlertLists()
        }
        presenter.onImportantClear = { [weak self] in
            guard let self else { return }
            for item in self.runtime.important { self.runtime.removeImportant(item.id) }
            self.syncAlertLists()
        }
        presenter.onCountdownDismiss = { [weak self] id in
            self?.runtime.removeCountdown(id)
            self?.syncAlertLists()
            self?.updateExpiryTimer()
        }
        presenter.onLayoutChanged = { [weak self] value in
            self?.preferences.notifications.presentation = value
        }
        subscription = preferences.$notifications.sink { [weak self] in self?.configure($0) }
        layoutSubscription = Publishers.CombineLatest4(
            preferences.$taskbarEnabled, preferences.$position, preferences.$barHeight, preferences.$theme
        ).dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.layout() }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated {
            guard let self else { return }
            self.presenter.configure(self.configuration.presentation)
            self.syncAlertLists()
            self.layout()
        } })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.suspended = true
                    self?.scanTask?.cancel()
                    self?.presenter.setSuspended(true)
                    self?.panels.values.forEach { $0.orderOut(nil) }
                }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.suspended = false
                    self?.lastTick = ProcessInfo.processInfo.systemUptime
                    self?.presenter.setSuspended(false)
                    self?.tick()
                    self?.layout()
                }
            })
        }
    }

    func stop() {
        subscription = nil
        layoutSubscription = nil
        captureTimer?.invalidate()
        captureTimer = nil
        generation = UUID()
        scanTask?.cancel()
        dismissalAttempts.removeAll()
        systemBannerStatusKey = nil
        clearAllAlerts()
        seen.removeAll()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func configure(_ value: NotificationPreferences) {
        let changedEnabled = configuration.enabled != value.enabled
        let changedRules = configuration.rules != value.rules || configuration.fallback != value.fallback
            || configuration.outputDefaults != value.outputDefaults
        configuration = value
        if changedEnabled || changedRules {
            generation = UUID()
            scanTask?.cancel()
            dismissalAttempts.removeAll()
            systemBannerStatusKey = nil
        }
        if changedRules {
            cards = cards.compactMap { card in
                guard !card.content.sourceID.hasPrefix("preview:") else { return card }
                let plan = value.plan(for: card.content)
                let outputs = plan.outputs
                guard outputs.enabled.contains(.card), outputs.settings(for: .card).card.mode != .hidden else { return nil }
                var updated = card
                updated.renderedText = outputs.settings(for: .card).textTemplate.isEmpty ? nil : plan.text(for: .card)
                if updated.behavior != outputs.settings(for: .card).card {
                    updated.behavior = outputs.settings(for: .card).card
                    updated.remaining = nil
                }
                return updated
            }
        }
        if changedEnabled { clearAllAlerts() }
        presenter.configure(value.presentation)
        if !value.enabled {
            captureTimer?.invalidate()
            captureTimer = nil
            generation = UUID()
            seen.removeAll()
            statusKey = "Notification capture is off."
        } else if captureTimer == nil {
            let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.capture() }
            }
            captureTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            capture()
        }
        layout()
    }

    private func capture() {
        guard configuration.enabled, !suspended, scanTask == nil else { return }
        guard AXIsProcessTrusted() else {
            statusKey = "Accessibility access is required to capture notifications."
            return
        }
        let currentGeneration = generation
        let rules = configuration
        let worker = captureWorker
        scanTask = Task { [weak self] in
            let result = await worker.scan()
            guard let self else { return }
            defer { self.scanTask = nil }
            guard !Task.isCancelled, self.configuration == rules,
                  self.generation == currentGeneration, !self.suspended else { return }
            self.statusKey = result.unreadable ? "Some notification content could not be read. Check Accessibility access."
                : result.unrecognized ? "A notification layout was not recognized."
                : "Listening for system notification banners."
            let now = ProcessInfo.processInfo.systemUptime
            self.seen = self.seen.filter { now - $0.value.time < 600 }
            self.dismissalAttempts = self.dismissalAttempts.filter { self.seen[$0.key] != nil }
            var dismissalFailed = false
            var dismissalSucceeded = false
            for content in result.notifications {
                guard !Task.isCancelled, self.configuration == rules,
                      self.generation == currentGeneration, !self.suspended else { return }
                let previous = self.seen[content.sourceID]?.content
                self.seen[content.sourceID] = (content, now)
                let plan = rules.plan(for: content)
                if previous != content {
                    if !plan.outputs.enabled.contains(.card) || plan.outputs.settings(for: .card).card.mode == .hidden {
                        self.cards.removeAll { $0.content.sourceID == content.sourceID }
                        self.layout()
                    }
                    self.receive(plan, now: now)
                }
                guard plan.outputs.dismissSystemNotification else { continue }
                let attempt = self.dismissalAttempts[content.sourceID]
                let count = attempt?.content == content ? attempt?.count ?? 0 : 0
                guard count < 3 else { continue }
                guard let token = result.dismissalTokens[content.sourceID] else {
                    dismissalFailed = true
                    continue
                }
                self.dismissalAttempts[content.sourceID] = (content, count + 1)
                let outcome = await worker.dismiss(token, expected: content)
                guard !Task.isCancelled, self.configuration == rules,
                      self.generation == currentGeneration, !self.suspended else { return }
                switch outcome {
                case .closed:
                    self.dismissalAttempts[content.sourceID] = (content, 3)
                    dismissalSucceeded = true
                case .unsupported, .failed: dismissalFailed = true
                case .changed, .cancelled: break
                }
            }
            if dismissalFailed {
                self.systemBannerStatusKey = "Some original macOS notifications could not be closed. They have been left visible."
            } else if dismissalSucceeded {
                self.systemBannerStatusKey = nil
            }
        }
    }

    func showPreview(outputs: NotificationOutputs? = nil) {
        var value = outputs ?? configuration.fallback
        value.cooldownSeconds = 0
        let content = SystemNotificationContent(
            sourceID: "preview:" + UUID().uuidString, appName: "WinTaskbar",
            title: NSLocalizedString("Notification preview", comment: "Notification sample"),
            body: NSLocalizedString("Preview message. Alerts stay in memory and disappear when WinTaskbar quits.", comment: "Notification sample")
        )
        var preview = configuration
        preview.rules = []
        preview.fallback = value
        receive(preview.plan(for: content), now: ProcessInfo.processInfo.systemUptime)
    }

    func showOutputPreview(_ kind: NotificationOutputKind) {
        var outputs = NotificationOutputs(enabled: [kind])
        if kind == .countdown {
            var settings = configuration.outputDefaults[.countdown] ?? NotificationOutputSettings()
            settings.countdownPattern = ""
            settings.completionOutputs = []
            outputs.overrides[.countdown] = settings
        }
        showPreview(outputs: outputs)
    }

    func beginLayoutEditing() {
        isLayoutEditing = true
        presenter.setLayoutEditing(true)
    }

    func endLayoutEditing() {
        isLayoutEditing = false
        presenter.setLayoutEditing(false)
    }

    private func receive(_ plan: NotificationAlertPlan, now: TimeInterval) {
        let accepted = runtime.ingest(plan, now: now)
        if accepted { deliver(plan) }
        syncAlertLists()
        updateExpiryTimer()
    }

    private func deliver(_ plan: NotificationAlertPlan) {
        let outputs = plan.outputs
        let content = plan.content
        if outputs.enabled.contains(.card), outputs.settings(for: .card).card.mode != .hidden {
            if let index = cards.firstIndex(where: { $0.content.sourceID == content.sourceID }) {
                cards[index].content = content
                cards[index].renderedText = outputs.settings(for: .card).textTemplate.isEmpty ? nil : plan.text(for: .card)
                cards[index].behavior = outputs.settings(for: .card).card
                cards[index].remaining = nil
            } else {
                cards.append(Card(id: UUID(), content: content,
                                  renderedText: outputs.settings(for: .card).textTemplate.isEmpty ? nil : plan.text(for: .card),
                                  behavior: outputs.settings(for: .card).card, remaining: nil))
            }
        }
        for kind in [NotificationOutputKind.centerText, .largeText, .glow] where outputs.enabled.contains(kind) {
            let settings = outputs.settings(for: kind)
            let color = NSColor(hex: settings.colorHex) ?? NotificationGlow.defaultColor
            let duration = min(3600, max(0.5, settings.durationSeconds))
            if kind == .glow {
                presenter.showGlow(color: color, duration: duration)
            } else {
                presenter.showText(plan.text(for: kind), large: kind == .largeText, color: color, duration: duration)
            }
        }
        if outputs.enabled.contains(.sound) {
            let settings = outputs.settings(for: .sound)
            presenter.playSound(named: settings.soundName, speech: settings.speechEnabled ? plan.text(for: .sound) : nil)
        }
        layout()
    }

    private func syncAlertLists() {
        presenter.setImportant(runtime.important.map {
            NotificationAlertPresenter.ImportantRow(id: $0.id, appName: $0.content.appName,
                                                     title: $0.content.title, body: $0.text)
        })
        presenter.setCountdown(runtime.countdowns.map {
            NotificationAlertPresenter.CountdownRow(id: $0.id, title: $0.text, deadline: $0.deadline, duration: $0.duration,
                                                     color: NSColor(hex: $0.colorHex) ?? NotificationGlow.defaultColor)
        })
    }

    func clearAllAlerts() {
        endLayoutEditing()
        runtime.clear()
        presenter.stop()
        clearCards()
    }

    func clearCards() {
        cards.removeAll()
        panels.values.forEach { $0.close() }
        panels.removeAll()
        hovered.removeAll()
        expanded.removeAll()
        updateExpiryTimer()
    }

    private func dismiss(_ id: UUID) {
        cards.removeAll { $0.id == id }
        layout()
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastTick
        lastTick = now
        guard !suspended else { return }
        for index in cards.indices where panels[cards[index].id] != nil && !hovered.contains(cards[index].id) {
            if let remaining = cards[index].remaining { cards[index].remaining = remaining - elapsed }
        }
        let count = cards.count
        cards.removeAll { $0.remaining.map { $0 <= 0 } ?? false }
        if cards.count != count { layout() }
        let completed = runtime.tick(now: now)
        for plan in completed { receive(plan, now: now) }
        if !completed.isEmpty { syncAlertLists() }
        updateExpiryTimer()
    }

    private func layout() {
        guard !suspended, let screen = NSScreen.screens.first else { return }
        var area = screen.visibleFrame
        if preferences.taskbarEnabled {
            if preferences.position == .bottom {
                let bottom = max(area.minY, screen.frame.minY + preferences.barHeight)
                area.size.height = max(0, area.maxY - bottom)
                area.origin.y = bottom
            } else if preferences.position == .right {
                area.size.width = max(0, min(area.maxX, screen.frame.maxX - preferences.barHeight) - area.minX)
            }
        }
        let gap: CGFloat = 12
        let width = min(400, max(240, area.width - gap * 2))
        let maxHeight = min(420, area.height - gap * 2)
        expanded.formIntersection(cards.map(\.id))
        var visible: [(card: Card, metrics: NotificationCardMetrics)] = []
        var usedHeight: CGFloat = gap
        for card in cards.reversed() {
            let availableHeight = area.height - usedHeight - gap
            let compact = NotificationCardMetrics.measure(card.displayContent, width: width, maxHeight: maxHeight, expanded: false)
            guard compact.height <= availableHeight else { break }
            // Expanding the top card must keep it visible; scroll within the remaining screen space.
            let metrics = expanded.contains(card.id)
                ? NotificationCardMetrics.measure(card.displayContent, width: width, maxHeight: min(maxHeight, availableHeight), expanded: true)
                : compact
            visible.append((card, metrics))
            usedHeight += metrics.height + gap
        }
        let visibleIDs = Set(visible.map { $0.card.id })
        for id in Array(panels.keys) where !visibleIDs.contains(id) {
            panels.removeValue(forKey: id)?.close()
            hovered.remove(id)
        }
        let runningApps = NSWorkspace.shared.runningApplications
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var bottom = area.minY + gap
        for (slot, entry) in visible.enumerated() {
            let card = entry.card
            let panel: NSPanel
            let isNew = panels[card.id] == nil
            if let existing = panels[card.id] {
                panel = existing
            } else {
                panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                panel.hidesOnDeactivate = false
                panel.isFloatingPanel = true
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = true
                panel.animationBehavior = .none
                panels[card.id] = panel
            }
            if let index = cards.firstIndex(where: { $0.id == card.id }), cards[index].remaining == nil {
                cards[index].remaining = card.behavior.duration
            }
            panel.level = configuration.presentation.alwaysOnTop ? .floating : .normal
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            if configuration.presentation.showInFullscreen { panel.collectionBehavior.insert(.fullScreenAuxiliary) }
            panel.appearance = preferences.theme == .dark ? NSAppearance(named: .darkAqua)
                : preferences.theme == .light ? NSAppearance(named: .aqua) : nil
            let view = NotificationCardView(
                content: card.displayContent,
                icon: runningApps.first { $0.localizedName?.localizedCaseInsensitiveCompare(card.content.appName) == .orderedSame }?.icon,
                width: width, metrics: entry.metrics, expanded: expanded.contains(card.id),
                queued: slot == visible.count - 1 ? max(0, cards.count - visible.count) : 0,
                toggleExpanded: { [weak self] in
                    guard let self else { return }
                    if !self.expanded.insert(card.id).inserted { self.expanded.remove(card.id) }
                    self.layout()
                },
                dismiss: { [weak self] in self?.dismiss(card.id) },
                clearAll: { [weak self] in self?.clearCards() },
                hover: { [weak self] inside in
                    if inside { self?.hovered.insert(card.id) } else { self?.hovered.remove(card.id) }
                }
            )
            if let hosting = panel.contentView as? NSHostingView<NotificationCardView> {
                hosting.rootView = view
            } else {
                panel.contentView = NSHostingView(rootView: view)
            }
            let targetFrame = NSRect(x: area.maxX - width - gap, y: bottom, width: width, height: entry.metrics.height)
            if reduceMotion || (!isNew && !panel.isVisible) {
                panel.setFrame(targetFrame, display: true)
                panel.alphaValue = 1
                panel.orderFrontRegardless()
            } else {
                if isNew {
                    panel.setFrame(targetFrame.offsetBy(dx: width + gap, dy: 0), display: true)
                    panel.alphaValue = 0
                    panel.orderFrontRegardless()
                }
                if isNew || panel.frame != targetFrame {
                    NSAnimationContext.runAnimationGroup { context in
                        // Fluent motion: direct entrance vs. point-to-point movement of existing cards.
                        context.duration = isNew ? 0.333 : 0.250
                        context.timingFunction = isNew
                            ? CAMediaTimingFunction(controlPoints: 0, 0, 0, 1)
                            : CAMediaTimingFunction(controlPoints: 0.55, 0.55, 0, 1)
                        panel.animator().setFrame(targetFrame, display: true)
                        if isNew { panel.animator().alphaValue = 1 }
                    }
                }
            }
            bottom += entry.metrics.height + gap
        }
        updateExpiryTimer()
    }

    private func updateExpiryTimer() {
        if cards.isEmpty && runtime.countdowns.isEmpty {
            expiryTimer?.invalidate()
            expiryTimer = nil
        } else if expiryTimer == nil {
            lastTick = ProcessInfo.processInfo.systemUptime
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            expiryTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }
}
