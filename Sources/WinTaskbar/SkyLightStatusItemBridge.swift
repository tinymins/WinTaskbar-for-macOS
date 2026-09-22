import CoreGraphics
import Darwin

final class SkyLightStatusItemBridge: @unchecked Sendable {
    static let shared = SkyLightStatusItemBridge()

    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias MoveWindow = @convention(c) (
        Int32,
        CGWindowID,
        UnsafePointer<CGPoint>
    ) -> CGError

    private let mainConnectionID: MainConnectionID?
    private let moveWindow: MoveWindow?

    private init() {
        let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY | RTLD_LOCAL
        )
        mainConnectionID = Self.symbol("SLSMainConnectionID", handle: handle)
        moveWindow = Self.symbol("SLSMoveWindow", handle: handle)
    }

    func move(windowID: CGWindowID, to origin: CGPoint) -> Bool {
        guard let mainConnectionID, let moveWindow else { return false }
        var origin = origin
        return moveWindow(mainConnectionID(), windowID, &origin) == .success
    }

    private static func symbol<T>(
        _ name: String,
        handle: UnsafeMutableRawPointer?
    ) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}
