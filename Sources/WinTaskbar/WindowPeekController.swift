import AppKit
import CoreGraphics

struct WindowPeekGeometry {
    static func localFrame(windowFrame: CGRect, displayBounds: CGRect) -> CGRect {
        CGRect(
            x: windowFrame.minX - displayBounds.minX,
            y: displayBounds.maxY - windowFrame.maxY,
            width: windowFrame.width,
            height: windowFrame.height
        )
    }
}

private final class WindowPeekPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class WindowPeekContentView: NSView {
    private var desktopImage: NSImage?
    private var windowImage: NSImage?
    private var windowFrame = CGRect.zero
    private var displayBounds = CGRect.zero

    override var isOpaque: Bool { true }

    func update(
        desktopImage: NSImage?,
        windowImage: NSImage,
        windowFrame: CGRect,
        displayBounds: CGRect
    ) {
        self.desktopImage = desktopImage
        self.windowImage = windowImage
        self.windowFrame = windowFrame
        self.displayBounds = displayBounds
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        NSBezierPath(rect: bounds).fill()
        drawDesktopImage()

        NSColor.black.withAlphaComponent(0.08).setFill()
        NSBezierPath(rect: bounds).fill()

        guard let windowImage else { return }
        let targetFrame = WindowPeekGeometry.localFrame(
            windowFrame: windowFrame,
            displayBounds: displayBounds
        )
        guard targetFrame.intersects(bounds) else { return }

        let shape = NSBezierPath(roundedRect: targetFrame, xRadius: 9, yRadius: 9)
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.48)
        shadow.shadowBlurRadius = 24
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.set()
        NSColor.black.withAlphaComponent(0.25).setFill()
        shape.fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        NSGraphicsContext.current?.saveGraphicsState()
        shape.addClip()
        windowImage.draw(
            in: targetFrame,
            from: NSRect(origin: .zero, size: windowImage.size),
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: false,
            hints: nil
        )
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    private func drawDesktopImage() {
        guard let desktopImage,
              desktopImage.size.width > 0,
              desktopImage.size.height > 0 else {
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(rect: bounds).fill()
            return
        }

        let scale = max(
            bounds.width / desktopImage.size.width,
            bounds.height / desktopImage.size.height
        )
        let size = NSSize(
            width: desktopImage.size.width * scale,
            height: desktopImage.size.height * scale
        )
        let destination = NSRect(
            x: bounds.midX - (size.width / 2),
            y: bounds.midY - (size.height / 2),
            width: size.width,
            height: size.height
        )
        desktopImage.draw(
            in: destination,
            from: NSRect(origin: .zero, size: desktopImage.size),
            operation: .copy,
            fraction: 1,
            respectFlipped: false,
            hints: nil
        )
    }
}

@MainActor
final class WindowPeekController {
    private let windowsService: WindowsService
    private var panels: [CGDirectDisplayID: WindowPeekPanel] = [:]
    private var desktopImages: [URL: NSImage] = [:]
    private var currentWindowID: CGWindowID?
    private var delayedHideTask: Task<Void, Never>?
    private var orderOutTask: Task<Void, Never>?

    init(windowsService: WindowsService) {
        self.windowsService = windowsService
    }

    func show(window: WindowInfo) {
        delayedHideTask?.cancel()
        delayedHideTask = nil
        orderOutTask?.cancel()
        orderOutTask = nil

        guard let image = windowsService.thumbnail(for: window.windowID) else {
            hideImmediately()
            return
        }

        currentWindowID = window.windowID
        reconcilePanels(window: window, image: image)
        for panel in panels.values {
            if !panel.isVisible {
                panel.alphaValue = 0
                panel.orderFrontRegardless()
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
    }

    func scheduleHide() {
        delayedHideTask?.cancel()
        delayedHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        delayedHideTask?.cancel()
        delayedHideTask = nil
        currentWindowID = nil
        orderOutTask?.cancel()

        for panel in panels.values where panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            }
        }
        orderOutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled, self?.currentWindowID == nil else { return }
            self?.panels.values.forEach { panel in
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        }
    }

    func hideImmediately() {
        delayedHideTask?.cancel()
        delayedHideTask = nil
        orderOutTask?.cancel()
        orderOutTask = nil
        currentWindowID = nil
        panels.values.forEach { panel in
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
    }

    private func reconcilePanels(window: WindowInfo, image: NSImage) {
        let displays = NSScreen.screens.compactMap { screen -> (NSScreen, CGDirectDisplayID)? in
            guard let displayID = displayID(for: screen) else { return nil }
            return (screen, displayID)
        }
        let currentDisplayIDs = Set(displays.map(\.1))
        for displayID in panels.keys where !currentDisplayIDs.contains(displayID) {
            panels.removeValue(forKey: displayID)?.orderOut(nil)
        }

        for (screen, displayID) in displays {
            let displayBounds = CGDisplayBounds(displayID)
            let panel = panels[displayID] ?? makePanel(for: screen, displayID: displayID)
            panel.setFrame(screen.frame, display: false)
            let contentView = panel.contentView as? WindowPeekContentView
            contentView?.update(
                desktopImage: desktopImage(for: screen),
                windowImage: image,
                windowFrame: window.frame,
                displayBounds: displayBounds
            )
        }
    }

    private func makePanel(for screen: NSScreen, displayID: CGDirectDisplayID) -> WindowPeekPanel {
        let panel = WindowPeekPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.contentView = WindowPeekContentView(frame: NSRect(origin: .zero, size: screen.frame.size))
        panels[displayID] = panel
        return panel
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    private func desktopImage(for screen: NSScreen) -> NSImage? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        if let cached = desktopImages[url] { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        desktopImages[url] = image
        return image
    }
}
