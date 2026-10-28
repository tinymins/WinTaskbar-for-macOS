import Foundation

struct MouseEnhancementExcludedApp: Codable, Equatable, Identifiable {
    let bundleID: String
    let name: String
    var id: String { bundleID }
}

struct MouseEnhancementPreferences: Codable, Equatable {
    private(set) var tuningVersion = 2
    var enabled = false
    var smoothScrolling = true
    var step = 33.6
    var speed = 2.7
    var response = 4.35
    var reverseVertical = false
    var reverseHorizontal = false
    var excludedApps: [MouseEnhancementExcludedApp] = []

    var effectiveStep: Double { step.isFinite ? min(100, max(0.01, step)) : 33.6 }
    var effectiveSpeed: Double { speed.isFinite ? min(10, max(1, speed)) : 2.7 }
    var effectiveResponse: Double { response.isFinite ? min(5, max(1, response)) : 4.35 }
    var transition: Double { ((1 - sqrt(effectiveResponse / 5.2)) * 1_000).rounded() / 1_000 }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case tuningVersion, enabled, smoothScrolling, step, speed, response
        case reverseVertical, reverseHorizontal, excludedApps
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        smoothScrolling = try values.decodeIfPresent(Bool.self, forKey: .smoothScrolling) ?? true
        reverseVertical = try values.decodeIfPresent(Bool.self, forKey: .reverseVertical) ?? false
        reverseHorizontal = try values.decodeIfPresent(Bool.self, forKey: .reverseHorizontal) ?? false
        excludedApps = try values.decodeIfPresent([MouseEnhancementExcludedApp].self, forKey: .excludedApps) ?? []
        // Version 1 used seconds and a different response model. Its duration
        // and gain are deliberately not reinterpreted as the new tuning values.
        if (try values.decodeIfPresent(Int.self, forKey: .tuningVersion) ?? 1) >= 2 {
            step = try values.decodeIfPresent(Double.self, forKey: .step) ?? 33.6
            speed = try values.decodeIfPresent(Double.self, forKey: .speed) ?? 2.7
            response = try values.decodeIfPresent(Double.self, forKey: .response) ?? 4.35
        }
        step = effectiveStep
        speed = effectiveSpeed
        response = effectiveResponse
    }

    mutating func resetTuning() {
        step = 33.6
        speed = 2.7
        response = 4.35
    }
}
