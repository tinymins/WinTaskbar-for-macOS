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
        let changedDuration = configuration.displaySeconds != value.displaySeconds
        configuration = value
        if changedDuration {
            for index in cards.indices {
                cards[index].remaining = value.displaySeconds == 0 ? nil : TimeInterval(max(1, value.displaySeconds))
            }
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
                let scan = SystemNotificationCapture.scan()
                return (scan, scan.notifications.filter { rules.accepts(app: $0.appName, title: $0.title, body: $0.body) })
            }.value
            guard let self else { return }
            self.scanTask = nil
            guard self.configuration == rules, self.generation == currentGeneration, !self.suspended else { return }
            self.statusKey = result.0.unreadable ? "Some notification content could not be read. Check Accessibility access."
                : result.0.unrecognized ? "A notification layout was not recognized."
                : "Listening for system notification banners."
            let now = ProcessInfo.processInfo.systemUptime
            self.seen = self.seen.filter { now - $0.value.time < 600 }
            var changed = false
            let acceptedIDs = Set(result.1.map(\.sourceID))
            for content in result.0.notifications {
                let previous = self.seen[content.sourceID]?.content
                self.seen[content.sourceID] = (content, now)
                guard previous != content, acceptedIDs.contains(content.sourceID) else { continue }
                if let index = self.cards.firstIndex(where: { $0.content.sourceID == content.sourceID }) {
                    self.cards[index].content = content
                    self.cards[index].remaining = rules.displaySeconds == 0 ? nil : TimeInterval(max(1, rules.displaySeconds))
                } else {
                    self.cards.append(Card(id: UUID(), content: content, remaining: nil))
                }
                changed = true
            }
            if changed { self.layout() }
        }
    }

    func showPreview() {
        cards.append(Card(id: UUID(), content: SystemNotificationContent(
            sourceID: UUID().uuidString, appName: "WinTaskbar",
            title: NSLocalizedString("Notification preview", comment: "Notification sample"),
            body: NSLocalizedString("New notifications stack upward. This preview uses your display time and does not read system notifications.", comment: "Notification sample")
        ), remaining: nil))
        layout()
    }

    func clearCards() {
        cards.removeAll()
        panels.values.forEach { $0.close() }
        panels.removeAll()
        hovered.removeAll()
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
        let height = min(220, max(100, area.height - gap * 2))
        let width = min(410, max(240, area.width - gap * 2))
        let capacity = max(1, Int((area.height - gap) / (height + gap)))
        let visible = Array(cards.suffix(capacity).reversed())
        let visibleIDs = Set(visible.map(\.id))
        for id in Array(panels.keys) where !visibleIDs.contains(id) {
            panels.removeValue(forKey: id)?.close()
            hovered.remove(id)
        }
        for (slot, card) in visible.enumerated() {
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
                if let index = cards.firstIndex(where: { $0.id == card.id }), cards[index].remaining == nil,
                   configuration.displaySeconds != 0 {
                    cards[index].remaining = TimeInterval(max(1, configuration.displaySeconds))
                }
            }
            panel.appearance = preferences.theme == .dark ? NSAppearance(named: .darkAqua)
                : preferences.theme == .light ? NSAppearance(named: .aqua) : nil
            let view = NotificationCardView(
                content: card.content, queued: slot == visible.count - 1 ? max(0, cards.count - visible.count) : 0,
                dismiss: { [weak self] in self?.dismiss(card.id) },
                hover: { [weak self] inside in
                    if inside { self?.hovered.insert(card.id) } else { self?.hovered.remove(card.id) }
                }
            )
            if let hosting = panel.contentView as? NSHostingView<NotificationCardView> {
                hosting.rootView = view
            } else {
                panel.contentView = NSHostingView(rootView: view)
            }
            panel.setFrame(NSRect(x: area.maxX - width - gap, y: area.minY + gap + CGFloat(slot) * (height + gap), width: width, height: height), display: true)
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

private struct NotificationCardView: View {
    let content: SystemNotificationContent
    let queued: Int
    let dismiss: () -> Void
    let hover: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: "bell.badge.fill").foregroundStyle(Color.accentColor)
                Text(content.appName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark").padding(5) }
                    .buttonStyle(.plain).help("Dismiss notification")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !content.title.isEmpty { Text(content.title).font(.system(size: 18, weight: .semibold)) }
                    if !content.body.isEmpty { Text(content.body).font(.system(size: 17)) }
                }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            if queued > 0 {
                Text(String(format: NSLocalizedString("%ld more notifications waiting", comment: "Queued notifications"), queued))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
        .padding(1).onHover(perform: hover)
    }
}
