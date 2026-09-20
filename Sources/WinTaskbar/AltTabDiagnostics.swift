import Foundation
import OSLog

enum AltTabDiagnostics {
    static let logger = Logger(
        subsystem: "io.github.tinymins.WinTaskbar",
        category: "AltTab"
    )

    static func timestamp() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    static func milliseconds(since timestamp: UInt64) -> UInt64 {
        (DispatchTime.now().uptimeNanoseconds - timestamp) / 1_000_000
    }
}
