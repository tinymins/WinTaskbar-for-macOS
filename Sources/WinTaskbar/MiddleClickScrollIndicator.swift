import AppKit

/// Windows Chromium supplies 32×32 cursor bitmaps with a (16,16) hotspot.
/// Render the same artwork at the click and pointer without activating the target window.
@MainActor
final class MiddleClickScrollIndicator {
    private enum Axes: Sendable {
        case vertical, horizontal, both

        var center: String {
            switch self {
            case .vertical: "middle_vertical"
            case .horizontal: "middle_horizontal"
            case .both: "middle"
            }
        }

        func cursor(offset: CGPoint) -> String? {
            let radius = MiddleClickScrollMotion.deadZone
            guard hypot(offset.x, offset.y) > radius else { return nil }
            var dx = self == .vertical ? 0 : offset.x
            var dy = self == .horizontal ? 0 : offset.y
            // Chromium ignores minor axis drift for its directional artwork.
            // A diagonal can leave our circular dead zone with both components below the radius.
            if self == .both, max(abs(dx), abs(dy)) > radius {
                if abs(dx) <= radius { dx = 0 }
                if abs(dy) <= radius { dy = 0 }
            }
            let x = dx == 0 ? "" : (dx < 0 ? "west" : "east")
            let y = dy == 0 ? "" : (dy < 0 ? "north" : "south")
            if x.isEmpty { return y.isEmpty ? center : y }
            return y.isEmpty ? x : "\(y)_\(x)"
        }
    }

    private static let images: [String: NSImage] = {
        var bundle = Bundle.main
        #if SWIFT_PACKAGE
        if bundle.bundleURL.pathExtension != "app" { bundle = .module }
        #endif
        let names = ["middle", "middle_vertical", "middle_horizontal", "north", "south",
                     "west", "east", "north_west", "north_east", "south_west", "south_east"]
        var images: [String: NSImage] = [:]
        for name in names {
            guard let url = bundle.url(forResource: "pan_" + name, withExtension: "cur", subdirectory: "AutoscrollCursors"),
                  let image = NSImage(contentsOf: url) else { continue }
            images[name] = image
        }
        return images
    }()

    private let anchor = CursorPanel()
    private let pointer = CursorPanel()
    private let origin: CGPoint
    private let pid: pid_t
    private var axes: Axes
    private var axisLookup: Task<Void, Never>?
    private var hiddenDisplay: CGDirectDisplayID?
    private var lastPosition: CGPoint?

    init(origin: CGPoint, target: NSRunningApplication) {
        self.origin = origin
        pid = target.processIdentifier
        // iTerm2 can hide its scrollbar even when terminal history is scrollable.
        axes = target.bundleIdentifier == "com.googlecode.iterm2" ? .vertical : .both
    }

    func show() {
        guard let image = Self.images[axes.center] else { return }
        anchor.show(image, at: origin)
        let display = CGMainDisplayID() // Core Graphics balances this hide/show count across displays.
        if CGDisplayHideCursor(display) == .success { hiddenDisplay = display }

        let pid = pid, origin = origin
        axisLookup = Task { [weak self] in
            let axes = await Task.detached {
                Self.scrollAxes(at: origin, pid: pid)
            }.value
            guard !Task.isCancelled, let self, let axes, axes != self.axes,
                  let image = Self.images[axes.center] else { return }
            self.axes = axes
            self.anchor.show(image, at: origin)
            if let position = self.lastPosition {
                self.lastPosition = nil
                self.update(at: position)
            }
        }
    }

    func update(at location: CGPoint) {
        guard location != lastPosition, hiddenDisplay != nil else { return }
        lastPosition = location
        let offset = CGPoint(x: location.x - origin.x, y: location.y - origin.y)
        // Only one copy of the central cursor should cover its hotspot.
        guard let cursor = axes.cursor(offset: offset) else {
            if pointer.isVisible { pointer.orderOut(nil) }
            return
        }
        if let image = Self.images[cursor] { pointer.show(image, at: location) }
    }

    func hide() {
        axisLookup?.cancel()
        axisLookup = nil
        pointer.orderOut(nil)
        anchor.orderOut(nil)
        if let hiddenDisplay {
            CGDisplayShowCursor(hiddenDisplay)
            self.hiddenDisplay = nil
        }
    }

    private nonisolated static func scrollAxes(at point: CGPoint, pid: pid_t) -> Axes? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &element) == .success else { return nil }
        while let current = element {
            AXUIElementSetMessagingTimeout(current, 0.1)
            func attribute(_ key: String) -> CFTypeRef? {
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(current, key as CFString, &value) == .success else { return nil }
                return value
            }
            if attribute(kAXRoleAttribute) as? String == kAXScrollAreaRole {
                let vertical = attribute(kAXVerticalScrollBarAttribute) != nil
                let horizontal = attribute(kAXHorizontalScrollBarAttribute) != nil
                if vertical && horizontal { return .both }
                if vertical { return .vertical }
                if horizontal { return .horizontal }
            }
            guard let parent = attribute(kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID(),
                  !CFEqual(parent, current) else { break }
            element = (parent as! AXUIElement)
        }
        return nil
    }

    @MainActor
    private final class CursorPanel: NSPanel {
        private let artwork = NSImageView(frame: NSRect(x: 0, y: 0, width: 32, height: 32))

        init() {
            super.init(contentRect: artwork.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            isOpaque = false
            backgroundColor = .clear
            hasShadow = false
            ignoresMouseEvents = true
            hidesOnDeactivate = false
            level = .init(rawValue: Int(CGWindowLevelForKey(.cursorWindow)) + 1)
            collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            artwork.imageScaling = .scaleNone
            contentView = artwork
        }

        func show(_ image: NSImage, at point: CGPoint) {
            if artwork.image !== image { artwork.image = image }
            let height = CGDisplayBounds(CGMainDisplayID()).height
            setFrameOrigin(NSPoint(x: point.x - 16, y: height - point.y - 16))
            if !isVisible { orderFrontRegardless() }
        }
    }
}
