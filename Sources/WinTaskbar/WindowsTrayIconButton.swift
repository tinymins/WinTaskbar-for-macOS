import AppKit
import SwiftUI

enum WindowsTrayIconMetrics {
    static let squareControlWidth: CGFloat = 32
    static let batteryControlWidth: CGFloat = 60
    static let controlHeight: CGFloat = 40
    static let iconSize: CGFloat = 18
    static let clockFontSize: CGFloat = 12
    static let clockRowHeight: CGFloat = 18
    static let horizontalContentPadding: CGFloat = 7
    static let tooltipGap: CGFloat = 4
    static let clockTooltipGap: CGFloat = 10
    static let showDesktopHitThickness: CGFloat = 8
    static let showDesktopVisibleThickness: CGFloat = 1
    static let showDesktopIndicatorLength: CGFloat = 20
    static let showDesktopIndicatorEdgeInset: CGFloat = 4
    static let hoverFillOpacity: CGFloat = 0.10
    static let pressedFillOpacity: CGFloat = 0.22
}

enum WindowsTrayIconAppearance {
    case standard
    case showDesktop(horizontal: Bool)
}

enum WindowsTrayIconDropAxis {
    case horizontal
    case vertical
}

@MainActor
final class WindowsTrayDragSessionState: ObservableObject {
    static let shared = WindowsTrayDragSessionState()

    @Published private(set) var draggedItemID: String?
    private(set) var draggedItemCenterOffset = CGSize.zero

    func begin(itemID: String, centerOffset: CGSize) {
        draggedItemID = itemID
        draggedItemCenterOffset = centerOffset
    }

    func end(itemID: String) {
        guard draggedItemID == itemID else { return }
        draggedItemID = nil
        draggedItemCenterOffset = .zero
    }
}

@MainActor
enum WindowsTrayTooltipMetrics {
    static let font = NSFont.systemFont(ofSize: 11, weight: .regular)
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 8
    static let minimumWidth: CGFloat = 44
    static let maximumWidth: CGFloat = 280
    static let singleLineHeight: CGFloat = 32

    static func lines(for title: String) -> [String] {
        title.components(separatedBy: "\n")
    }

    static func size(for title: String) -> CGSize {
        let lines = lines(for: title)
        let textWidth = lines.map {
            ($0 as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 0
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let height = lines.count == 1
            ? singleLineHeight
            : ceil(CGFloat(lines.count) * lineHeight + 2 * verticalPadding)
        return CGSize(
            width: min(max(ceil(textWidth) + 2 * horizontalPadding, minimumWidth), maximumWidth),
            height: height
        )
    }
}

@MainActor
struct WindowsTrayIconButton<Content: View>: NSViewRepresentable {
    let title: String
    let accessibilityLabel: String
    let tooltipGap: CGFloat
    let visualStyle: WindowsTrayIconAppearance
    let preservesTransientPanelOnMouseDown: Bool
    let primaryAction: (WindowsTrayIconControl) -> Void
    let contextAction: (() -> Void)?
    let dragIdentifier: String?
    let dropAxis: WindowsTrayIconDropAxis
    let dropValidator: ((String) -> Bool)?
    let dropHoverAction: ((String, Bool) -> Void)?
    let dropAction: ((String, Bool) -> Void)?
    let dropTipSymbolName: String?
    private let content: Content

    init(
        title: String,
        accessibilityLabel: String? = nil,
        tooltipGap: CGFloat = WindowsTrayIconMetrics.tooltipGap,
        visualStyle: WindowsTrayIconAppearance = .standard,
        preservesTransientPanelOnMouseDown: Bool = false,
        primaryAction: @escaping () -> Void,
        contextAction: (() -> Void)? = nil,
        dragIdentifier: String? = nil,
        dropAxis: WindowsTrayIconDropAxis = .horizontal,
        dropValidator: ((String) -> Bool)? = nil,
        dropHoverAction: ((String, Bool) -> Void)? = nil,
        dropAction: ((String, Bool) -> Void)? = nil,
        dropTipSymbolName: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.accessibilityLabel = accessibilityLabel ?? title
        self.tooltipGap = tooltipGap
        self.visualStyle = visualStyle
        self.preservesTransientPanelOnMouseDown = preservesTransientPanelOnMouseDown
        self.primaryAction = { _ in primaryAction() }
        self.contextAction = contextAction
        self.dragIdentifier = dragIdentifier
        self.dropAxis = dropAxis
        self.dropValidator = dropValidator
        self.dropHoverAction = dropHoverAction
        self.dropAction = dropAction
        self.dropTipSymbolName = dropTipSymbolName
        self.content = content()
    }

    init(
        title: String,
        accessibilityLabel: String? = nil,
        tooltipGap: CGFloat = WindowsTrayIconMetrics.tooltipGap,
        visualStyle: WindowsTrayIconAppearance = .standard,
        preservesTransientPanelOnMouseDown: Bool = false,
        anchoredPrimaryAction: @escaping (WindowsTrayIconControl) -> Void,
        contextAction: (() -> Void)? = nil,
        dragIdentifier: String? = nil,
        dropAxis: WindowsTrayIconDropAxis = .horizontal,
        dropValidator: ((String) -> Bool)? = nil,
        dropHoverAction: ((String, Bool) -> Void)? = nil,
        dropAction: ((String, Bool) -> Void)? = nil,
        dropTipSymbolName: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.accessibilityLabel = accessibilityLabel ?? title
        self.tooltipGap = tooltipGap
        self.visualStyle = visualStyle
        self.preservesTransientPanelOnMouseDown = preservesTransientPanelOnMouseDown
        self.primaryAction = anchoredPrimaryAction
        self.contextAction = contextAction
        self.dragIdentifier = dragIdentifier
        self.dropAxis = dropAxis
        self.dropValidator = dropValidator
        self.dropHoverAction = dropHoverAction
        self.dropAction = dropAction
        self.dropTipSymbolName = dropTipSymbolName
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
        control.tooltipGap = tooltipGap
        control.visualStyle = visualStyle
        control.preservesTransientPanelOnMouseDown = preservesTransientPanelOnMouseDown
        control.onLeftActivate = { [weak control] in
            guard let control else { return }
            primaryAction(control)
        }
        control.onRightActivate = contextAction
        control.dragIdentifier = dragIdentifier
        control.dropAxis = dropAxis
        control.dropValidator = dropValidator
        control.onDropHover = dropHoverAction
        control.onDrop = dropAction
        control.dropTipSymbolName = dropTipSymbolName
        control.setAccessibilityElement(true)
        control.setAccessibilityRole(.button)
        control.setAccessibilityLabel(accessibilityLabel)
    }
}

@MainActor
final class WindowsTrayIconControl: NSControl, NSDraggingSource {
    static let trayItemPasteboardType = NSPasteboard.PasteboardType(
        "io.github.tinymins.WinTaskbar.external-status-item"
    )
    static let trackingAreaOptions: NSTrackingArea.Options = [
        .activeAlways,
        .mouseEnteredAndExited,
        .inVisibleRect,
    ]

    var hoverTitle = ""
    var tooltipGap = WindowsTrayIconMetrics.tooltipGap
    var visualStyle = WindowsTrayIconAppearance.standard
    var preservesTransientPanelOnMouseDown = false
    var onLeftActivate: (() -> Void)?
    var onRightActivate: (() -> Void)?
    var dragIdentifier: String?
    var dropAxis = WindowsTrayIconDropAxis.horizontal
    var dropValidator: ((String) -> Bool)?
    var onDropHover: ((String, Bool) -> Void)?
    var dropTipSymbolName: String?
    var onDrop: ((String, Bool) -> Void)? {
        didSet {
            unregisterDraggedTypes()
            if onDrop != nil { registerForDraggedTypes([Self.trayItemPasteboardType]) }
        }
    }

    private var hostingView: NSHostingView<AnyView>?
    private var trackingAreaReference: NSTrackingArea?
    private var isHovered = false
    private var isPressed = false
    private var isDropTarget = false
    private var mouseDownLocation: CGPoint?
    private var didBeginDrag = false
    private var isDragging = false
    private var lastDropHover: (identifier: String, after: Bool)?

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
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: .zero,
            options: Self.trackingAreaOptions,
            owner: self
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
        guard !hoverTitle.isEmpty, let window else { return }
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        WindowsTrayTooltipController.shared.schedule(
            title: hoverTitle,
            anchor: anchor,
            gap: tooltipGap,
            owner: self
        )
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
        WindowsTrayTooltipController.shared.hide(owner: self)
    }

    override func mouseDown(with event: NSEvent) {
        guard onLeftActivate != nil || dragIdentifier != nil else { return }
        WindowsTrayTooltipController.shared.hide(owner: self)
        mouseDownLocation = convert(event.locationInWindow, from: nil)
        didBeginDrag = false
        isPressed = true
        needsDisplay = true
        displayIfNeeded()
    }

    override func mouseDragged(with event: NSEvent) {
        if !didBeginDrag,
           let dragIdentifier,
           let mouseDownLocation {
            let currentLocation = convert(event.locationInWindow, from: nil)
            let distance = hypot(
                currentLocation.x - mouseDownLocation.x,
                currentLocation.y - mouseDownLocation.y
            )
            if distance >= 4 {
                beginTrayItemDrag(identifier: dragIdentifier, event: event)
                return
            }
        }
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownLocation = nil
        if didBeginDrag {
            didBeginDrag = false
            isPressed = false
            needsDisplay = true
            return
        }
        let shouldActivate = isPressed && bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        needsDisplay = true
        displayIfNeeded()
        if shouldActivate { perform(onLeftActivate) }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let onRightActivate else { return }
        perform(onRightActivate)
    }

    override func accessibilityPerformPress() -> Bool {
        perform(onLeftActivate)
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
        guard !isDragging, isHovered || isPressed || isDropTarget else { return }
        switch visualStyle {
        case .standard:
            let opacity = isPressed || isDropTarget
                ? WindowsTrayIconMetrics.pressedFillOpacity
                : WindowsTrayIconMetrics.hoverFillOpacity
            NSColor.labelColor.withAlphaComponent(opacity).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        case let .showDesktop(horizontal):
            NSColor.labelColor.withAlphaComponent(isPressed ? 0.45 : 0.24).setFill()
            let thickness = WindowsTrayIconMetrics.showDesktopVisibleThickness
            let length = WindowsTrayIconMetrics.showDesktopIndicatorLength
            let edgeInset = WindowsTrayIconMetrics.showDesktopIndicatorEdgeInset
            let indicator = horizontal
                ? CGRect(
                    x: bounds.maxX - edgeInset - thickness,
                    y: bounds.midY - length / 2,
                    width: thickness,
                    height: length
                )
                : CGRect(
                    x: bounds.midX - length / 2,
                    y: bounds.maxY - edgeInset - thickness,
                    width: length,
                    height: thickness
                )
            NSBezierPath(rect: indicator).fill()
        }
    }

    private func perform(_ action: (() -> Void)?) {
        guard let action else { return }
        WindowsTrayTooltipController.shared.hide(owner: self)
        action()
    }

    private func beginTrayItemDrag(identifier: String, event: NSEvent) {
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(identifier, forType: Self.trayItemPasteboardType)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(bounds, contents: dragContentImage())

        didBeginDrag = true
        isDragging = true
        isPressed = false
        hostingView?.alphaValue = 0
        needsDisplay = true
        let pointerLocation = NSEvent.mouseLocation
        let centerOffset: CGSize
        if let window {
            let centerInWindow = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil)
            let centerOnScreen = window.convertPoint(toScreen: centerInWindow)
            centerOffset = CGSize(
                width: centerOnScreen.x - pointerLocation.x,
                height: centerOnScreen.y - pointerLocation.y
            )
        } else {
            centerOffset = .zero
        }
        WindowsTrayDragSessionState.shared.begin(itemID: identifier, centerOffset: centerOffset)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    private func dragContentImage() -> NSImage {
        guard let hostingView,
              let representation = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            return NSImage(size: bounds.size)
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(representation)
        return image
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .move
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if let dragIdentifier { WindowsTrayDragSessionState.shared.end(itemID: dragIdentifier) }
        didBeginDrag = false
        isDragging = false
        mouseDownLocation = nil
        isPressed = false
        hostingView?.alphaValue = 1
        needsDisplay = true
        WindowsTrayDropTipController.shared.hide(owner: self)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrop(from: sender) else { return [] }
        isDropTarget = true
        needsDisplay = true
        updateDropHover(from: sender)
        showDropTipIfNeeded()
        return .move
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrop(from: sender) else { return [] }
        updateDropHover(from: sender)
        return .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        isDropTarget = false
        lastDropHover = nil
        needsDisplay = true
        WindowsTrayDropTipController.shared.hide(owner: self)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        acceptsDrop(from: sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard acceptsDrop(from: sender),
              let identifier = draggedIdentifier(from: sender),
              let onDrop else { return false }
        let location = draggedItemCenterLocation(from: sender)
        let after = dropAxis == .horizontal ? location.x >= bounds.midX : location.y >= bounds.midY
        onDrop(identifier, after)
        isDropTarget = false
        lastDropHover = nil
        needsDisplay = true
        WindowsTrayDropTipController.shared.hide(owner: self)
        return true
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        isDropTarget = false
        lastDropHover = nil
        needsDisplay = true
        WindowsTrayDropTipController.shared.hide(owner: self)
    }

    private func draggedIdentifier(from sender: any NSDraggingInfo) -> String? {
        sender.draggingPasteboard.string(forType: Self.trayItemPasteboardType)
    }

    private func acceptsDrop(from sender: any NSDraggingInfo) -> Bool {
        guard onDrop != nil, let identifier = draggedIdentifier(from: sender) else { return false }
        return dropValidator?(identifier) ?? true
    }

    private func updateDropHover(from sender: any NSDraggingInfo) {
        guard let onDropHover, let identifier = draggedIdentifier(from: sender) else { return }
        let location = draggedItemCenterLocation(from: sender)
        let after = dropAxis == .horizontal ? location.x >= bounds.midX : location.y >= bounds.midY
        guard lastDropHover?.identifier != identifier || lastDropHover?.after != after else { return }
        lastDropHover = (identifier, after)
        onDropHover(identifier, after)
    }

    private func draggedItemCenterLocation(from sender: any NSDraggingInfo) -> CGPoint {
        guard let window else { return convert(sender.draggingLocation, from: nil) }
        let offset = WindowsTrayDragSessionState.shared.draggedItemCenterOffset
        let centerOnScreen = CGPoint(
            x: NSEvent.mouseLocation.x + offset.width,
            y: NSEvent.mouseLocation.y + offset.height
        )
        return convert(window.convertPoint(fromScreen: centerOnScreen), from: nil)
    }

    private func showDropTipIfNeeded() {
        guard let dropTipSymbolName, let window else { return }
        WindowsTrayTooltipController.shared.hide(owner: self)
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        WindowsTrayDropTipController.shared.show(
            symbolName: dropTipSymbolName,
            anchor: anchor,
            gap: tooltipGap,
            owner: self
        )
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

    func schedule(title: String, anchor: CGRect, gap: CGFloat, owner: WindowsTrayIconControl) {
        pendingWorkItem?.cancel()
        panel.orderOut(nil)
        self.owner = owner

        let workItem = DispatchWorkItem { [weak self, weak owner] in
            guard let self, let owner, self.owner === owner, owner.window != nil else { return }
            self.show(title: title, anchor: anchor, gap: gap)
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

    private func show(title: String, anchor: CGRect, gap: CGFloat) {
        tooltipView.title = title
        let size = WindowsTrayTooltipMetrics.size(for: title)
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main else { return }
        panel.setFrame(Self.frame(size: size, anchor: anchor, gap: gap, screen: screen.frame), display: true)
        panel.orderFrontRegardless()
    }

    static func frame(size: CGSize, anchor: CGRect, gap: CGFloat, screen: CGRect) -> CGRect {
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
            origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - gap)
        case 2:
            origin = CGPoint(x: anchor.maxX + gap, y: anchor.midY - size.height / 2)
        case 3:
            origin = CGPoint(x: anchor.minX - size.width - gap, y: anchor.midY - size.height / 2)
        default:
            origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + gap)
        }
        origin.x = min(max(origin.x, screen.minX + 6), screen.maxX - size.width - 6)
        origin.y = min(max(origin.y, screen.minY + 6), screen.maxY - size.height - 6)
        return CGRect(origin: origin, size: size)
    }
}

@MainActor
private final class WindowsTrayDropTipController {
    static let shared = WindowsTrayDropTipController()

    private let panel: WindowsTrayTooltipPanel
    private let tipView = WindowsTrayDropTipView()
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
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = tipView
    }

    func show(symbolName: String, anchor: CGRect, gap: CGFloat, owner: WindowsTrayIconControl) {
        self.owner = owner
        tipView.symbolName = symbolName
        let size = CGSize(width: 32, height: 32)
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main else { return }
        panel.setFrame(
            WindowsTrayTooltipController.frame(size: size, anchor: anchor, gap: gap, screen: screen.frame),
            display: true
        )
        panel.orderFrontRegardless()
    }

    func hide(owner: WindowsTrayIconControl) {
        guard self.owner === owner else { return }
        self.owner = nil
        panel.orderOut(nil)
    }
}

private final class WindowsTrayTooltipPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class WindowsTrayTooltipView: NSView {
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
        let attributes: [NSAttributedString.Key: Any] = [
            .font: WindowsTrayTooltipMetrics.font,
            .foregroundColor: NSColor(srgbRed: 246 / 255, green: 247 / 255, blue: 247 / 255, alpha: 1),
            .paragraphStyle: paragraph
        ]
        let lines = WindowsTrayTooltipMetrics.lines(for: title)
        let lineHeight = ceil(
            WindowsTrayTooltipMetrics.font.ascender
                - WindowsTrayTooltipMetrics.font.descender
                + WindowsTrayTooltipMetrics.font.leading
        )
        let contentHeight = CGFloat(lines.count) * lineHeight
        let originY = (bounds.height - contentHeight) / 2
        for (index, line) in lines.enumerated() where !line.isEmpty {
            (line as NSString).draw(
                in: CGRect(
                    x: WindowsTrayTooltipMetrics.horizontalPadding,
                    y: originY + CGFloat(index) * lineHeight,
                    width: bounds.width - 2 * WindowsTrayTooltipMetrics.horizontalPadding,
                    height: lineHeight
                ),
                withAttributes: attributes
            )
        }
    }
}

private final class WindowsTrayDropTipView: NSView {
    var symbolName = "pin.slash" { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 31 / 255, green: 42 / 255, blue: 52 / 255, alpha: 0.98).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        NSColor(srgbRed: 58 / 255, green: 68 / 255, blue: 77 / 255, alpha: 1).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        border.lineWidth = 1
        border.stroke()

        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            .applying(.init(paletteColors: [.white]))
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let imageSize = image.size
        image.draw(
            in: CGRect(
                x: bounds.midX - imageSize.width / 2,
                y: bounds.midY - imageSize.height / 2,
                width: imageSize.width,
                height: imageSize.height
            )
        )
    }
}
