import AppKit
@preconcurrency import ApplicationServices
import Combine
import SwiftUI

struct ExternalStatusItem: Identifiable {
    let id: String
    let processIdentifier: pid_t
    let accessibilityLabel: String
    let sourceFrame: CGRect
    let image: NSImage
}

enum ExternalStatusItemVisibility {
    case visible
    case hidden
}

struct ExternalStatusItemLayout: Equatable {
    private(set) var orderedIDs: [String]
    private(set) var hiddenIDs: Set<String>

    init(orderedIDs: [String] = [], hiddenIDs: Set<String> = []) {
        var seen = Set<String>()
        self.orderedIDs = orderedIDs.filter { seen.insert($0).inserted }
        self.hiddenIDs = hiddenIDs
    }

    mutating func reconcile(discoveredIDs: [String], beforeIDs: Set<String> = []) {
        var known = Set(orderedIDs)
        let newIDs = discoveredIDs.filter { known.insert($0).inserted }
        let insertionIndex = orderedIDs.firstIndex(where: beforeIDs.contains) ?? orderedIDs.endIndex
        orderedIDs.insert(contentsOf: newIDs, at: insertionIndex)
    }

    mutating func setHidden(_ hidden: Bool, itemID: String) {
        if hidden { hiddenIDs.insert(itemID) }
        else { hiddenIDs.remove(itemID) }
    }

    mutating func move(
        itemID: String,
        relativeTo destinationID: String,
        after: Bool,
        hidden: Bool
    ) {
        guard itemID != destinationID,
              let sourceIndex = orderedIDs.firstIndex(of: itemID),
              let destinationIndex = orderedIDs.firstIndex(of: destinationID) else {
            setHidden(hidden, itemID: itemID)
            return
        }

        let value = orderedIDs.remove(at: sourceIndex)
        let adjustedDestination = sourceIndex < destinationIndex ? destinationIndex - 1 : destinationIndex
        orderedIDs.insert(value, at: after ? adjustedDestination + 1 : adjustedDestination)
        setHidden(hidden, itemID: itemID)
    }

    func ordered(_ items: [ExternalStatusItem]) -> [ExternalStatusItem] {
        ordered(items, id: \ExternalStatusItem.id)
    }

    func ordered<Item>(_ items: [Item], id: (Item) -> String) -> [Item] {
        let rank = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($1, $0) })
        return items.sorted {
            let lhsID = id($0)
            let rhsID = id($1)
            return (rank[lhsID] ?? Int.max, lhsID) < (rank[rhsID] ?? Int.max, rhsID)
        }
    }
}

struct ExternalStatusItemIdentity {
    static func make(
        ownerIdentifier: String,
        accessibilityIdentifier: String?,
        childIndex: Int
    ) -> String {
        let itemIdentifier = accessibilityIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ownerIdentifier + "|" + ((itemIdentifier?.isEmpty == false ? itemIdentifier : nil) ?? "item-\(childIndex)")
    }
}

final class ExternalStatusItemLayoutStore {
    private static let orderKey = "wintaskbar.externalStatusItems.order"
    private static let hiddenKey = "wintaskbar.externalStatusItems.hidden"
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func load() -> ExternalStatusItemLayout {
        ExternalStatusItemLayout(
            orderedIDs: defaults.stringArray(forKey: Self.orderKey) ?? [],
            hiddenIDs: Set(defaults.stringArray(forKey: Self.hiddenKey) ?? [])
        )
    }

    func save(_ layout: ExternalStatusItemLayout) {
        defaults.set(layout.orderedIDs, forKey: Self.orderKey)
        defaults.set(layout.hiddenIDs.sorted(), forKey: Self.hiddenKey)
    }
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
    static func shouldInspectApplication(
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        ownProcessIdentifier: pid_t
    ) -> Bool {
        processIdentifier != ownProcessIdentifier
            && bundleIdentifier?.hasPrefix("com.apple.") != true
    }

    static func shouldInclude(
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        role: String?,
        frame: CGRect,
        ownProcessIdentifier: pid_t
    ) -> Bool {
        guard shouldInspectApplication(
                  processIdentifier: processIdentifier,
                  bundleIdentifier: bundleIdentifier,
                  ownProcessIdentifier: ownProcessIdentifier
              ),
              role == kAXMenuBarItemRole as String,
              frame.width >= 8,
              frame.width <= 160,
              frame.height >= 8,
              frame.height <= 64 else { return false }
        return true
    }
}

private struct ExternalStatusApplicationSnapshot: Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let bundleURL: URL?
    let localizedName: String?
}

private struct ExternalStatusItemSnapshot: Sendable {
    let id: String
    let processIdentifier: pid_t
    let accessibilityLabel: String
    let sourceFrame: CGRect
    let capturedImage: CGImage?
    let fallbackURL: URL?
    let element: AXUIElement
}

private enum ExternalStatusItemDiscovery {
    static func discover(
        applications: [ExternalStatusApplicationSnapshot],
        controlCenterProcessIdentifier: pid_t?,
        canCapture: Bool,
        ownProcessIdentifier: pid_t
    ) -> [ExternalStatusItemSnapshot] {
        let statusItemWindows = canCapture
            ? visibleStatusItemWindows(controlCenterProcessIdentifier: controlCenterProcessIdentifier)
            : []
        var items: [ExternalStatusItemSnapshot] = []

        for application in applications {
            let root = AXUIElementCreateApplication(application.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.1)
            guard let extrasMenuBar = element(root, attribute: kAXExtrasMenuBarAttribute) else { continue }
            AXUIElementSetMessagingTimeout(extrasMenuBar, 0.1)
            guard let children: [AXUIElement] = attribute(extrasMenuBar, kAXChildrenAttribute) else { continue }

            let ownerName = application.localizedName ?? application.bundleIdentifier ?? "App"
            let ownerIdentifier = application.bundleIdentifier
                ?? application.bundleURL?.path
                ?? ownerName
            var identifierOccurrences: [String: Int] = [:]

            for (childIndex, child) in children.enumerated() {
                AXUIElementSetMessagingTimeout(child, 0.1)
                guard let frame = frame(of: child),
                      ExternalStatusItemPolicy.shouldInclude(
                          processIdentifier: application.processIdentifier,
                          bundleIdentifier: application.bundleIdentifier,
                          role: attribute(child, kAXRoleAttribute),
                          frame: frame,
                          ownProcessIdentifier: ownProcessIdentifier
                      ) else { continue }

                let baseItemID = ExternalStatusItemIdentity.make(
                    ownerIdentifier: ownerIdentifier,
                    accessibilityIdentifier: attribute(child, kAXIdentifierAttribute),
                    childIndex: childIndex
                )
                let occurrence = identifierOccurrences[baseItemID, default: 0]
                identifierOccurrences[baseItemID] = occurrence + 1
                let itemID = occurrence == 0 ? baseItemID : "\(baseItemID)#\(occurrence)"
                let label = firstNonemptyString(
                    attribute(child, kAXHelpAttribute),
                    attribute(child, kAXDescriptionAttribute),
                    attribute(child, kAXTitleAttribute),
                    ownerName
                )
                items.append(ExternalStatusItemSnapshot(
                    id: itemID,
                    processIdentifier: application.processIdentifier,
                    accessibilityLabel: label,
                    sourceFrame: frame,
                    capturedImage: capturedImage(frame: frame, windows: statusItemWindows),
                    fallbackURL: application.bundleURL,
                    element: child
                ))
            }
        }

        return items.sorted { lhs, rhs in
            if lhs.sourceFrame.minY != rhs.sourceFrame.minY {
                return lhs.sourceFrame.minY < rhs.sourceFrame.minY
            }
            return lhs.sourceFrame.minX < rhs.sourceFrame.minX
        }
    }

    private static func visibleStatusItemWindows(
        controlCenterProcessIdentifier: pid_t?
    ) -> [StatusItemWindow] {
        guard let controlCenterProcessIdentifier,
              let rawWindows = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements],
                  kCGNullWindowID
              ) as? [[String: Any]] else { return [] }

        return rawWindows.compactMap { window in
            guard window[kCGWindowOwnerPID as String] as? pid_t == controlCenterProcessIdentifier,
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

    private static func capturedImage(
        frame: CGRect,
        windows: [StatusItemWindow]
    ) -> CGImage? {
        guard let window = windows
            .filter({ $0.frame.minX <= frame.midX && $0.frame.maxX >= frame.midX })
            .min(by: { $0.frame.width < $1.frame.width }),
              let image = CGWindowListCreateImage(
                  .null,
                  .optionIncludingWindow,
                  window.id,
                  [.boundsIgnoreFraming, .bestResolution]
              ) else { return nil }
        return transparentContentImage(image)
    }

    private static func transparentContentImage(_ image: CGImage) -> CGImage? {
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
                let offset = (y * width + x) * 4
                let alpha = pixels[offset + 3]
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

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue: AXValue = attribute(element, kAXPositionAttribute),
              let sizeValue: AXValue = attribute(element, kAXSizeAttribute) else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func element(_ element: AXUIElement, attribute name: String) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
              let raw,
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success else { return nil }
        return raw as? T
    }

    private static func firstNonemptyString(_ values: String?...) -> String {
        values.compactMap { value -> String? in
            guard let value,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }.first ?? "App"
    }
}

@MainActor
final class ExternalStatusItemService: NSObject, ObservableObject {
    @Published private(set) var items: [ExternalStatusItem] = []
    @Published private(set) var layout: ExternalStatusItemLayout

    private var elements: [String: AXUIElement] = [:]
    private let layoutStore: ExternalStatusItemLayoutStore
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var presentedMenu: NSMenu?

    init(defaults: UserDefaults = .standard) {
        let layoutStore = ExternalStatusItemLayoutStore(defaults: defaults)
        self.layoutStore = layoutStore
        var layout = layoutStore.load()
        layout.reconcile(discoveredIDs: SystemTrayItemID.allCases.map(\.rawValue))
        for item in SystemTrayItemID.allCases {
            layout.setHidden(false, itemID: item.rawValue)
        }
        self.layout = layout
        layoutStore.save(layout)
        super.init()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    isolated deinit {
        timer?.invalidate()
        refreshTask?.cancel()
    }

    func items(
        on screen: NSScreen,
        visibility: ExternalStatusItemVisibility = .visible
    ) -> [ExternalStatusItem] {
        guard let primaryScreen = NSScreen.screens.first else { return items }
        let screenItems = items.filter { item in
            let sourceFrame = item.sourceFrame
            let cocoaFrame = CGRect(
                x: sourceFrame.minX,
                y: primaryScreen.frame.maxY - sourceFrame.maxY,
                width: sourceFrame.width,
                height: sourceFrame.height
            )
            return cocoaFrame.intersects(screen.frame)
        }
        return layout.ordered(screenItems).filter { item in
            let isHidden = layout.hiddenIDs.contains(item.id)
            return visibility == .hidden ? isHidden : !isHidden
        }
    }

    func allItems(on screen: NSScreen) -> [ExternalStatusItem] {
        items(on: screen, visibility: .visible) + items(on: screen, visibility: .hidden)
    }

    func orderedTrayItems<Item>(_ items: [Item], id: (Item) -> String) -> [Item] {
        layout.ordered(items, id: id)
    }

    func isExternalItem(_ itemID: String) -> Bool {
        items.contains { $0.id == itemID }
    }

    func isHidden(_ itemID: String) -> Bool {
        layout.hiddenIDs.contains(itemID)
    }

    func setHidden(_ hidden: Bool, itemID: String) {
        updateLayout { $0.setHidden(hidden, itemID: itemID) }
    }

    func toggleHidden(itemID: String) {
        setHidden(!isHidden(itemID), itemID: itemID)
    }

    func move(
        itemID: String,
        relativeTo destinationID: String,
        after: Bool,
        visibility: ExternalStatusItemVisibility
    ) {
        updateLayout {
            $0.move(
                itemID: itemID,
                relativeTo: destinationID,
                after: after,
                hidden: visibility == .hidden
            )
        }
    }

    private func updateLayout(_ mutation: (inout ExternalStatusItemLayout) -> Void) {
        var nextLayout = layout
        mutation(&nextLayout)
        guard nextLayout != layout else { return }
        layout = nextLayout
        layoutStore.save(nextLayout)
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

    private func externalStatusItemControl(at screenPoint: CGPoint) -> WindowsTrayIconControl? {
        for window in NSApp.windows where window.frame.contains(screenPoint) {
            guard let contentView = window.contentView else { continue }
            let windowPoint = window.convertPoint(fromScreen: screenPoint)
            let contentPoint = contentView.convert(windowPoint, from: nil)
            if let control = contentView.hitTest(contentPoint) as? WindowsTrayIconControl,
               control.onRightActivate != nil {
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
            refreshTask?.cancel()
            refreshTask = nil
            items = []
            elements = [:]
            return
        }
        guard refreshTask == nil else { return }

        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let applications: [ExternalStatusApplicationSnapshot] = NSWorkspace.shared.runningApplications.compactMap {
            application in
            guard ExternalStatusItemPolicy.shouldInspectApplication(
                processIdentifier: application.processIdentifier,
                bundleIdentifier: application.bundleIdentifier,
                ownProcessIdentifier: ownProcessIdentifier
            ) else { return nil }
            return ExternalStatusApplicationSnapshot(
                processIdentifier: application.processIdentifier,
                bundleIdentifier: application.bundleIdentifier,
                bundleURL: application.bundleURL,
                localizedName: application.localizedName
            )
        }
        let canCapture = CGPreflightScreenCaptureAccess()
        let controlCenterProcessIdentifier = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.controlcenter"
        })?.processIdentifier
        refreshTask = Task { [weak self] in
            let snapshots = await Task.detached(priority: .utility) {
                ExternalStatusItemDiscovery.discover(
                    applications: applications,
                    controlCenterProcessIdentifier: controlCenterProcessIdentifier,
                    canCapture: canCapture,
                    ownProcessIdentifier: ownProcessIdentifier
                )
            }.value
            guard let self, !Task.isCancelled else { return }
            apply(snapshots)
            refreshTask = nil
        }
    }

    private func apply(_ snapshots: [ExternalStatusItemSnapshot]) {
        var nextItems: [ExternalStatusItem] = []
        var nextElements: [String: AXUIElement] = [:]
        for snapshot in snapshots {
            let image: NSImage?
            if let capturedImage = snapshot.capturedImage {
                image = NSImage(
                    cgImage: capturedImage,
                    size: NSSize(width: capturedImage.width, height: capturedImage.height)
                )
            } else if let fallbackURL = snapshot.fallbackURL {
                image = NSWorkspace.shared.icon(forFile: fallbackURL.path)
            } else {
                image = nil
            }
            guard let image else { continue }
            nextItems.append(ExternalStatusItem(
                id: snapshot.id,
                processIdentifier: snapshot.processIdentifier,
                accessibilityLabel: snapshot.accessibilityLabel,
                sourceFrame: snapshot.sourceFrame,
                image: image
            ))
            nextElements[snapshot.id] = snapshot.element
        }

        items = nextItems
        var nextLayout = layout
        nextLayout.reconcile(
            discoveredIDs: nextItems.map(\.id),
            beforeIDs: Set(SystemTrayItemID.allCases.map(\.rawValue))
        )
        if nextLayout != layout {
            layout = nextLayout
            layoutStore.save(nextLayout)
        }
        elements = nextElements
    }

    private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success else { return nil }
        return raw as? T
    }

}

@MainActor
struct ExternalStatusItemsView: View {
    @ObservedObject var service: ExternalStatusItemService
    let screen: NSScreen
    let horizontal: Bool
    var visibility = ExternalStatusItemVisibility.visible
    var onActivate: (() -> Void)?

    var body: some View {
        let items = service.items(on: screen, visibility: visibility)
        Group {
            if horizontal { HStack(spacing: 0) { buttons(items) } }
            else { VStack(spacing: 0) { buttons(items) } }
        }
    }

    @ViewBuilder
    private func buttons(_ items: [ExternalStatusItem]) -> some View {
        ForEach(items) { item in
            ExternalStatusItemButton(
                item: item,
                service: service,
                visibility: visibility,
                horizontal: horizontal,
                controlWidth: Self.controlWidth(for: item.image, horizontal: horizontal),
                onActivate: onActivate
            )
        }
    }

    static let maximumContentWidth: CGFloat = 120

    static func controlWidth(for image: NSImage, horizontal: Bool = true) -> CGFloat {
        guard horizontal else { return WindowsTrayIconMetrics.squareControlWidth }
        guard image.size.height > 0 else { return WindowsTrayIconMetrics.squareControlWidth }
        return contentWidth(for: image) + 2 * WindowsTrayIconMetrics.horizontalContentPadding
    }

    static func contentWidth(for image: NSImage) -> CGFloat {
        guard image.size.height > 0 else { return WindowsTrayIconMetrics.iconSize }
        let imageWidth = WindowsTrayIconMetrics.iconSize * image.size.width / image.size.height
        return min(max(imageWidth, WindowsTrayIconMetrics.iconSize), maximumContentWidth)
    }
}

enum ExternalStatusOverflowMetrics {
    static let columnCount = 5
    static let cellSize: CGFloat = 40
    static let panelPadding: CGFloat = 4

    static func contentSize(itemCount: Int) -> CGSize {
        let rowCount = max(1, Int(ceil(Double(itemCount) / Double(columnCount))))
        return CGSize(
            width: CGFloat(columnCount) * cellSize + 2 * panelPadding,
            height: CGFloat(rowCount) * cellSize + 2 * panelPadding
        )
    }
}

enum ExternalStatusOverflowVisibilityPolicy {
    static func shouldShowButton(hiddenItemCount: Int, isDragging: Bool) -> Bool {
        hiddenItemCount > 0 || isDragging
    }
}

@MainActor
final class ExternalStatusOverflowPanelController: ObservableObject {
    private let panelController = TaskbarJumpListController()
    private var layoutCancellable: AnyCancellable?

    var isVisible: Bool { panelController.isVisible }

    func toggle(
        service: ExternalStatusItemService,
        screen: NSScreen,
        position: TaskbarPosition,
        relativeTo anchorView: NSView
    ) {
        if isVisible {
            dismiss()
            return
        }

        let itemCount = service.items(on: screen, visibility: .hidden).count
        guard itemCount > 0 else { return }
        let contentSize = ExternalStatusOverflowMetrics.contentSize(itemCount: itemCount)
        let rootView = ExternalStatusOverflowPanelView(
            service: service,
            screen: screen,
            onActivate: { [weak self] in self?.dismiss() }
        )
        panelController.show(
            rootView: AnyView(rootView),
            contentSize: contentSize,
            relativeTo: anchorView,
            position: position,
            preservesOnTrayItemMouseDown: true
        )
        layoutCancellable = service.$layout.dropFirst().sink { [weak self, weak service, weak anchorView] _ in
            DispatchQueue.main.async {
                guard let self, let service, let anchorView, self.isVisible else { return }
                let nextCount = service.items(on: screen, visibility: .hidden).count
                guard nextCount > 0 else {
                    self.dismiss()
                    return
                }
                self.panelController.updateFrame(
                    contentSize: ExternalStatusOverflowMetrics.contentSize(itemCount: nextCount),
                    relativeTo: anchorView,
                    position: position
                )
            }
        }
    }

    func dismiss() {
        layoutCancellable?.cancel()
        layoutCancellable = nil
        panelController.dismiss()
    }

    func setKeepsVisibleForSettings(_ keepsVisible: Bool) {
        panelController.setKeepsVisibleForSettings(keepsVisible)
    }
}

@MainActor
struct ExternalStatusOverflowButton: View {
    @ObservedObject var service: ExternalStatusItemService
    @ObservedObject var panelController: ExternalStatusOverflowPanelController
    let screen: NSScreen
    let position: TaskbarPosition

    var body: some View {
        WindowsTrayIconButton(
            title: "Show hidden icons",
            anchoredPrimaryAction: { anchorView in
                panelController.toggle(
                    service: service,
                    screen: screen,
                    position: position,
                    relativeTo: anchorView
                )
            },
            dropAxis: position.isHorizontal ? .horizontal : .vertical,
            dropValidator: service.isExternalItem,
            dropAction: { itemID, _ in
                service.setHidden(true, itemID: itemID)
                if service.items(on: screen, visibility: .hidden).isEmpty {
                    panelController.dismiss()
                }
            },
            dropTipSymbolName: "pin.slash"
        ) {
            Image(systemName: chevronName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: WindowsTrayIconMetrics.iconSize, height: WindowsTrayIconMetrics.iconSize)
        }
        .frame(width: WindowsTrayIconMetrics.squareControlWidth, height: WindowsTrayIconMetrics.controlHeight)
    }

    private var chevronName: String {
        switch position {
        case .bottom: "chevron.up"
        case .top: "chevron.down"
        case .left: "chevron.right"
        case .right: "chevron.left"
        }
    }
}

@MainActor
private struct ExternalStatusOverflowPanelView: View {
    @ObservedObject var service: ExternalStatusItemService
    let screen: NSScreen
    let onActivate: () -> Void

    var body: some View {
        let items = service.items(on: screen, visibility: .hidden)
        ZStack {
            ExternalStatusItemDropDestination(
                dropValidator: service.isExternalItem,
                onDrop: { itemID in service.setHidden(true, itemID: itemID) }
            )
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.fixed(ExternalStatusOverflowMetrics.cellSize), spacing: 0),
                    count: ExternalStatusOverflowMetrics.columnCount
                ),
                alignment: .leading,
                spacing: 0
            ) {
                ForEach(items) { item in
                    ExternalStatusItemButton(
                        item: item,
                        service: service,
                        visibility: .hidden,
                        horizontal: true,
                        controlWidth: ExternalStatusOverflowMetrics.cellSize,
                        onActivate: onActivate
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(ExternalStatusOverflowMetrics.panelPadding)
        }
    }
}

@MainActor
struct ExternalStatusItemButton: View {
    let item: ExternalStatusItem
    @ObservedObject var service: ExternalStatusItemService
    let visibility: ExternalStatusItemVisibility
    let horizontal: Bool
    let controlWidth: CGFloat
    let onActivate: (() -> Void)?

    var body: some View {
        WindowsTrayIconButton(
            title: item.accessibilityLabel,
            primaryAction: {
                service.performPrimaryAction(item)
                onActivate?()
            },
            contextAction: { service.presentContextMenu(item) },
            dragIdentifier: item.id,
            dropAxis: horizontal ? .horizontal : .vertical,
            dropValidator: { sourceID in
                visibility == .visible || service.isExternalItem(sourceID)
            },
            dropHoverAction: { sourceID, after in
                service.move(
                    itemID: sourceID,
                    relativeTo: item.id,
                    after: after,
                    visibility: visibility
                )
            },
            dropAction: { sourceID, after in
                service.move(
                    itemID: sourceID,
                    relativeTo: item.id,
                    after: after,
                    visibility: visibility
                )
            }
        ) {
            Image(nsImage: item.image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(
                    width: min(
                        ExternalStatusItemsView.contentWidth(for: item.image),
                        max(
                            controlWidth - 2 * WindowsTrayIconMetrics.horizontalContentPadding,
                            WindowsTrayIconMetrics.iconSize
                        )
                    ),
                    height: WindowsTrayIconMetrics.iconSize
                )
        }
        .frame(width: controlWidth, height: WindowsTrayIconMetrics.controlHeight)
    }
}

@MainActor
private struct ExternalStatusItemDropDestination: NSViewRepresentable {
    let dropValidator: (String) -> Bool
    let onDrop: (String) -> Void

    func makeNSView(context: Context) -> ExternalStatusItemDropView {
        let view = ExternalStatusItemDropView()
        view.dropValidator = dropValidator
        view.onDrop = onDrop
        return view
    }

    func updateNSView(_ view: ExternalStatusItemDropView, context: Context) {
        view.dropValidator = dropValidator
        view.onDrop = onDrop
    }
}

@MainActor
private final class ExternalStatusItemDropView: NSView {
    var dropValidator: ((String) -> Bool)?
    var onDrop: ((String) -> Void)?
    private var isTargeted = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([WindowsTrayIconControl.trayItemPasteboardType])
    }

    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrop(from: sender) else { return [] }
        isTargeted = true
        needsDisplay = true
        return .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        isTargeted = false
        needsDisplay = true
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        acceptsDrop(from: sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard acceptsDrop(from: sender), let itemID = draggedIdentifier(from: sender) else { return false }
        onDrop?(itemID)
        isTargeted = false
        needsDisplay = true
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isTargeted else { return }
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 7, yRadius: 7).fill()
    }

    private func draggedIdentifier(from sender: any NSDraggingInfo) -> String? {
        sender.draggingPasteboard.string(forType: WindowsTrayIconControl.trayItemPasteboardType)
    }

    private func acceptsDrop(from sender: any NSDraggingInfo) -> Bool {
        guard let identifier = draggedIdentifier(from: sender) else { return false }
        return dropValidator?(identifier) ?? true
    }
}
