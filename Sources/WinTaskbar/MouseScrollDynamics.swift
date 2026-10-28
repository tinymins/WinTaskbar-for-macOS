import Foundation

/// Display-frame response: accumulated wheel distance followed by two low-pass
/// stages. This model advances once per display refresh, not by a millisecond TTL.
struct MouseScrollDynamics: Sendable {
    struct Axis: Sendable {
        private(set) var remaining = 0.0
        private(set) var filtered = 0.0
        private var previousInput = 0.0

        mutating func add(_ input: Double) {
            // Direction changes (and an inactive axis) restart distance tracking,
            // while retaining filtered velocity for a smooth transition.
            remaining = input * previousInput > 0 ? remaining + input : input
            previousInput = input
        }

        mutating func advance(transition: Double) -> Double {
            let raw = remaining * transition
            remaining -= raw
            let output = filtered
            filtered += 0.23 * (raw - filtered)
            return output
        }
    }

    private(set) var x = Axis()
    private(set) var y = Axis()
    private var transition = 0.085
    static let deadZone = 1.0

    mutating func add(x: Double, y: Double, step: Double, speed: Double, transition: Double) {
        func distance(_ value: Double) -> Double {
            value == 0 ? 0 : copysign(max(abs(value), step) * speed, value)
        }
        self.transition = transition
        self.x.add(distance(x))
        self.y.add(distance(y))
    }

    mutating func advance() -> (x: Double, y: Double) {
        (x.advance(transition: transition), y.advance(transition: transition))
    }

    var isSettled: Bool {
        max(abs(x.remaining), abs(y.remaining)) <= Self.deadZone
            && max(abs(x.filtered), abs(y.filtered)) <= Self.deadZone
    }
}
