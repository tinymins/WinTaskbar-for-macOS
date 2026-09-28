import AppKit
import ApplicationServices
import Combine
import SwiftUI

@MainActor
final class SystemNotificationService: ObservableObject {
    static let shared = SystemNotificationService(preferences: .shared)
    @Published private(set) var statusKey = "Notification capture is off."

    private struct Card {
        let id: UUID
        var content: SystemNotificationContent
        var behavior: NotificationDisplayBehavior
        var isPreview = false
        var remaining: TimeInterval?
    }

    private let preferences: PreferencesStore
    private var configuration = NotificationPreferences()
    private var subscription: AnyCancellable?
    private var layoutSubscription: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
    private var captureTimer: Timer?
    private var expiryTimer: Timer?
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
        subscription = preferences.$notifications.sink { [weak self] in self?.configure($0) }
        layoutSubscription = Publishers.CombineLatest4(
            preferences.$taskbarEnabled, preferences.$position, preferences.$barHeight, preferences.$theme
        ).dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.layout() }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.layout() } })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.suspended = true
                    self?.panels.values.forEach { $0.orderOut(nil) }
                }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.suspended = false
                    self?.lastTick = ProcessInfo.processInfo.systemUptime
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
        clearCards()
        seen.removeAll()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func configure(_ value: NotificationPreferences) {
        let changedEnabled = configuration.enabled != value.enabled
        configuration = value
        cards = cards.compactMap { card in
            var updated = card
            let behavior = card.isPreview ? value.fallback
                : value.behavior(app: card.content.appName, title: card.content.title, body: card.content.body)
            guard behavior.mode != .hidden else { return nil }
            if behavior != card.behavior {
                updated.behavior = behavior
                updated.remaining = nil
            }
            return updated
        }
        if !value.enabled {
            captureTimer?.invalidate()
            captureTimer = nil
            generation = UUID()
            seen.removeAll()
            if changedEnabled { clearCards() }
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
        scanTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                SystemNotificationCapture.scan()
            }.value
            guard let self else { return }
            self.scanTask = nil
            guard self.configuration == rules, self.generation == currentGeneration, !self.suspended else { return }
            self.statusKey = result.unreadable ? "Some notification content could not be read. Check Accessibility access."
                : result.unrecognized ? "A notification layout was not recognized."
                : "Listening for system notification banners."
            let now = ProcessInfo.processInfo.systemUptime
            self.seen = self.seen.filter { now - $0.value.time < 600 }
            var changed = false
            for content in result.notifications {
                let previous = self.seen[content.sourceID]?.content
                self.seen[content.sourceID] = (content, now)
                guard previous != content else { continue }
                let behavior = rules.behavior(app: content.appName, title: content.title, body: content.body)
                if behavior.mode == .hidden {
                    let count = self.cards.count
                    self.cards.removeAll { $0.content.sourceID == content.sourceID }
                    changed = changed || self.cards.count != count
                    continue
                }
                if let index = self.cards.firstIndex(where: { $0.content.sourceID == content.sourceID }) {
                    self.cards[index].content = content
                    self.cards[index].behavior = behavior
                    self.cards[index].remaining = nil
                } else {
                    self.cards.append(Card(id: UUID(), content: content, behavior: behavior, remaining: nil))
                }
                changed = true
            }
            if changed { self.layout() }
        }
    }

    func showPreview() {
        guard configuration.fallback.mode != .hidden else {
            statusKey = "The fallback is set to Do not show. Change its display behavior to preview a notification."
            return
        }
        cards.append(Card(id: UUID(), content: SystemNotificationContent(
            sourceID: UUID().uuidString, appName: "WinTaskbar",
            title: NSLocalizedString("Notification preview", comment: "Notification sample"),
            body: NSLocalizedString("New notifications stack upward. This preview uses the fallback display behavior and does not read system notifications.", comment: "Notification sample")
        ), behavior: configuration.fallback, isPreview: true, remaining: nil))
        layout()
    }

    func clearCards() {
        cards.removeAll()
        panels.values.forEach { $0.close() }
        panels.removeAll()
        hovered.removeAll()
        expanded.removeAll()
        expiryTimer?.invalidate()
        expiryTimer = nil
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
            let compact = NotificationCardMetrics.measure(card.content, width: width, maxHeight: maxHeight, expanded: false)
            guard compact.height <= availableHeight else { break }
            // Expanding the top card must keep it visible; scroll within the remaining screen space.
            let metrics = expanded.contains(card.id)
                ? NotificationCardMetrics.measure(card.content, width: width, maxHeight: min(maxHeight, availableHeight), expanded: true)
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
        var bottom = area.minY + gap
        for (slot, entry) in visible.enumerated() {
            let card = entry.card
            let panel: NSPanel
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
                panel.level = .floating
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
                panels[card.id] = panel
            }
            if let index = cards.firstIndex(where: { $0.id == card.id }), cards[index].remaining == nil {
                cards[index].remaining = card.behavior.duration
            }
            panel.appearance = preferences.theme == .dark ? NSAppearance(named: .darkAqua)
                : preferences.theme == .light ? NSAppearance(named: .aqua) : nil
            let view = NotificationCardView(
                content: card.content,
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
            panel.setFrame(NSRect(x: area.maxX - width - gap, y: bottom, width: width, height: entry.metrics.height), display: true)
            bottom += entry.metrics.height + gap
            panel.orderFrontRegardless()
        }
        if cards.isEmpty {
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
