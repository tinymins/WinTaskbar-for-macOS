import AppKit
import Combine
import os

struct WindowCaptureKey: Hashable, Sendable {
    let ownerPID: pid_t
    let windowID: CGWindowID

    init(_ window: WindowInfo) {
        ownerPID = window.ownerPID
        windowID = window.windowID
    }
}

enum WindowCaptureQuality: Int, Comparable, Sendable {
    case thumbnail
    case fullSize

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct WindowCaptureDemand {
    let interval: TimeInterval
    let quality: WindowCaptureQuality

    static let thumbnail = Self(interval: Double(WindowLiveCaptureCadence.thumbnailIntervalNanoseconds) / 1_000_000_000, quality: .thumbnail)
    static let peek = Self(interval: Double(WindowPeekRefreshSession.intervalNanoseconds) / 1_000_000_000, quality: .fullSize)
}

@MainActor
final class WindowCaptureFrame: ObservableObject {
    @Published private(set) var snapshot: WindowLiveSnapshot?
    private(set) var image: NSImage?

    func update(_ snapshot: WindowLiveSnapshot?) {
        image = snapshot.map { NSImage(cgImage: $0.image, size: NSSize(width: $0.image.width, height: $0.image.height)) }
        self.snapshot = snapshot
    }
}

/// A consumer owns its presentation lifetime; the service owns all capture work.
@MainActor
final class WindowCaptureSession {
    private let service: WindowCaptureService
    private var subscriptionID: UUID?
    private var frames: [WindowCaptureKey: WindowCaptureFrame] = [:]

    init(service: WindowCaptureService) { self.service = service }

    func frame(for window: WindowInfo) -> WindowCaptureFrame {
        let key = WindowCaptureKey(window)
        if let frame = frames[key] { return frame }
        let frame = WindowCaptureFrame()
        frame.update(service.cachedSnapshot(for: window))
        frames[key] = frame
        return frame
    }

    func start(
        windows: [WindowInfo],
        demand: WindowCaptureDemand,
        onSnapshot: (@MainActor (WindowLiveSnapshot) -> Void)? = nil
    ) {
        if let subscriptionID { service.unsubscribe(subscriptionID) }
        let keys = Set(windows.map(WindowCaptureKey.init))
        frames = frames.filter { keys.contains($0.key) }
        for window in windows { _ = frame(for: window) }
        subscriptionID = service.subscribe(windows: windows, demand: demand) { [weak self] key, snapshot in
            guard let self, let snapshot else { return }
            self.frames[key]?.update(snapshot)
            onSnapshot?(snapshot)
        }
    }

    func update(windows: [WindowInfo]) {
        for window in windows { _ = frame(for: window) }
        if let subscriptionID { service.update(subscriptionID, windows: windows) }
    }

    func stop() {
        if let subscriptionID { service.unsubscribe(subscriptionID) }
        subscriptionID = nil
        for frame in frames.values { frame.update(nil) }
        frames = [:]
    }
}

@MainActor
final class WindowCaptureService {
    private struct CachedFrame {
        var snapshot: WindowLiveSnapshot
        var quality: WindowCaptureQuality
        let capturedAt: TimeInterval
        var lastUsedAt: TimeInterval
    }

    private struct Subscription {
        var windows: [WindowCaptureKey: WindowInfo]
        let demand: WindowCaptureDemand
        let once: Bool
        var deliveredAt: [WindowCaptureKey: TimeInterval] = [:]
        let receive: @MainActor (WindowCaptureKey, WindowLiveSnapshot?) -> Void
    }

    private struct Request {
        var window: WindowInfo
        var demand: WindowCaptureDemand
        var dueAt: TimeInterval
    }

    private let logger = Logger(subsystem: "io.github.tinymins.WinTaskbar", category: "WindowCapture")
    private var cache: [WindowCaptureKey: CachedFrame] = [:]
    private var subscriptions: [UUID: Subscription] = [:]
    private var workers: [WindowCaptureKey: Task<Void, Never>] = [:]
    private var retryAfter: [WindowCaptureKey: TimeInterval] = [:]
    private var wakeTask: Task<Void, Never>?
    private static let memoryBudget = 32 * 1024 * 1024

    func cachedSnapshot(for window: WindowInfo) -> WindowLiveSnapshot? {
        let key = WindowCaptureKey(window)
        cache[key]?.lastUsedAt = ProcessInfo.processInfo.systemUptime
        return cache[key]?.snapshot
    }

    func subscribe(
        windows: [WindowInfo],
        demand: WindowCaptureDemand,
        once: Bool = false,
        receive: @escaping @MainActor (WindowCaptureKey, WindowLiveSnapshot?) -> Void
    ) -> UUID {
        let id = UUID()
        subscriptions[id] = Subscription(
            windows: Dictionary(uniqueKeysWithValues: windows.map { (WindowCaptureKey($0), $0) }),
            demand: demand, once: once, receive: receive
        )
        for window in windows {
            if let snapshot = cachedSnapshot(for: window) { receive(WindowCaptureKey(window), snapshot) }
        }
        logger.debug("subscribe consumers=\(self.subscriptions.count) windows=\(windows.count) quality=\(demand.quality.rawValue)")
        schedule()
        return id
    }

    func update(_ id: UUID, windows: [WindowInfo]) {
        subscriptions[id]?.windows = Dictionary(uniqueKeysWithValues: windows.map { (WindowCaptureKey($0), $0) })
        schedule()
    }

    func unsubscribe(_ id: UUID) {
        subscriptions.removeValue(forKey: id)
        logger.debug("unsubscribe consumers=\(self.subscriptions.count) workers=\(self.workers.count)")
        trimCache()
        schedule()
    }

    func captureOnce(for window: WindowInfo) async -> WindowLiveSnapshot? {
        if window.isMinimized { return cachedSnapshot(for: window) }
        let key = WindowCaptureKey(window)
        let now = ProcessInfo.processInfo.systemUptime
        if let entry = cache[key], entry.quality == .fullSize, now - entry.capturedAt < 0.04 {
            return entry.snapshot
        }
        return await withCheckedContinuation { continuation in
            // One-shot subscribers wait for a sufficiently recent, high-quality result.
            let id = UUID()
            subscriptions[id] = Subscription(
                windows: [key: window], demand: .peek, once: true,
                receive: { _, snapshot in continuation.resume(returning: snapshot) }
            )
            schedule()
        }
    }

    func removeClosedWindows() {
        guard !cache.isEmpty,
              let raw = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else { return }
        let live = Set(raw.compactMap { info -> WindowCaptureKey? in
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t else { return nil }
            return WindowCaptureKey(WindowInfo(windowID: id, title: "", ownerPID: pid, frame: .zero, isMinimized: false))
        })
        for key in workers.keys where !live.contains(key) { workers[key]?.cancel() }
        cache = cache.filter { live.contains($0.key) }
        retryAfter = retryAfter.filter { live.contains($0.key) }
        for id in Array(subscriptions.keys) {
            guard let subscription = subscriptions[id] else { continue }
            for key in subscription.windows.keys where !live.contains(key) {
                subscriptions[id]?.windows.removeValue(forKey: key)
                subscription.receive(key, nil)
            }
            if subscription.once, subscriptions[id]?.windows.isEmpty == true { subscriptions.removeValue(forKey: id) }
        }
        schedule()
    }

    private func requests() -> [WindowCaptureKey: Request] {
        var result: [WindowCaptureKey: Request] = [:]
        for subscription in subscriptions.values {
            for (key, window) in subscription.windows where !window.isMinimized {
                let entry = cache[key]
                let dueAt = entry.map {
                    $0.quality < subscription.demand.quality ? 0 : $0.capturedAt + subscription.demand.interval
                } ?? 0
                if var request = result[key] {
                    request.demand = WindowCaptureDemand(
                        interval: min(request.demand.interval, subscription.demand.interval),
                        quality: max(request.demand.quality, subscription.demand.quality)
                    )
                    request.dueAt = min(request.dueAt, dueAt)
                    result[key] = request
                } else {
                    result[key] = Request(window: window, demand: subscription.demand, dueAt: dueAt)
                }
            }
        }
        for key in Array(result.keys) {
            let dueAt = max(result[key]?.dueAt ?? 0, retryAfter[key] ?? 0)
            result[key]?.dueAt = dueAt
        }
        return result
    }

    private func schedule() {
        wakeTask?.cancel()
        wakeTask = nil
        let now = ProcessInfo.processInfo.systemUptime
        let pending = requests().filter { workers[$0.key] == nil }.sorted {
            if ($0.value.dueAt <= now) != ($1.value.dueAt <= now) { return $0.value.dueAt < $1.value.dueAt }
            if $0.value.demand.quality != $1.value.demand.quality { return $0.value.demand.quality > $1.value.demand.quality }
            return $0.value.dueAt < $1.value.dueAt
        }
        for (key, request) in pending where request.dueAt <= now {
            guard workers.count < 2 else { break }
            let quality = request.demand.quality
            let window = request.window
            workers[key] = Task { [weak self] in
                let snapshot = await Task.detached(priority: .userInitiated) {
                    let snapshot = WindowLiveSnapshotCapture.capture(
                        windowID: window.windowID, ownerPID: window.ownerPID,
                        imageOptions: [.boundsIgnoreFraming, quality == .fullSize ? .bestResolution : .nominalResolution]
                    )
                    return quality == .thumbnail ? snapshot.map { Self.thumbnail($0) } : snapshot
                }.value
                self?.complete(key: key, snapshot: Task.isCancelled ? nil : snapshot, quality: quality)
            }
            logger.debug("capture-start window=\(key.windowID) quality=\(quality.rawValue) workers=\(self.workers.count)")
        }
        guard workers.count < 2,
              let next = pending.filter({ workers[$0.key] == nil }).map({ $0.value.dueAt }).min() else { return }
        wakeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0.001, next - ProcessInfo.processInfo.systemUptime))) }
            catch { return }
            self?.schedule()
        }
    }

    private func complete(key: WindowCaptureKey, snapshot: WindowLiveSnapshot?, quality: WindowCaptureQuality) {
        workers.removeValue(forKey: key)
        let now = ProcessInfo.processInfo.systemUptime
        if let snapshot {
            cache[key] = CachedFrame(snapshot: snapshot, quality: quality, capturedAt: now, lastUsedAt: now)
            retryAfter.removeValue(forKey: key)
        } else {
            retryAfter[key] = now + 1
        }
        for id in Array(subscriptions.keys) {
            guard var subscription = subscriptions[id], subscription.windows[key] != nil else { continue }
            if subscription.once {
                guard snapshot == nil || quality >= subscription.demand.quality else { continue }
                subscriptions.removeValue(forKey: id)
                subscription.receive(key, snapshot ?? cache[key]?.snapshot)
            } else if now - (subscription.deliveredAt[key] ?? 0) >= subscription.demand.interval {
                subscription.deliveredAt[key] = now
                subscriptions[id] = subscription
                subscription.receive(key, snapshot)
            }
        }
        logger.debug("capture-finished window=\(key.windowID) success=\(snapshot != nil) subscribers=\(self.subscriptions.count)")
        trimCache()
        schedule()
    }

    private func trimCache() {
        let active = requests()
        for key in Array(cache.keys) where cache[key]?.quality == .fullSize && active[key]?.demand.quality != .fullSize {
            if var entry = cache[key] {
                entry.snapshot = Self.thumbnail(entry.snapshot)
                entry.quality = .thumbnail
                cache[key] = entry
            }
        }
        var bytes = cache.values.reduce(0) { $0 + $1.snapshot.image.bytesPerRow * $1.snapshot.image.height }
        for (key, entry) in cache.sorted(by: { $0.value.lastUsedAt < $1.value.lastUsedAt }) where active[key] == nil {
            guard bytes > Self.memoryBudget else { break }
            bytes -= entry.snapshot.image.bytesPerRow * entry.snapshot.image.height
            cache.removeValue(forKey: key)
        }
    }

    nonisolated private static func thumbnail(_ snapshot: WindowLiveSnapshot) -> WindowLiveSnapshot {
        let image = snapshot.image
        let scale = min(1, 1024 / Double(max(image.width, image.height)))
        guard scale < 1,
              let context = CGContext(
                data: nil, width: max(1, Int(Double(image.width) * scale)),
                height: max(1, Int(Double(image.height) * scale)), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return snapshot }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        guard let resized = context.makeImage() else { return snapshot }
        return WindowLiveSnapshot(windowID: snapshot.windowID, frame: snapshot.frame, image: resized)
    }
}
