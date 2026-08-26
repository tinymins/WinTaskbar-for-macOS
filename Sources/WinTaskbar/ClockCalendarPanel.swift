import AppKit
import Combine
import QuartzCore
import SwiftUI

final class ClockCalendarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct ClockCalendarPanelTransitionSequence {
    private(set) var revision: UInt = 0

    mutating func begin() -> UInt {
        revision &+= 1
        return revision
    }

    func isCurrent(_ revision: UInt) -> Bool {
        self.revision == revision
    }
}

struct ClockCalendarDismissalPolicy {
    static func shouldDismissForFocusLoss(
        isEditingCalendarEvent: Bool,
        isRequestingCalendarAccess: Bool
    ) -> Bool {
        !isEditingCalendarEvent && !isRequestingCalendarAccess
    }
}

@MainActor
final class ClockCalendarPanelController: ObservableObject {
    let state = ClockCalendarState()
    let calendarService: SystemCalendarService

    private let backdrop = NSVisualEffectView()
    private let hostingView: NSHostingView<AnyView>
    private var panel: ClockCalendarPanel?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var expansionObserver: AnyCancellable?
    private var presentation: Presentation?
    private var isShowing = false
    private var transitionSequence = ClockCalendarPanelTransitionSequence()

    private struct Presentation {
        let screen: NSScreen
        let position: TaskbarPosition
        let barHeight: CGFloat
    }

    init() {
        let calendarService = SystemCalendarService()
        self.calendarService = calendarService
        hostingView = NSHostingView(rootView: AnyView(ClockCalendarPanelView(
            state: state,
            calendarService: calendarService
        )))
        expansionObserver = state.$isExpanded.dropFirst().sink { [weak self] isExpanded in
            MainActor.assumeIsolated { self?.resizeForExpansion(isExpanded: isExpanded) }
        }
    }

    func toggle(screen: NSScreen, position: TaskbarPosition, barHeight: CGFloat, theme: AppTheme) {
        if isShowing {
            dismiss()
        } else {
            present(screen: screen, position: position, barHeight: barHeight, theme: theme)
        }
    }

    func dismiss(animated: Bool = true) {
        guard isShowing, let panel, let presentation else { return }
        let transitionRevision = transitionSequence.begin()
        isShowing = false
        state.isEditingCalendarEvent = false
        removeEventMonitors()

        guard animated else {
            panel.orderOut(nil)
            return
        }

        let targetFrame = frame(for: presentation)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = StartMenuMotion.exitDuration
            context.timingFunction = StartMenuMotion.exitTimingFunction()
            panel.animator().setFrame(StartMenuMotion.dismissedFrame(from: targetFrame, position: presentation.position), display: true)
            panel.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor [weak self, weak panel] in
                guard let self,
                      let panel,
                      !self.isShowing,
                      self.transitionSequence.isCurrent(transitionRevision) else { return }
                panel.orderOut(nil)
            }
        }
    }

    private func present(screen: NSScreen, position: TaskbarPosition, barHeight: CGFloat, theme: AppTheme) {
        let transitionRevision = transitionSequence.begin()
        state.resetToToday()
        calendarService.refreshAuthorizationState()
        Task { [weak self] in
            guard let self else { return }
            await self.calendarService.loadEvents(in: self.state.eventQueryInterval)
        }
        let presentation = Presentation(screen: screen, position: position, barHeight: barHeight)
        self.presentation = presentation
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.appearance = appearance(for: theme)

        let targetFrame = frame(for: presentation)
        panel.setFrame(StartMenuMotion.dismissedFrame(from: targetFrame, position: position), display: true)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        isShowing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + StartMenuMotion.entranceDuration) { [weak self] in
            guard let self,
                  self.isShowing,
                  self.transitionSequence.isCurrent(transitionRevision) else { return }
            self.installEventMonitors()
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = StartMenuMotion.entranceDuration
            context.timingFunction = StartMenuMotion.entranceTimingFunction()
            panel.animator().setFrame(targetFrame, display: true)
            panel.animator().alphaValue = 1
        }
    }

    private func makePanel() -> ClockCalendarPanel {
        let panel = ClockCalendarPanel(
            contentRect: NSRect(origin: .zero, size: currentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.title = "Clock and calendar"
        panel.titleVisibility = .hidden
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.frame = NSRect(origin: .zero, size: currentSize)
        backdrop.autoresizingMask = [.width, .height]
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 8
        backdrop.layer?.cornerCurve = .continuous
        backdrop.layer?.masksToBounds = true
        backdrop.layer?.borderWidth = 0.5
        backdrop.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor

        hostingView.frame = backdrop.bounds
        hostingView.autoresizingMask = [.width, .height]
        backdrop.addSubview(hostingView)
        panel.contentView = backdrop
        return panel
    }

    private func resizeForExpansion(isExpanded: Bool) {
        guard isShowing, let panel, let presentation else { return }
        let targetFrame = frame(for: presentation, contentSize: size(isExpanded: isExpanded))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = StartMenuMotion.exitDuration
            context.timingFunction = StartMenuMotion.entranceTimingFunction()
            panel.animator().setFrame(targetFrame, display: true)
        }
    }

    private func frame(for presentation: Presentation) -> NSRect {
        frame(for: presentation, contentSize: currentSize)
    }

    private func frame(for presentation: Presentation, contentSize: CGSize) -> NSRect {
        StartMenuGeometry.anchoredFrame(
            screenFrame: presentation.screen.frame,
            visibleFrame: presentation.screen.visibleFrame,
            position: presentation.position,
            barHeight: presentation.barHeight,
            contentSize: contentSize,
            oppositeEnd: true
        )
    }

    private var currentSize: CGSize {
        size(isExpanded: state.isExpanded)
    }

    private func size(isExpanded: Bool) -> CGSize {
        CGSize(
            width: ClockCalendarMetrics.width,
            height: isExpanded ? ClockCalendarMetrics.expandedHeight : ClockCalendarMetrics.collapsedHeight
        )
    }

    private func installEventMonitors() {
        removeEventMonitors()
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseUp, .rightMouseUp, .keyDown, .scrollWheel]
        ) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                if self.state.isEditingCalendarEvent { return event }
                self.dismiss()
                return nil
            }
            if event.type == .scrollWheel,
               event.window === self.panel,
               self.state.isExpanded,
               !self.state.isEditingCalendarEvent {
                guard event.scrollingDeltaY != 0 else { return nil }
                if event.hasPreciseScrollingDeltas {
                    self.state.scrollCalendar(by: event.scrollingDeltaY)
                    self.state.scheduleCalendarScrollSettling()
                } else {
                    self.state.scrollCalendarByWheel(direction: event.scrollingDeltaY > 0 ? 1 : -1)
                }
                return nil
            }
            if event.window !== self.panel {
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          ClockCalendarDismissalPolicy.shouldDismissForFocusLoss(
                              isEditingCalendarEvent: self.state.isEditingCalendarEvent,
                              isRequestingCalendarAccess: self.calendarService.isRequestingAccess
                          ) else { return }
                    self.dismiss()
                }
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self,
                  ClockCalendarDismissalPolicy.shouldDismissForFocusLoss(
                      isEditingCalendarEvent: self.state.isEditingCalendarEvent,
                      isRequestingCalendarAccess: self.calendarService.isRequestingAccess
                  ) else { return }
            self.dismiss()
        }
    }

    private func removeEventMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    private func appearance(for theme: AppTheme) -> NSAppearance? {
        switch theme {
        case .automatic: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
