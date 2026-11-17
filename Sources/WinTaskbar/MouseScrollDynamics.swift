import Foundation

/// Slow input contributes one native line. Rapid input preserves the native
/// distance, with additional acceleration during sustained, overlapping fast flicks.
struct MouseScrollDynamics: Sendable {
    struct Axis: Sendable {
        private var direction: Int64 = 0
        private var previousTime: Double?
        private var nextRoundGain = 1.0
        private var roundGain: Double?
        private var overlapStart: Double?
        private var sustainedFraction = 0.0
        private var firstRoundDistance = 1.0
        private var accelerationRemainder = 0.0
        private var immediateLines: Int64 = 0
        private var pendingLines: Int64 = 0
        private var remaining = 0.0
        private var filtered = 0.0
        private var outputRemainder = 0.0

        private static let roundInterval = 0.12
        private static let cooldown = 0.8

        mutating func add(_ input: Double, at time: Double, speed: Double) {
            guard input != 0 else { return }
            let newDirection: Int64 = input > 0 ? 1 : -1
            if direction != newDirection { self = Axis() }
            let interval = previousTime.map { time - $0 } ?? .infinity
            // Event timestamps are converted from nanoseconds to Double.
            let boundaryInterval = interval + 1e-9
            if interval <= 0 || boundaryInterval >= Self.cooldown {
                nextRoundGain = 1
                roundGain = nil
                accelerationRemainder = 0
            }
            let nativeDistance = max(1, abs(input))
            let distance: Double
            if interval > 0, boundaryInterval < Self.roundInterval {
                // A long gap within a flick breaks its high-rate input stream.
                if interval > Self.roundInterval / 2 { overlapStart = nil }
                sustainedFraction = overlapStart.map {
                    // Build speed over 200 ms once fast flicks overlap for 400 ms.
                    min(1, max(0, (time - $0 - Self.cooldown / 2) / (Self.cooldown / 4)))
                } ?? 0
                let gain = roundGain ?? min(speed, nextRoundGain)
                let effectiveGain = gain + (speed - gain) * sustainedFraction
                if roundGain == nil {
                    roundGain = gain
                    nextRoundGain = min(speed, gain + 0.25)
                    // The second event confirms a quick flick. Credit its first
                    // event too, subtracting the baseline line already emitted.
                    distance = firstRoundDistance * effectiveGain - 1 + nativeDistance * effectiveGain
                    firstRoundDistance = 1
                } else {
                    distance = nativeDistance * effectiveGain
                }
            } else {
                // Qualify a new flick only if its predecessor really has output
                // left to render at this instant, before accepting this event.
                if roundGain != nil, pendingLines > 0, interval > 0, interval < 2 * Self.roundInterval {
                    if overlapStart == nil { overlapStart = time }
                } else {
                    overlapStart = nil
                    sustainedFraction = 0
                }
                roundGain = nil
                firstRoundDistance = nativeDistance
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
            // As the user keeps flicking, deliver queued lines sooner. The
            // per-flick gain still bounds total distance, including at the cap.
            let response = min(1, transition * (1 + 2 * sustainedFraction))
            let raw = remaining * response
            remaining -= raw
            let released = filtered * (1 + sustainedFraction)
            outputRemainder += released
            filtered += 0.23 * (raw - released)
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
