import Foundation

struct MouseEnhancementExcludedApp: Codable, Equatable, Identifiable {
    let bundleID: String
    let name: String
    var id: String { bundleID }
}

struct MouseEnhancementPreferences: Codable, Equatable {
    var enabled = false
    var smoothScrolling = true
    var speed = 1.0
    var duration = 0.18
    var reverseVertical = false
    var reverseHorizontal = false
    var excludedApps: [MouseEnhancementExcludedApp] = []

    var effectiveSpeed: Double { speed.isFinite ? min(4, max(0.25, speed)) : 1 }
    var effectiveDuration: Double { duration.isFinite ? min(0.5, max(0.05, duration)) : 0.18 }
}
