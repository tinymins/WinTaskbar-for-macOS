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
    static let tooltipGap = StartMenuGeometry.taskbarGap
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
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 8
    static let minimumWidth: CGFloat = 32
    static let maximumWidth: CGFloat = 280

    static func lines(for title: String) -> [String] {
        title.components(separatedBy: "\n")
    }

    static func size(for title: String) -> CGSize {
        let lines = lines(for: title)
        let textWidth = lines.map {
            ($0 as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 0
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let height = ceil(CGFloat(lines.count) * lineHeight + 2 * verticalPadding)
        return CGSize(
            width: min(max(ceil(textWidth) + 2 * horizontalPadding, minimumWidth), maximumWidth),
            height: height
        )
    }
}

@MainActor
enum WindowsTrayTooltipSurfaceStyle {
    static let cornerRadius: CGFloat = 8
    static let borderWidth: CGFloat = 0.5

    static func apply(to view: NSVisualEffectView) {
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = borderWidth
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
    }

    static func makeSurface(contentView: NSView) -> NSVisualEffectView {
        let surface = NSVisualEffectView()
        apply(to: surface)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: surface.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: surface.bottomAnchor)
        ])
        return surface
    }
}

@MainActor
enum WindowsTrayTooltipContentStyle {
    static func makeLabels(for title: String) -> [NSTextField] {
        WindowsTrayTooltipMetrics.lines(for: title).map { line in
            makeLabel(text: line)
        }
    }

    private static func makeLabel(text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = WindowsTrayTooltipMetrics.font
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        return label
    }
}

enum WindowsTrayTooltipGeometry {
    static let screenInset: CGFloat = 8

    static func frame(
        size: CGSize,
        anchor: CGRect,
        taskbarFrame: CGRect,
        position explicitPosition: TaskbarPosition?,
        screen: CGRect
    ) -> CGRect {
        let distances = [
            (position: TaskbarPosition.bottom, distance: abs(anchor.minY - screen.minY)),
            (position: TaskbarPosition.top, distance: abs(screen.maxY - anchor.maxY)),
            (position: TaskbarPosition.left, distance: abs(anchor.minX - screen.minX)),
            (position: TaskbarPosition.right, distance: abs(screen.maxX - anchor.maxX))
        ]
        let position = explicitPosition
            ?? distances.min(by: { $0.distance < $1.distance })?.position
            ?? .bottom
        let boundary = explicitPosition == nil ? anchor : taskbarFrame
        var origin: CGPoint
        switch position {
        case .top:
            origin = CGPoint(
                x: anchor.midX - size.width / 2,
                y: boundary.minY - size.height - WindowsTrayIconMetrics.tooltipGap
            )
        case .left:
            origin = CGPoint(
                x: boundary.maxX + WindowsTrayIconMetrics.tooltipGap,
                y: anchor.midY - size.height / 2
            )
        case .right:
            origin = CGPoint(
                x: boundary.minX - size.width - WindowsTrayIconMetrics.tooltipGap,
                y: anchor.midY - size.height / 2
            )
        case .bottom:
            origin = CGPoint(
                x: anchor.midX - size.width / 2,
                y: boundary.maxY + WindowsTrayIconMetrics.tooltipGap
            )
        }
        switch position {
        case .bottom, .top:
            origin.x = min(
                max(origin.x, screen.minX + screenInset),
                screen.maxX - size.width - screenInset
            )
        case .left, .right:
            origin.y = min(
                max(origin.y, screen.minY + screenInset),
                screen.maxY - size.height - screenInset
            )
        }
        return CGRect(origin: origin, size: size)
    }
}

@MainActor
enum WindowsTrayTooltipPanelPolicy {
    static func keepVisibleWhileApplicationIsInactive(_ panel: NSPanel) {
        panel.hidesOnDeactivate = false
    }
}

@MainActor
struct WindowsTrayIconButton<Content: View>: NSViewRepresentable {
    let title: String
    let accessibilityLabel: String
    let taskbarPosition: TaskbarPosition?
    let visualStyle: WindowsTrayIconAppearance
    let preservesTransientPanelOnMouseDown: Bool
    let primaryAction: (WindowsTrayIconControl) -> Void
    let contextAction: (() -> Void)?
    let pointerAction: ((WindowsTrayIconControl, CGPoint?) -> Void)?
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
        taskbarPosition: TaskbarPosition? = nil,
        visualStyle: WindowsTrayIconAppearance = .standard,
        preservesTransientPanelOnMouseDown: Bool = false,
        primaryAction: @escaping () -> Void,
        contextAction: (() -> Void)? = nil,
        pointerAction: ((WindowsTrayIconControl, CGPoint?) -> Void)? = nil,
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
        self.taskbarPosition = taskbarPosition
        self.visualStyle = visualStyle
        self.preservesTransientPanelOnMouseDown = preservesTransientPanelOnMouseDown
        self.primaryAction = { _ in primaryAction() }
        self.contextAction = contextAction
        self.pointerAction = pointerAction
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
        taskbarPosition: TaskbarPosition? = nil,
        visualStyle: WindowsTrayIconAppearance = .standard,
        preservesTransientPanelOnMouseDown: Bool = false,
        anchoredPrimaryAction: @escaping (WindowsTrayIconControl) -> Void,
        contextAction: (() -> Void)? = nil,
        pointerAction: ((WindowsTrayIconControl, CGPoint?) -> Void)? = nil,
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
        self.taskbarPosition = taskbarPosition
        self.visualStyle = visualStyle
        self.preservesTransientPanelOnMouseDown = preservesTransientPanelOnMouseDown
        self.primaryAction = anchoredPrimaryAction
        self.contextAction = contextAction
        self.pointerAction = pointerAction
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
        control.taskbarPosition = taskbarPosition
        control.visualStyle = visualStyle
        control.preservesTransientPanelOnMouseDown = preservesTransientPanelOnMouseDown
        control.onLeftActivate = { [weak control] in
            guard let control else { return }
            primaryAction(control)
        }
        control.onRightActivate = contextAction
        control.onPointerMove = { [weak control] location in
            guard let control else { return }
            pointerAction?(control, location)
        }
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
        .mouseMoved,
        .inVisibleRect,
    ]

    var hoverTitle = ""
    var taskbarPosition: TaskbarPosition?
    var visualStyle = WindowsTrayIconAppearance.standard
    var preservesTransientPanelOnMouseDown = false
    var onLeftActivate: (() -> Void)?
    var onRightActivate: (() -> Void)?
    var onPointerMove: ((CGPoint?) -> Void)?
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
    private(set) var activationLocation: CGPoint?

    private var hostingView: NSHostingView<AnyView>?
    private var trackingAreaReference: NSTrackingArea?
    private var isHovered = false
    private var isPressed = false
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
        onPointerMove?(convert(event.locationInWindow, from: nil))
        guard !hoverTitle.isEmpty, let window else { return }
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        WindowsTrayTooltipController.shared.schedule(
            title: hoverTitle,
            anchor: anchor,
            taskbarFrame: window.frame,
            position: taskbarPosition,
            owner: self
        )
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
        onPointerMove?(nil)
        WindowsTrayTooltipController.shared.hide(owner: self)
    }

    override func mouseMoved(with event: NSEvent) {
        onPointerMove?(convert(event.locationInWindow, from: nil))
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
        let location = convert(event.locationInWindow, from: nil)
        mouseDownLocation = nil
        if didBeginDrag {
            didBeginDrag = false
            isPressed = false
            needsDisplay = true
            return
        }
        let shouldActivate = isPressed && bounds.contains(location)
        isPressed = false
        needsDisplay = true
        displayIfNeeded()
        if shouldActivate {
            activationLocation = location
            perform(onLeftActivate)
            activationLocation = nil
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let onRightActivate else { return }
        perform(onRightActivate)
    }

    override func accessibilityPerformPress() -> Bool {
        activationLocation = nil
        perform(onLeftActivate)
        return onLeftActivate != nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            onPointerMove?(nil)
            WindowsTrayTooltipController.shared.hide(owner: self)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard WindowsTrayDragSessionState.shared.draggedItemID == nil,
              !isDragging,
              isHovered || isPressed else { return }
        switch visualStyle {
        case .standard:
            let opacity = isPressed
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
        lastDropHover = nil
        needsDisplay = true
        WindowsTrayDropTipController.shared.hide(owner: self)
        return true
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
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
            owner: self
        )
    }
}

@MainActor
private final class WindowsTrayTooltipController {
    static let shared = WindowsTrayTooltipController()

    private let panel: WindowsTrayTooltipPanel
    private let tooltipView: WindowsTrayTooltipView
    private let surfaceView: NSVisualEffectView
    private var pendingWorkItem: DispatchWorkItem?
    private weak var owner: WindowsTrayIconControl?

    private init() {
        let tooltipView = WindowsTrayTooltipView()
        self.tooltipView = tooltipView
        surfaceView = WindowsTrayTooltipSurfaceStyle.makeSurface(contentView: tooltipView)
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
        WindowsTrayTooltipPanelPolicy.keepVisibleWhileApplicationIsInactive(panel)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = surfaceView
    }

    func schedule(
        title: String,
        anchor: CGRect,
        taskbarFrame: CGRect,
        position: TaskbarPosition?,
        owner: WindowsTrayIconControl
    ) {
        pendingWorkItem?.cancel()
        panel.orderOut(nil)
        panel.appearance = owner.effectiveAppearance
        self.owner = owner

        let workItem = DispatchWorkItem { [weak self, weak owner] in
            guard let self, let owner, self.owner === owner, owner.window != nil else { return }
            self.show(
                title: title,
                anchor: anchor,
                taskbarFrame: taskbarFrame,
                position: position
            )
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

    private func show(
        title: String,
        anchor: CGRect,
        taskbarFrame: CGRect,
        position: TaskbarPosition?
    ) {
        tooltipView.title = title
        let size = WindowsTrayTooltipMetrics.size(for: title)
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main else { return }
        panel.setFrame(
            WindowsTrayTooltipGeometry.frame(
                size: size,
                anchor: anchor,
                taskbarFrame: taskbarFrame,
                position: position,
                screen: screen.frame
            ),
            display: true
        )
        panel.orderFrontRegardless()
    }

}

@MainActor
private final class WindowsTrayDropTipController {
    static let shared = WindowsTrayDropTipController()

    private let panel: WindowsTrayTooltipPanel
    private let tipView: WindowsTrayDropTipView
    private let surfaceView: NSVisualEffectView
    private weak var owner: WindowsTrayIconControl?

    private init() {
        let tipView = WindowsTrayDropTipView()
        self.tipView = tipView
        surfaceView = WindowsTrayTooltipSurfaceStyle.makeSurface(contentView: tipView)
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
        WindowsTrayTooltipPanelPolicy.keepVisibleWhileApplicationIsInactive(panel)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = surfaceView
    }

    func show(symbolName: String, anchor: CGRect, owner: WindowsTrayIconControl) {
        self.owner = owner
        panel.appearance = owner.effectiveAppearance
        tipView.symbolName = symbolName
        let size = CGSize(width: 32, height: 32)
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main else { return }
        panel.setFrame(
            WindowsTrayTooltipGeometry.frame(
                size: size,
                anchor: anchor,
                taskbarFrame: owner.window?.frame ?? anchor,
                position: owner.taskbarPosition,
                screen: screen.frame
            ),
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
    private let stackView = NSStackView()
    private var storedTitle = ""

    var title: String {
        get { storedTitle }
        set {
            storedTitle = newValue
            stackView.arrangedSubviews.forEach { view in
                stackView.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            WindowsTrayTooltipContentStyle.makeLabels(for: newValue).forEach {
                stackView.addArrangedSubview($0)
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stackView.orientation = .vertical
        stackView.alignment = .width
        stackView.distribution = .fillEqually
        stackView.spacing = 0
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: WindowsTrayTooltipMetrics.horizontalPadding
            ),
            stackView.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -WindowsTrayTooltipMetrics.horizontalPadding
            ),
            stackView.topAnchor.constraint(
                equalTo: topAnchor,
                constant: WindowsTrayTooltipMetrics.verticalPadding
            ),
            stackView.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -WindowsTrayTooltipMetrics.verticalPadding
            )
        ])
    }

    required init?(coder: NSCoder) { nil }
}

private final class WindowsTrayDropTipView: NSView {
    private let imageView = NSImageView()

    var symbolName = "pin.slash" { didSet { updateImage() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        updateImage()
    }

    required init?(coder: NSCoder) { nil }

    private func updateImage() {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            .applying(.init(paletteColors: [.labelColor]))
        imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }
}
