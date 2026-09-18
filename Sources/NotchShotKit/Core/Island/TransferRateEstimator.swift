import Foundation

/// Throughput and time remaining derived only from measured byte counts.
///
/// Nothing here guesses: with fewer than two samples, or samples spanning too
/// short a window to be meaningful, `rate` is nil and the island shows no
/// speed or ETA at all rather than a jumpy or invented one.
public struct TransferRateEstimator: Sendable, Equatable {
    public var window: TimeInterval
    public var minimumSpan: TimeInterval
    private var samples: [(time: TimeInterval, bytes: Int64)] = []

    public init(window: TimeInterval = 4, minimumSpan: TimeInterval = 0.75) {
        self.window = window
        self.minimumSpan = minimumSpan
    }

    public static func == (lhs: TransferRateEstimator, rhs: TransferRateEstimator) -> Bool {
        lhs.window == rhs.window
            && lhs.minimumSpan == rhs.minimumSpan
            && lhs.samples.map(\.time) == rhs.samples.map(\.time)
            && lhs.samples.map(\.bytes) == rhs.samples.map(\.bytes)
    }

    public mutating func record(bytes: Int64, at time: TimeInterval) {
        guard bytes >= 0, time.isFinite else { return }
        if let last = samples.last {
            // Counters only move forward; a reset starts a fresh measurement.
            if bytes < last.bytes || time < last.time { samples.removeAll() }
        }
        samples.append((time, bytes))
        samples.removeAll { time - $0.time > window }
    }

    /// Bytes per second over the sampling window.
    public var rate: Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let span = last.time - first.time
        guard span >= minimumSpan else { return nil }
        let rate = Double(last.bytes - first.bytes) / span
        return rate > 0 ? rate : nil
    }

    /// Seconds remaining for `total`, or nil without a measured rate.
    public func estimatedSecondsRemaining(total: Int64) -> TimeInterval? {
        guard let rate, let last = samples.last, total >= last.bytes else { return nil }
        return Double(total - last.bytes) / rate
    }
}
