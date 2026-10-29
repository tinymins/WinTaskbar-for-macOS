import Foundation

/// Slow input contributes one native line. Rapid input preserves the native
/// distance and applies acceleration; only additional line budgets are smoothed.
struct MouseScrollDynamics: Sendable {
    struct Axis: Sendable {
        private var direction: Int64 = 0
        private var previousTime: Double?
        private var accelerationRemainder = 0.0
        private var immediateLines: Int64 = 0
        private var pendingLines: Int64 = 0
        private var remaining = 0.0
        private var filtered = 0.0
        private var outputRemainder = 0.0

        private static let slowInterval = 0.2
        private static let fastestInterval = 0.04

        mutating func add(_ input: Double, at time: Double, speed: Double) {
            guard input != 0 else { return }
            let newDirection: Int64 = input > 0 ? 1 : -1
            if direction != newDirection { self = Axis() }
            let interval = previousTime.map { time - $0 }
            let distance: Double
            if let interval, interval > 0, interval < Self.slowInterval {
                let activity = min(1, (Self.slowInterval - interval)
                    / (Self.slowInterval - Self.fastestInterval))
                let gain = 1 + (speed - 1) * activity
                distance = max(1, abs(input)) * gain
            } else {
                accelerationRemainder = 0
                distance = 1
            }
            direction = newDirection
            previousTime = time
            immediateLines += 1
            // Quantize acceleration once per input burst, never once per frame.
            // Allow floating-point noise at a complete-line boundary.
            let additional = accelerationRemainder + distance - 1
            let lines = Int64((additional + 1e-9).rounded(.down))
            accelerationRemainder = max(0, additional - Double(lines))
            pendingLines += lines
            remaining += Double(lines)
        }

        mutating func advance(transition: Double) -> Int64 {
            let raw = remaining * transition
            remaining -= raw
            outputRemainder += filtered
            filtered += 0.23 * (raw - filtered)
            var lines = min(pendingLines, Int64(max(0, outputRemainder.rounded())))
            outputRemainder -= Double(lines)
            pendingLines -= lines
            if pendingLines == 0 {
                remaining = 0
                filtered = 0
                outputRemainder = 0
            }
            lines += immediateLines
            immediateLines = 0
            return direction * lines
        }

        var isSettled: Bool { immediateLines == 0 && pendingLines == 0 }
    }

    private var x = Axis()
    private var y = Axis()
    private var transition = 0.085

    mutating func add(x: Double, y: Double, speed: Double, transition: Double, at time: Double) {
        self.transition = transition
        self.x.add(x, at: time, speed: speed)
        self.y.add(y, at: time, speed: speed)
    }

    mutating func advance() -> (x: Int64, y: Int64) {
        (x.advance(transition: transition), y.advance(transition: transition))
    }

    var isSettled: Bool { x.isSettled && y.isSettled }
}
