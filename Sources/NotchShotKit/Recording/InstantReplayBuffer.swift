import Foundation

/// The last stretch of an Instant Replay stream, as fragmented MP4.
///
/// `AVAssetWriter` hands the stream over as one initialization segment and
/// then a self-contained segment about every second. The initialization
/// segment followed by any run of consecutive media segments is a playable
/// movie, so the buffer keeps the newest segments that cover the window and
/// drops older ones as new ones arrive. Everything stays in memory.
struct InstantReplayBuffer: Sendable, Equatable {
    struct Segment: Sendable, Equatable {
        var data: Data
        var duration: TimeInterval
    }

    /// How much footage to keep, in seconds.
    var window: TimeInterval
    private(set) var initialization: Data?
    private(set) var segments: [Segment] = []

    init(window: TimeInterval) {
        self.window = max(1, window)
    }

    var bufferedDuration: TimeInterval { segments.reduce(0) { $0 + $1.duration } }
    var byteCount: Int { (initialization?.count ?? 0) + segments.reduce(0) { $0 + $1.data.count } }
    var isEmpty: Bool { initialization == nil || segments.isEmpty }

    mutating func reset() {
        initialization = nil
        segments.removeAll()
    }

    /// A new writer starts a new movie: segments from the old one can't follow
    /// the new initialization segment, so they go with it.
    mutating func setInitialization(_ data: Data) {
        initialization = data
        segments.removeAll()
    }

    mutating func append(_ data: Data, duration: TimeInterval) {
        guard initialization != nil, !data.isEmpty else { return }
        segments.append(Segment(data: data, duration: max(0, duration.isFinite ? duration : 0)))
        trim()
    }

    /// Drops the oldest segment while the rest still cover the window, so the
    /// saved clip is never shorter than asked for and at most one segment
    /// (about a second) longer.
    private mutating func trim() {
        var total = bufferedDuration
        while segments.count > 1, total - segments[0].duration >= window {
            total -= segments[0].duration
            segments.removeFirst()
        }
    }

    /// The buffered stretch as one fragmented MP4, or nil before the first
    /// segment has arrived.
    func movieData() -> Data? {
        guard let initialization, !segments.isEmpty else { return nil }
        var data = Data(capacity: byteCount)
        data.append(initialization)
        for segment in segments { data.append(segment.data) }
        return data
    }
}
