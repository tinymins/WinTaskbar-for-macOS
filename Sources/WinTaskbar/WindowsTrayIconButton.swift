import AppKit
import SwiftUI

enum WindowsTrayIconMetrics {
    static let squareControlWidth: CGFloat = 32
    static let batteryControlWidth: CGFloat = 60
    static let controlHeight: CGFloat = 40
    static let iconSize: CGFloat = 18
    static let horizontalContentPadding: CGFloat = 7
}

@MainActor
struct WindowsTrayIconButton<Content: View>: NSViewRepresentable {
    let title: String
    let accessibilityLabel: String
    let primaryAction: () -> Void
    let contextAction: (() -> Void)?
    private let content: Content

    init(
        title: String,
        accessibilityLabel: String? = nil,
        primaryAction: @escaping () -> Void,
        contextAction: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.accessibilityLabel = accessibilityLabel ?? title
        self.primaryAction = primaryAction
        self.contextAction = contextAction
        self.content = content()
    }

    func makeNSView(context: Context) -> WindowsTrayIconControl {
        let control = WindowsTrayIconControl()
        update(control)
        return control
    }

    func updateNSView(_ control: WindowsTrayIconControl, context: Context) {
        update(control)
    }

    private func update(_ control: WindowsTrayIconControl) {
        control.setContent(AnyView(
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
        ))
        control.hoverTitle = title
        control.onLeftActivate = primaryAction
        control.onRightActivate = contextAction
        control.setAccessibilityElement(true)
        control.setAccessibilityRole(.button)
        control.setAccessibilityLabel(accessibilityLabel)
    }
}

@MainActor
final class WindowsTrayIconControl: NSControl {
    var hoverTitle = ""
    var onLeftActivate: (() -> Void)?
    var onRightActivate: (() -> Void)?

    private var hostingView: NSHostingView<AnyView>?
    private var trackingAreaReference: NSTrackingArea?
    private var isHovered = false
    private var isPressed = false

    override var isFlipped: Bool { true }

    func setContent(_ content: AnyView) {
        if let hostingView {
            hostingView.rootView = content
        } else {
            let hostingView = NSHostingView(rootView: content)
            addSubview(hostingView)
            self.hostingView = hostingView
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        hostingView?.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaReference = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
        guard !hoverTitle.isEmpty, let window else { return }
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        WindowsTrayTooltipController.shared.schedule(title: hoverTitle, anchor: anchor, owner: self)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
        WindowsTrayTooltipController.shared.hide(owner: self)
    }

    override func mouseDown(with event: NSEvent) {
        activate(onLeftActivate)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let onRightActivate else { return }
        activate(onRightActivate)
    }

    override func accessibilityPerformPress() -> Bool {
        activate(onLeftActivate)
        return onLeftActivate != nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            WindowsTrayTooltipController.shared.hide(owner: self)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isHovered || isPressed {
            NSColor.labelColor.withAlphaComponent(isPressed ? 0.16 : 0.10).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
    }

    private func activate(_ action: (() -> Void)?) {
        guard let action else { return }
        WindowsTrayTooltipController.shared.hide(owner: self)
        isPressed = true
        needsDisplay = true
        displayIfNeeded()
        action()
        isPressed = false
        needsDisplay = true
    }
}

@MainActor
private final class WindowsTrayTooltipController {
    static let shared = WindowsTrayTooltipController()

    private let panel: WindowsTrayTooltipPanel
    private let tooltipView = WindowsTrayTooltipView()
    private var pendingWorkItem: DispatchWorkItem?
    private weak var owner: WindowsTrayIconControl?

    private init() {
        panel = WindowsTrayTooltipPanel(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = tooltipView
    }

    func schedule(title: String, anchor: CGRect, owner: WindowsTrayIconControl) {
        pendingWorkItem?.cancel()
        panel.orderOut(nil)
        self.owner = owner

        let workItem = DispatchWorkItem { [weak self, weak owner] in
            guard let self, let owner, self.owner === owner, owner.window != nil else { return }
            self.show(title: title, anchor: anchor)
        }
        pendingWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(400), execute: workItem)
    }

    func hide(owner: WindowsTrayIconControl) {
        guard self.owner === owner else { return }
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        self.owner = nil
        panel.orderOut(nil)
    }

    private func show(title: String, anchor: CGRect) {
        tooltipView.title = title
        let textWidth = ceil((title as NSString).size(withAttributes: [.font: tooltipView.font]).width)
        let size = CGSize(width: min(max(textWidth + 20, 44), 280), height: 32)
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main else { return }
        panel.setFrame(Self.frame(size: size, anchor: anchor, screen: screen.frame), display: true)
        panel.orderFrontRegardless()
    }

    private static func frame(size: CGSize, anchor: CGRect, screen: CGRect) -> CGRect {
        let distances = [
            (side: 0, distance: abs(anchor.minY - screen.minY)),
            (side: 1, distance: abs(screen.maxY - anchor.maxY)),
            (side: 2, distance: abs(anchor.minX - screen.minX)),
            (side: 3, distance: abs(screen.maxX - anchor.maxX))
        ]
        let side = distances.min(by: { $0.distance < $1.distance })?.side ?? 0
        var origin: CGPoint
        switch side {
        case 1:
            origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 4)
        case 2:
            origin = CGPoint(x: anchor.maxX + 4, y: anchor.midY - size.height / 2)
        case 3:
            origin = CGPoint(x: anchor.minX - size.width - 4, y: anchor.midY - size.height / 2)
        default:
            origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + 4)
        }
        origin.x = min(max(origin.x, screen.minX + 6), screen.maxX - size.width - 6)
        origin.y = min(max(origin.y, screen.minY + 6), screen.maxY - size.height - 6)
        return CGRect(origin: origin, size: size)
    }
}

private final class WindowsTrayTooltipPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class WindowsTrayTooltipView: NSView {
    let font = NSFont.systemFont(ofSize: 11, weight: .regular)
    var title = "" { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 31 / 255, green: 42 / 255, blue: 52 / 255, alpha: 0.98).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        NSColor(srgbRed: 58 / 255, green: 68 / 255, blue: 77 / 255, alpha: 1).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        border.lineWidth = 1
        border.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        (title as NSString).draw(
            in: bounds.insetBy(dx: 10, dy: 8),
            withAttributes: [
                .font: font,
                .foregroundColor: NSColor(srgbRed: 246 / 255, green: 247 / 255, blue: 247 / 255, alpha: 1),
                .paragraphStyle: paragraph
            ]
        )
    }
}
