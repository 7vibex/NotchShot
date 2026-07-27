import Foundation

/// A conservative source gate for brightness UI. macOS does not label a
/// sampled brightness value as keyboard, slider, or ambient-sensor driven, but
/// it does deliver brightness-key system events. Requiring a recent key event
/// deliberately trades silent Control Centre changes for never opening the
/// notch merely because the room lighting changed.
struct BrightnessKeyIntentGate {
    private(set) var lastKeyEventAt: TimeInterval?
    let validityWindow: TimeInterval = 0.8

    mutating func noteKeyEvent(at time: TimeInterval) {
        lastKeyEventAt = time
    }

    mutating func reset() {
        lastKeyEventAt = nil
    }

    func allowsPublication(at time: TimeInterval) -> Bool {
        guard let lastKeyEventAt else { return false }
        let elapsed = time - lastKeyEventAt
        return elapsed >= 0 && elapsed <= validityWindow
    }
}

/// Decides whether a brightness reading is a change the *user* made or the
/// ambient light sensor adapting on its own.
///
/// macOS exposes no signal for which is which — auto-brightness moves the same
/// value the brightness keys do — so this works from the shape of the movement.
/// Measured on an adapting display, the two are well separated:
///
/// * Auto-brightness ramps continuously through arbitrary values, about 0.006
///   per 200 ms sample, and keeps going for as long as the light keeps
///   changing. Once the light settles it wanders by under 0.0025 per sample.
/// * The brightness keys move in exact 1/64 increments, so a deliberate change
///   is at least 0.0156 in one sample and lands on that grid. It is also brief:
///   a tap, or a key held for a moment, and then it stops.
///
/// So a reading is reported when it steps far enough in one sample to be a key
/// press, or when a short burst of movement has come to rest. Anything that
/// keeps sliding is ambient and stays silent.
struct BrightnessChangeClassifier {
    enum Outcome: Equatable {
        /// Nothing to show. The baseline has still been updated.
        case ignore
        /// A change the user appears to have made.
        case report(Double)
    }

    /// Finest increment the brightness keys produce (⇧⌥F1/F2).
    static let keyboardStep = 1.0 / 64.0

    /// Below this, the reading is hardware wobble rather than a change.
    private let noiseFloor = 0.004
    /// One sample moving at least this far is faster than auto-brightness ever
    /// ramps, so it is a key press or a slider being flicked.
    private let deliberateStep = keyboardStep * 0.75
    /// A one-sample jump this large is deliberate even off the keyboard grid.
    private let unmistakableStep = 0.05
    /// How far off a 1/64 multiple a reading may sit and still count as on-grid.
    private let gridTolerance = 0.08
    /// Movement is over once a sample goes by without any.
    private let restDelay = 0.15
    /// Deliberate movement is short. Longer than this is the sensor tracking
    /// the room.
    private let maximumBurst = 1.2

    private struct Burst {
        var anchor: Double
        var startedAt: TimeInterval
        var lastMovedAt: TimeInterval
        var latest: Double
        var sampleCount: Int
        /// Largest single-sample move seen in this burst. The whole decision
        /// rests on this: it is what a person does and the sensor cannot.
        var peakStep: Double
        var isReporting: Bool
    }

    private var last: Double?
    private var lastSampleAt: TimeInterval?
    private var burst: Burst?

    /// Adopts `value` as the baseline without reporting anything. Used at start
    /// and after a display wake, where the value legitimately jumps.
    mutating func reset(to value: Double?) {
        last = value
        lastSampleAt = nil
        burst = nil
    }

    mutating func classify(_ value: Double, at time: TimeInterval) -> Outcome {
        guard let previous = last else {
            last = value
            lastSampleAt = time
            return .ignore
        }

        // A blocked main run loop can collapse several seconds of a slow
        // ambient ramp into one apparently large sample. Re-baseline after a
        // sampling gap instead of turning that accumulated movement into a
        // false user gesture.
        if let lastSampleAt, time - lastSampleAt > 0.45 {
            last = value
            self.lastSampleAt = time
            burst = nil
            return .ignore
        }
        lastSampleAt = time

        let delta = value - previous
        guard abs(delta) > noiseFloor else {
            return settleIfNeeded(at: time)
        }

        last = value
        let step = abs(delta)
        var current = burst ?? Burst(
            anchor: previous,
            startedAt: time,
            lastMovedAt: time,
            latest: value,
            sampleCount: 0,
            peakStep: 0,
            isReporting: false
        )
        current.latest = value
        current.lastMovedAt = time
        current.sampleCount += 1
        current.peakStep = max(current.peakStep, step)

        let isFast = step >= deliberateStep

        if current.isReporting {
            // A held key keeps producing fast samples. The moment they stop
            // being fast the gesture is over, so stop tracking it rather than
            // letting an ambient drift inherit an open HUD.
            guard isFast else {
                burst = nil
                return .ignore
            }
            burst = current
            return .report(value)
        }

        // The keys land on exact 1/64 boundaries and a ramping sensor does not,
        // so a fast on-grid sample can be shown at once instead of waiting for
        // the movement to stop.
        if isFast, step >= unmistakableStep || (isOnKeyboardGrid(value) && isOnKeyboardGrid(previous)) {
            current.isReporting = true
            burst = current
            return .report(value)
        }

        burst = current
        return .ignore
    }

    private func isOnKeyboardGrid(_ value: Double) -> Bool {
        let steps = value / Self.keyboardStep
        return abs(steps - steps.rounded()) <= gridTolerance
    }

    /// Called on a sample that did not move. Closes an open burst, reporting it
    /// if it was short enough to have been a person.
    private mutating func settleIfNeeded(at time: TimeInterval) -> Outcome {
        guard let current = burst else { return .ignore }
        guard time - current.lastMovedAt >= restDelay else { return .ignore }
        burst = nil

        // Already shown, or already judged to be a ramp.
        guard !current.isReporting else { return .ignore }

        // Accumulated distance is *not* enough on its own. An auto-brightness
        // ramp does not glide at a constant rate — it stutters, and a sample
        // that happens to fall under the noise floor closes the burst. Judging
        // on the total then reported every few seconds of a long adaptation,
        // which is the flicker this class exists to stop. Only a single fast
        // sample separates a person from the sensor: measured, the sensor never
        // exceeds ~0.006 per sample and the finest key press is 0.0156.
        guard current.peakStep >= deliberateStep else { return .ignore }
        let duration = current.lastMovedAt - current.startedAt
        guard duration <= maximumBurst else { return .ignore }
        // A Control Centre drag: off-grid, but it stopped, so it was a person.
        return .report(current.latest)
    }
}
