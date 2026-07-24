import AppKit
import Foundation

public enum MediaSourceKind: String, Sendable, Codable {
    /// MediaRemote bridge — covers Spotify, Music, Safari, Chrome, and anything
    /// else that publishes Now Playing info.
    case mediaRemote
    /// Apple Events fallback, app-specific.
    case appleEvents
    /// Nothing usable is available.
    case none

    public var displayName: String {
        switch self {
        case .mediaRemote: "System Now Playing"
        case .appleEvents: "Spotify / Music (Apple Events)"
        case .none: "Disabled"
        }
    }
}

public struct MediaSnapshot: Sendable, Equatable {
    public var source: MediaSourceKind
    /// Bundle id of the app that owns playback, when known.
    public var applicationBundleID: String?
    public var applicationName: String?
    public var title: String?
    public var artist: String?
    public var album: String?
    public var artworkData: Data?
    public var duration: TimeInterval?
    public var position: TimeInterval?
    /// Wall-clock time `position` was sampled, so the UI can interpolate
    /// without polling the source.
    public var positionTimestamp: Date?
    public var isPlaying: Bool
    public var supportedCommands: Set<MediaCommandKind>

    public init(
        source: MediaSourceKind = .none,
        applicationBundleID: String? = nil,
        applicationName: String? = nil,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        artworkData: Data? = nil,
        duration: TimeInterval? = nil,
        position: TimeInterval? = nil,
        positionTimestamp: Date? = nil,
        isPlaying: Bool = false,
        supportedCommands: Set<MediaCommandKind> = []
    ) {
        self.source = source
        self.applicationBundleID = applicationBundleID
        self.applicationName = applicationName
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkData = artworkData
        self.duration = duration
        self.position = position
        self.positionTimestamp = positionTimestamp
        self.isPlaying = isPlaying
        self.supportedCommands = supportedCommands
    }

    public static let empty = MediaSnapshot()

    /// True when there is something worth showing in the notch.
    public var hasContent: Bool {
        source != .none && (title?.isEmpty == false || artist?.isEmpty == false)
    }

    /// Position advanced to `date`, assuming uninterrupted playback.
    public func interpolatedPosition(at date: Date = Date()) -> TimeInterval? {
        guard let position else { return nil }
        guard isPlaying, let positionTimestamp else { return position }
        let advanced = position + date.timeIntervalSince(positionTimestamp)
        guard let duration else { return max(0, advanced) }
        return min(max(0, advanced), duration)
    }

    public var progress: Double {
        guard let duration, duration > 0, let position = interpolatedPosition() else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    /// Ignores position/timestamp so a 1 Hz position tick doesn't redraw artwork.
    public func isMateriallyEqual(to other: MediaSnapshot) -> Bool {
        source == other.source
            && applicationBundleID == other.applicationBundleID
            && title == other.title
            && artist == other.artist
            && album == other.album
            && isPlaying == other.isPlaying
            && duration == other.duration
            && artworkData?.count == other.artworkData?.count
    }
}

public enum MediaCommandKind: String, Sendable, Codable, Hashable {
    case play
    case pause
    case togglePlayPause
    case nextTrack
    case previousTrack
    case seek
}

public enum MediaCommand: Sendable, Equatable {
    case play
    case pause
    case togglePlayPause
    case nextTrack
    case previousTrack
    case seek(TimeInterval)

    public var kind: MediaCommandKind {
        switch self {
        case .play: .play
        case .pause: .pause
        case .togglePlayPause: .togglePlayPause
        case .nextTrack: .nextTrack
        case .previousTrack: .previousTrack
        case .seek: .seek
        }
    }
}

/// A pluggable Now Playing backend. Implementations must never block or crash
/// the notch: failures surface as a `.none` snapshot.
public protocol MediaSource: Sendable {
    var kind: MediaSourceKind { get }
    /// Reports whether this backend can run on the current system right now.
    func healthCheck() async -> Bool
    /// `async` so an actor-based backend can vend its stream without breaking
    /// isolation — the adapter owns a subprocess and must stay serialised.
    func updates() async -> AsyncStream<MediaSnapshot>
    func send(_ command: MediaCommand) async throws
    func stop() async
}
