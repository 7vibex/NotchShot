import AppKit
import Foundation

/// One upcoming track, as the player itself reports it.
public struct MediaQueueEntry: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let artist: String

    public init(id: String, title: String, artist: String) {
        self.id = id
        self.title = title
        self.artist = artist
    }
}

/// Reads the tracks a player will play next.
///
/// Only Music can answer this. Its scripting dictionary exposes the current
/// playlist and the position of the current track inside it, so the next few
/// rows are a bounded index range rather than a full library enumeration —
/// which on a large library would take far longer than the two-second script
/// timeout allows. Spotify's dictionary has no queue at all, and MediaRemote
/// publishes none either, so every other player returns nothing and the UI
/// leaves the control out rather than showing an empty list.
///
/// Two consequences worth knowing before trusting the list:
/// * it reads playlist order, so shuffled playback shows the wrong rows;
/// * it needs Automation permission, and a denial reports as no queue.
public actor MediaQueueService {
    public static let shared = MediaQueueService()

    static let fieldSeparator = "\u{1F}"
    static let recordSeparator = "\u{1E}"
    /// Marks "Music answered, but playback is stopped", so a stopped player is
    /// never presented as a queue that is genuinely empty.
    static let stoppedMarker = "\u{03}"
    /// The panel shows four rows; reading more would cost Apple Events for
    /// tracks nobody can see.
    public static let lookAhead = 4

    private let executor = AppleScriptExecutor()

    public init() {}

    /// True when this player can be asked at all. Checked before the control is
    /// drawn, so no button appears that could only ever open an empty list.
    public nonisolated static func supportsQueue(bundleID: String?) -> Bool {
        bundleID == "com.apple.Music"
    }

    /// Nil when the player could not be asked at all — Automation denied, the
    /// script timed out, Music is not scriptable right now, or playback is
    /// stopped. An empty array means it answered and there is genuinely nothing
    /// after this track; the panel says different things about the two, because
    /// "nothing queued" is a lie when the truth is "nothing is playing".
    public func upcoming(for bundleID: String?) async -> [MediaQueueEntry]? {
        guard Self.supportsQueue(bundleID: bundleID) else { return nil }
        guard let output = await executor.execute(Self.musicQueueScript).stringValue else {
            return nil
        }
        guard output != Self.stoppedMarker else { return nil }
        return Self.parse(output)
    }

    /// Everything is wrapped in one `try`: a track played from Up Next has no
    /// current playlist, and asking for one raises rather than returning empty.
    private static let musicQueueScript = """
    tell application "Music"
        if player state is stopped then return (ASCII character 3)
        set fieldSeparator to ASCII character 31
        set recordSeparator to ASCII character 30
        set collected to ""
        try
            set thePlaylist to current playlist
            set startIndex to (index of current track) + 1
            set lastIndex to (count of tracks of thePlaylist)
            repeat with offset from 0 to \(lookAhead - 1)
                set position to startIndex + offset
                if position > lastIndex then exit repeat
                set theTrack to track position of thePlaylist
                set collected to collected & (name of theTrack) & fieldSeparator ¬
                    & (artist of theTrack) & recordSeparator
            end repeat
        on error
            return ""
        end try
        return collected
    end tell
    """

    static func parse(_ output: String) -> [MediaQueueEntry] {
        output
            .components(separatedBy: recordSeparator)
            .compactMap { record -> MediaQueueEntry? in
                let fields = record.components(separatedBy: fieldSeparator)
                guard fields.count == 2 else { return nil }
                let title = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return nil }
                let artist = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
                // Position is part of the identity: the same track can legally
                // appear twice in one playlist, and two rows sharing an id
                // makes SwiftUI drop one of them.
                return MediaQueueEntry(
                    id: "\(title)—\(artist)",
                    title: title,
                    artist: artist
                )
            }
            .enumerated()
            .map { index, entry in
                MediaQueueEntry(
                    id: "\(index)—\(entry.id)",
                    title: entry.title,
                    artist: entry.artist
                )
            }
    }
}
