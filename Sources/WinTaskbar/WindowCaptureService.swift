import AppKit
import OSLog

/// Callers keep their own refresh cadence. This service only shares capture work and results.
@MainActor
final class WindowCaptureService {
    private struct Key: Hashable {
        let ownerPID: pid_t
        let windowID: CGWindowID

        init(_ window: WindowInfo) {
            ownerPID = window.ownerPID
            windowID = window.windowID
        }
    }

    private struct CachedCapture {
        let snapshot: WindowLiveSnapshot
        let bestResolution: Bool
        let capturedAt: TimeInterval
    }

    private struct PendingCapture {
        let id: UUID
        let bestResolution: Bool
        let task: Task<WindowLiveSnapshot?, Never>
    }

    private let images = WindowThumbnailCache()
    private var captures: [Key: CachedCapture] = [:]
    private var pending: [Key: PendingCapture] = [:]
    private let logger = Logger(subsystem: "io.github.tinymins.WinTaskbar", category: "WindowCapture")

    func cachedImage(for window: WindowInfo) -> NSImage? {
        guard captures[Key(window)] != nil else { return nil }
        return images.cachedImage(for: window.windowID)
    }

    func capture(
        for window: WindowInfo,
        imageOptions: CGWindowImageOption = [.boundsIgnoreFraming, .bestResolution]
    ) async -> WindowLiveSnapshot? {
        let key = Key(window)
        guard !Task.isCancelled, !window.isMinimized else { return captures[key]?.snapshot }
        let bestResolution = imageOptions.contains(.bestResolution)
        // A frame just obtained by another preview can satisfy this request without another capture.
        let recentFrameLifetime = Double(WindowPeekRefreshSession.intervalNanoseconds) / 1_000_000_000
        if let cached = captures[key],
           (!bestResolution || cached.bestResolution),
           ProcessInfo.processInfo.systemUptime - cached.capturedAt < recentFrameLifetime {
            logger.debug("capture-reused window=\(window.windowID)")
            return cached.snapshot
        }
        if let existing = pending[key] {
            logger.debug("capture-joined window=\(window.windowID)")
            let snapshot = await existing.task.value
            guard !Task.isCancelled else { return nil }
            if bestResolution && !existing.bestResolution {
                return await capture(for: window, imageOptions: imageOptions)
            }
            return snapshot
        }

        let id = UUID()
        let task = Task { @MainActor [weak self] in
            let snapshot = await Task.detached(priority: .userInitiated) {
                WindowLiveSnapshotCapture.capture(
                    windowID: window.windowID, ownerPID: window.ownerPID, imageOptions: imageOptions
                )
            }.value
            guard let self else { return snapshot }
            guard self.pending[key]?.id == id else { return nil }
            self.pending.removeValue(forKey: key)
            if let snapshot {
                // Numeric window IDs can be reused by a different owner.
                self.captures = self.captures.filter { $0.key.windowID != key.windowID || $0.key == key }
                self.captures[key] = CachedCapture(
                    snapshot: snapshot, bestResolution: bestResolution,
                    capturedAt: ProcessInfo.processInfo.systemUptime
                )
                self.images.store(
                    NSImage(cgImage: snapshot.image, size: NSSize(width: snapshot.image.width, height: snapshot.image.height)),
                    for: window.windowID
                )
            }
            self.logger.debug("capture-finished window=\(window.windowID) success=\(snapshot != nil)")
            return snapshot
        }
        pending[key] = PendingCapture(id: id, bestResolution: bestResolution, task: task)
        logger.debug("capture-start window=\(window.windowID) bestResolution=\(bestResolution) workers=\(self.pending.count)")
        return await task.value
    }

    func removeClosedWindows() {
        images.removeClosedWindows()
        captures = captures.filter { images.cachedImage(for: $0.key.windowID) != nil }
    }
}
