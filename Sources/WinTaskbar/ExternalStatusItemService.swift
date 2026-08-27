import AppKit
import ApplicationServices
import Combine
import SwiftUI

struct ExternalStatusItem: Identifiable {
    let id: String
    let processIdentifier: pid_t
    let ownerName: String
    let accessibilityLabel: String
    let sourceFrame: CGRect
    let image: NSImage
}

private struct StatusItemWindow {
    let id: CGWindowID
    let frame: CGRect
}

private final class ExternalStatusMenuAction: NSObject {
    let sourceItem: AXUIElement
    let statusItem: AXUIElement
    let route: [Int]

    init(sourceItem: AXUIElement, statusItem: AXUIElement, route: [Int]) {
        self.sourceItem = sourceItem
        self.statusItem = statusItem
        self.route = route
    }
}

enum ExternalStatusItemPolicy {
    static func shouldInclude(
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        role: String?,
        frame: CGRect,
        ownProcessIdentifier: pid_t
    ) -> Bool {
        guard processIdentifier != ownProcessIdentifier,
              bundleIdentifier?.hasPrefix("com.apple.") != true,
              role == kAXMenuBarItemRole as String,
              frame.width >= 8,
              frame.width <= 160,
              frame.height >= 8,
              frame.height <= 64 else { return false }
        return true
    }
}

@MainActor
final class ExternalStatusItemService: NSObject, ObservableObject {
    @Published private(set) var items: [ExternalStatusItem] = []

    private var elements: [String: AXUIElement] = [:]
    private var timer: Timer?
    private var presentedMenu: NSMenu?

    override init() {
        super.init()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    func items(on screen: NSScreen) -> [ExternalStatusItem] {
        guard let primaryScreen = NSScreen.screens.first else { return items }
        return items.filter { item in
            let sourceFrame = item.sourceFrame
            let cocoaFrame = CGRect(
                x: sourceFrame.minX,
                y: primaryScreen.frame.maxY - sourceFrame.maxY,
                width: sourceFrame.width,
                height: sourceFrame.height
            )
            return cocoaFrame.intersects(screen.frame)
        }
    }

    func performPrimaryAction(_ item: ExternalStatusItem) {
        guard let element = elements[item.id] else {
            refresh()
            return
        }
        if children(of: element).contains(where: {
            attribute($0, kAXRoleAttribute) == kAXMenuRole as String
        }) {
            activateApplication(processIdentifier: item.processIdentifier)
            return
        }

        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        if result != .success, result != .cannotComplete {
            activateApplication(processIdentifier: item.processIdentifier)
        }
    }

    func presentContextMenu(_ item: ExternalStatusItem) {
        guard let element = elements[item.id] else {
            refresh()
            return
        }
        let popupLocation = NSEvent.mouseLocation
        if presentMirroredMenu(for: element, at: popupLocation, cancelSourceMenu: false) {
            return
        }

        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        if result == .success || result == .cannotComplete {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120)) { [weak self] in
                _ = self?.presentMirroredMenu(for: element, at: popupLocation, cancelSourceMenu: true)
            }
            return
        }

        let point = CGPoint(x: item.sourceFrame.midX, y: item.sourceFrame.midY)
        CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
        CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
    }

    @discardableResult
    private func presentMirroredMenu(
        for statusItem: AXUIElement,
        at location: CGPoint,
        cancelSourceMenu: Bool
    ) -> Bool {
        guard let sourceMenu = children(of: statusItem).first(where: {
            attribute($0, kAXRoleAttribute) == kAXMenuRole as String
        }) else { return false }
        let menu = mirroredMenu(from: sourceMenu, statusItem: statusItem, route: [])
        guard !menu.items.isEmpty else { return false }

        if cancelSourceMenu {
            _ = AXUIElementPerformAction(sourceMenu, kAXCancelAction as CFString)
        }
        presentedMenu = menu
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(40)) { [weak self] in
            guard let self, self.presentedMenu === menu else { return }
            let switchMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self, weak menu] event in
                guard let self,
                      let menu,
                      self.presentedMenu === menu,
                      let control = self.externalStatusItemControl(at: NSEvent.mouseLocation) else { return event }
                menu.cancelTracking()
                DispatchQueue.main.async { control.onRightActivate?() }
                return nil
            }
            menu.popUp(positioning: nil, at: location, in: nil)
            if let switchMonitor { NSEvent.removeMonitor(switchMonitor) }
            self.presentedMenu = nil
        }
        return true
    }

    private func externalStatusItemControl(at screenPoint: CGPoint) -> ExternalStatusItemControl? {
        for window in NSApp.windows where window.frame.contains(screenPoint) {
            guard let contentView = window.contentView else { continue }
            let windowPoint = window.convertPoint(fromScreen: screenPoint)
            let contentPoint = contentView.convert(windowPoint, from: nil)
            if let control = contentView.hitTest(contentPoint) as? ExternalStatusItemControl {
                return control
            }
        }
        return nil
    }

    private func activateApplication(processIdentifier: pid_t) {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier) else { return }
        application.unhide()
        application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    private func mirroredMenu(
        from sourceMenu: AXUIElement,
        statusItem: AXUIElement,
        route: [Int]
    ) -> NSMenu {
        let menu = NSMenu()
        for (index, sourceItem) in children(of: sourceMenu).enumerated() {
            let title: String = attribute(sourceItem, kAXTitleAttribute) ?? ""
            let itemRoute = route + [index]
            let actions = actionNames(of: sourceItem)
            let sourceSubmenu = children(of: sourceItem).first(where: {
                attribute($0, kAXRoleAttribute) == kAXMenuRole as String
            })

            if title.isEmpty, sourceSubmenu == nil {
                menu.addItem(.separator())
                continue
            }

            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            if let sourceSubmenu {
                item.submenu = mirroredMenu(from: sourceSubmenu, statusItem: statusItem, route: itemRoute)
            } else if actions.contains(kAXPickAction as String) || actions.contains(kAXPressAction as String) {
                item.target = self
                item.action = #selector(performMirroredMenuAction(_:))
                item.representedObject = ExternalStatusMenuAction(
                    sourceItem: sourceItem,
                    statusItem: statusItem,
                    route: itemRoute
                )
            }
            let enabled: Bool = attribute(sourceItem, kAXEnabledAttribute) ?? true
            item.isEnabled = enabled && (item.submenu != nil || item.action != nil)
            let mark: String? = attribute(sourceItem, kAXMenuItemMarkCharAttribute)
            item.state = mark?.isEmpty == false ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func performMirroredMenuAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? ExternalStatusMenuAction else { return }
        let result = performMenuAction(action.sourceItem)
        guard result != .success, result != .cannotComplete else { return }

        _ = AXUIElementPerformAction(action.statusItem, kAXPressAction as CFString)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120)) { [weak self] in
            guard let self,
                  let sourceItem = self.menuItem(at: action.route, in: action.statusItem) else { return }
            _ = self.performMenuAction(sourceItem)
        }
    }

    private func performMenuAction(_ item: AXUIElement) -> AXError {
        let actions = actionNames(of: item)
        if actions.contains(kAXPickAction as String) {
            return AXUIElementPerformAction(item, kAXPickAction as CFString)
        }
        return AXUIElementPerformAction(item, kAXPressAction as CFString)
    }

    private func menuItem(at route: [Int], in statusItem: AXUIElement) -> AXUIElement? {
        guard var menu = children(of: statusItem).first(where: {
            attribute($0, kAXRoleAttribute) == kAXMenuRole as String
        }) else { return nil }

        for (offset, index) in route.enumerated() {
            let menuItems = children(of: menu)
            guard menuItems.indices.contains(index) else { return nil }
            let item = menuItems[index]
            if offset == route.count - 1 { return item }
            guard let submenu = children(of: item).first(where: {
                attribute($0, kAXRoleAttribute) == kAXMenuRole as String
            }) else { return nil }
            menu = submenu
        }
        return nil
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) ?? []
    }

    private func actionNames(of element: AXUIElement) -> [String] {
        var raw: CFArray?
        guard AXUIElementCopyActionNames(element, &raw) == .success else { return [] }
        return raw as? [String] ?? []
    }

    private func refresh() {
        guard AXIsProcessTrusted() else {
            items = []
            elements = [:]
            return
        }

        var nextItems: [ExternalStatusItem] = []
        var nextElements: [String: AXUIElement] = [:]
        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let canCapture = CGPreflightScreenCaptureAccess()
        let statusItemWindows = canCapture ? visibleStatusItemWindows() : []

        for application in NSWorkspace.shared.runningApplications {
            let root = AXUIElementCreateApplication(application.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.1)
            guard let extrasMenuBar = element(root, attribute: kAXExtrasMenuBarAttribute),
                  let children: [AXUIElement] = attribute(extrasMenuBar, kAXChildrenAttribute) else { continue }

            let ownerName = application.localizedName ?? application.bundleIdentifier ?? "App"
            let fallbackImage = application.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) }

            for child in children {
                guard let frame = frame(of: child),
                      ExternalStatusItemPolicy.shouldInclude(
                          processIdentifier: application.processIdentifier,
                          bundleIdentifier: application.bundleIdentifier,
                          role: attribute(child, kAXRoleAttribute),
                          frame: frame,
                          ownProcessIdentifier: ownProcessIdentifier
                      ),
                      let image = capturedImage(frame: frame, windows: statusItemWindows) ?? fallbackImage else { continue }

                let itemID = identifier(
                    processIdentifier: application.processIdentifier,
                    frame: frame
                )
                let label = firstNonemptyString(
                    attribute(child, kAXHelpAttribute),
                    attribute(child, kAXDescriptionAttribute),
                    attribute(child, kAXTitleAttribute),
                    ownerName
                )
                nextItems.append(ExternalStatusItem(
                    id: itemID,
                    processIdentifier: application.processIdentifier,
                    ownerName: ownerName,
                    accessibilityLabel: label,
                    sourceFrame: frame,
                    image: image
                ))
                nextElements[itemID] = child
            }
        }

        items = nextItems.sorted { lhs, rhs in
            if lhs.sourceFrame.minY != rhs.sourceFrame.minY {
                return lhs.sourceFrame.minY < rhs.sourceFrame.minY
            }
            return lhs.sourceFrame.minX < rhs.sourceFrame.minX
        }
        elements = nextElements
    }

    private func visibleStatusItemWindows() -> [StatusItemWindow] {
        guard let controlCenterPID = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.controlcenter"
        })?.processIdentifier,
        let rawWindows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        return rawWindows.compactMap { window in
            guard window[kCGWindowOwnerPID as String] as? pid_t == controlCenterPID,
                  window[kCGWindowLayer as String] as? Int == 25,
                  let id = window[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.width >= 8,
                  frame.height >= 20,
                  frame.height <= 50 else { return nil }
            return StatusItemWindow(id: id, frame: frame)
        }
    }

    private func capturedImage(frame: CGRect, windows: [StatusItemWindow]) -> NSImage? {
        guard let window = windows
            .filter({ $0.frame.minX <= frame.midX && $0.frame.maxX >= frame.midX })
            .min(by: { $0.frame.width < $1.frame.width }),
              let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            window.id,
            [.boundsIgnoreFraming, .bestResolution]
        ), let trimmedImage = transparentContentImage(image) else { return nil }
        return NSImage(
            cgImage: trimmedImage,
            size: NSSize(width: trimmedImage.width, height: trimmedImage.height)
        )
    }

    private func transparentContentImage(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drewImage = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drewImage else { return nil }

        var transparentPixels = 0
        var visiblePixels = 0
        var minimumX = width
        var minimumY = height
        var maximumX = -1
        var maximumY = -1
        for y in 0..<height {
            for x in 0..<width {
                let alpha = pixels[(y * width + x) * 4 + 3]
                if alpha < 245 { transparentPixels += 1 }
                if alpha > 10 {
                    visiblePixels += 1
                    minimumX = min(minimumX, x)
                    minimumY = min(minimumY, y)
                    maximumX = max(maximumX, x)
                    maximumY = max(maximumY, y)
                }
            }
        }
        let pixelCount = width * height
        guard transparentPixels > pixelCount / 20,
              visiblePixels > pixelCount / 100,
              maximumX >= minimumX,
              maximumY >= minimumY else { return nil }

        let padding = 2
        let cropMinimumX = max(0, minimumX - padding)
        let cropMaximumX = min(width - 1, maximumX + padding)
        let normalizedMinimumY = max(0, height - 1 - maximumY - padding)
        let normalizedMaximumY = min(height - 1, height - 1 - minimumY + padding)
        return image.cropping(to: CGRect(
            x: cropMinimumX,
            y: normalizedMinimumY,
            width: cropMaximumX - cropMinimumX + 1,
            height: normalizedMaximumY - normalizedMinimumY + 1
        ))
    }

    private func identifier(processIdentifier: pid_t, frame: CGRect) -> String {
        [
            String(processIdentifier),
            String(Int(frame.minX.rounded())),
            String(Int(frame.minY.rounded())),
            String(Int(frame.width.rounded())),
            String(Int(frame.height.rounded()))
        ].joined(separator: ":")
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue: AXValue = attribute(element, kAXPositionAttribute),
              let sizeValue: AXValue = attribute(element, kAXSizeAttribute) else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func element(_ element: AXUIElement, attribute name: String) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
              let raw,
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success else { return nil }
        return raw as? T
    }

    private func firstNonemptyString(_ values: String?...) -> String {
        let nonemptyValues: [String] = values.compactMap { value -> String? in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }
        return nonemptyValues.first ?? "App"
    }
}

@MainActor
struct ExternalStatusItemsView: View {
    @ObservedObject var service: ExternalStatusItemService
    let screen: NSScreen
    let horizontal: Bool

    var body: some View {
        let items = service.items(on: screen)
        Group {
            if horizontal {
                HStack(spacing: 0) { buttons(items) }
            } else {
                VStack(spacing: 0) { buttons(items) }
            }
        }
    }

    @ViewBuilder
    private func buttons(_ items: [ExternalStatusItem]) -> some View {
        ForEach(items) { item in
            ExternalStatusItemButton(
                image: item.image,
                label: item.accessibilityLabel,
                help: "\(item.ownerName): \(item.accessibilityLabel)",
                primaryAction: { service.performPrimaryAction(item) },
                contextAction: { service.presentContextMenu(item) }
            )
            .frame(width: Self.controlWidth(for: item.image), height: 40)
        }
    }

    static func controlWidth(for image: NSImage) -> CGFloat {
        guard image.size.height > 0 else { return 32 }
        let imageWidth = 18 * image.size.width / image.size.height
        return min(max(imageWidth, 18), 40) + 14
    }
}

@MainActor
private struct ExternalStatusItemButton: NSViewRepresentable {
    let image: NSImage
    let label: String
    let help: String
    let primaryAction: () -> Void
    let contextAction: () -> Void

    func makeNSView(context: Context) -> ExternalStatusItemControl {
        let control = ExternalStatusItemControl()
        update(control)
        return control
    }

    func updateNSView(_ control: ExternalStatusItemControl, context: Context) {
        update(control)
    }

    private func update(_ control: ExternalStatusItemControl) {
        control.image = image
        control.toolTip = help
        control.onLeftActivate = primaryAction
        control.onRightActivate = contextAction
        control.setAccessibilityElement(true)
        control.setAccessibilityRole(.button)
        control.setAccessibilityLabel(label)
    }
}

@MainActor
private final class ExternalStatusItemControl: NSControl {
    var image: NSImage? { didSet { needsDisplay = true } }
    var onLeftActivate: (() -> Void)?
    var onRightActivate: (() -> Void)?
    private var trackingAreaReference: NSTrackingArea?
    private var isHovered = false
    private var isPressed = false

    override var isFlipped: Bool { true }

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
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        activate(onLeftActivate)
    }

    override func rightMouseDown(with event: NSEvent) {
        activate(onRightActivate)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isHovered || isPressed {
            NSColor.labelColor.withAlphaComponent(isPressed ? 0.16 : 0.10).setFill()
            NSBezierPath(
                roundedRect: bounds,
                xRadius: 4,
                yRadius: 4
            ).fill()
        }
        guard let image else { return }
        let imageBounds = CGRect(
            x: bounds.minX + 7,
            y: bounds.midY - 9,
            width: max(0, bounds.width - 14),
            height: 18
        )
        image.draw(
            in: aspectFitRect(for: image.size, inside: imageBounds),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    private func activate(_ action: (() -> Void)?) {
        isPressed = true
        needsDisplay = true
        displayIfNeeded()
        action?()
        isPressed = false
        needsDisplay = true
    }

    private func aspectFitRect(for size: CGSize, inside bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: bounds.midX - targetSize.width / 2,
            y: bounds.midY - targetSize.height / 2,
            width: targetSize.width,
            height: targetSize.height
        )
    }
}
