import AppKit
import CoreGraphics
import QuartzCore
import SwiftUI

enum WindowMinimizeTransitionMotion {
    static let duration: TimeInterval = 0.167

    static func destinationFrame(for targetFrame: CGRect) -> CGRect {
        let side = max(12, min(targetFrame.width, targetFrame.height) * 0.72)
        return CGRect(
            x: targetFrame.midX - (side / 2),
            y: targetFrame.midY - (side / 2),
            width: side,
            height: side
        )
    }

    static func appKitFrame(fromQuartzFrame frame: CGRect, primaryScreenTop: CGFloat) -> CGRect {
        CGRect(
            x: frame.minX,
            y: primaryScreenTop - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }
}

private final class WindowMinimizeTransitionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class WindowMinimizeTransitionAnimator {
    private struct PendingRestore {
        let ownerPID: pid_t
        let snapshot: WindowLiveSnapshot
        let sourceFrame: CGRect
        let targetFrame: CGRect
    }

    private var activePanels: [pid_t: WindowMinimizeTransitionPanel] = [:]
    private var pendingRestores: [pid_t: PendingRestore] = [:]
    private var generations: [pid_t: UInt64] = [:]

    func minimize(
        window: WindowInfo,
        targetFrame: CGRect?,
        reduceMotion: Bool,
        hide: @escaping @MainActor () -> Void,
        fallback: @escaping @MainActor () -> Void
    ) {
        guard !reduceMotion,
              activePanels[window.ownerPID] == nil,
              let targetFrame,
              let snapshot = WindowLiveSnapshotCapture.capture(windowID: window.windowID),
              let panel = makePanel(snapshot: snapshot) else {
            fallback()
            return
        }

        let destinationFrame = WindowMinimizeTransitionMotion.destinationFrame(for: targetFrame)
        pendingRestores[window.ownerPID] = PendingRestore(
            ownerPID: window.ownerPID,
            snapshot: snapshot,
            sourceFrame: panel.frame,
            targetFrame: destinationFrame
        )
        let generation = begin(ownerPID: window.ownerPID, panel: panel)
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        hide()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = WindowMinimizeTransitionMotion.duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0, 0, 0, 1)
            panel.animator().setFrame(destinationFrame, display: true)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.finish(ownerPID: window.ownerPID, generation: generation)
            }
        }
    }

    @discardableResult
    func restore(
        ownerPID: pid_t,
        reveal: @escaping @MainActor () -> Void
    ) -> Bool {
        guard let pending = pendingRestores[ownerPID] else {
            return false
        }
        guard let panel = makePanel(snapshot: pending.snapshot, frame: pending.targetFrame) else {
            pendingRestores.removeValue(forKey: ownerPID)
            reveal()
            return true
        }
        pendingRestores.removeValue(forKey: ownerPID)

        let generation = begin(ownerPID: ownerPID, panel: panel)
        panel.alphaValue = 0.15
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = WindowMinimizeTransitionMotion.duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0, 0, 0, 1)
            panel.animator().setFrame(pending.sourceFrame, display: true)
            panel.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                reveal()
                self?.finish(ownerPID: pending.ownerPID, generation: generation)
            }
        }
        return true
    }

    private func makePanel(snapshot: WindowLiveSnapshot) -> WindowMinimizeTransitionPanel? {
        let primaryScreenTop = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.maxY
            ?? NSScreen.main?.frame.maxY
            ?? 0
        return makePanel(
            snapshot: snapshot,
            frame: WindowMinimizeTransitionMotion.appKitFrame(
                fromQuartzFrame: snapshot.frame,
                primaryScreenTop: primaryScreenTop
            )
        )
    }

    private func makePanel(
        snapshot: WindowLiveSnapshot,
        frame: CGRect
    ) -> WindowMinimizeTransitionPanel? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        let panel = WindowMinimizeTransitionPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true

        let imageView = NSImageView(frame: NSRect(origin: .zero, size: frame.size))
        imageView.autoresizingMask = [.width, .height]
        imageView.imageScaling = .scaleAxesIndependently
        imageView.image = NSImage(cgImage: snapshot.image, size: frame.size)
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 8
        imageView.layer?.masksToBounds = true
        panel.contentView = imageView
        return panel
    }

    private func begin(ownerPID: pid_t, panel: WindowMinimizeTransitionPanel) -> UInt64 {
        activePanels.removeValue(forKey: ownerPID)?.orderOut(nil)
        let generation = (generations[ownerPID] ?? 0) &+ 1
        generations[ownerPID] = generation
        activePanels[ownerPID] = panel
        return generation
    }

    private func finish(ownerPID: pid_t, generation: UInt64) {
        guard generations[ownerPID] == generation else { return }
        generations.removeValue(forKey: ownerPID)
        activePanels.removeValue(forKey: ownerPID)?.orderOut(nil)
    }
}

struct TaskbarTransitionAnchor: NSViewRepresentable {
    let onResolve: @MainActor (TaskbarTransitionAnchorView) -> Void

    func makeNSView(context: Context) -> TaskbarTransitionAnchorView {
        let view = TaskbarTransitionAnchorView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: TaskbarTransitionAnchorView, context: Context) {
        nsView.onResolve = onResolve
        nsView.resolveWhenAttached()
    }
}

final class TaskbarTransitionAnchorView: NSView {
    var onResolve: (@MainActor (TaskbarTransitionAnchorView) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolveWhenAttached()
    }

    func resolveWhenAttached() {
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.onResolve?(self)
        }
    }

    var screenFrame: CGRect? {
        guard let window else { return nil }
        return window.convertToScreen(convert(bounds, to: nil))
    }
}
