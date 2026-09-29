import AppKit

/// Shared sizing for live text alerts and their maximum-width editing frames.
enum NotificationTextLayout {
    static func minimumWidth(large: Bool) -> CGFloat { large ? 320 : 240 }

    static func font(size: CGFloat) -> NSFont {
        let font = NSFont.systemFont(ofSize: size, weight: .bold)
        return font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? font
    }

    static func height(fontSize: CGFloat, large: Bool) -> CGFloat {
        guard !large else { return 170 }
        let font = font(size: fontSize)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        return lineHeight * 2 + 8 // Two line heights inside the outer shadow padding.
    }

    static func width(text: String, fontSize: CGFloat, maximum: CGFloat,
                      screenWidth: CGFloat, large: Bool, editing: Bool) -> CGFloat {
        let minimum = min(minimumWidth(large: large), screenWidth)
        let limit = min(screenWidth, max(minimum, maximum))
        guard !editing else { return limit }
        let content = (text as NSString).size(withAttributes: [.font: font(size: fontSize)]).width
        return min(limit, max(minimum, ceil(content) + 56))
    }

    enum DragMode { case move, left, right }

    static func draggedFrame(start: NSRect, delta: NSPoint, mode: DragMode,
                             minimumWidth: CGFloat, screen: NSRect) -> NSRect {
        switch mode {
        case .move:
            return NSRect(x: min(max(start.minX + delta.x, screen.minX), screen.maxX - start.width),
                          y: min(max(start.minY + delta.y, screen.minY), screen.maxY - start.height),
                          width: start.width, height: start.height)
        case .left, .right:
            let available = 2 * min(start.midX - screen.minX, screen.maxX - start.midX)
            let change = 2 * delta.x * (mode == .left ? -1 : 1)
            let width = min(available, max(minimumWidth, start.width + change))
            return NSRect(x: start.midX - width / 2, y: start.minY, width: width, height: start.height)
        }
    }
}
