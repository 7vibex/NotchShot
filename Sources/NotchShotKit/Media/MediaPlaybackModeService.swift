import Foundation

/// Repeat state, in the three positions Music exposes.
///
/// Spotify only has a boolean, so it maps onto `off` and `all`; a player that
/// reports `one` is always Music.
public enum MediaRepeatMode: String, Sendable, Equatable {
    case off
    case one
    case all

    public var symbolName: String {
        switch self {
        case .off, .all: "repeat"
        case .one: "repeat.1"
        }
    }

    public var isOn: Bool { self != .off }

    public var accessibilityDescription: String {
        switch self {
        case .off: "off"
        case .one: "repeat this track"
        case .all: "repeat all"
        }
    }
}

public struct MediaPlaybackModes: Sendable, Equatable {
    public var isShuffling: Bool
    public var repeatMode: MediaRepeatMode

    public init(isShuffling: Bool, repeatMode: MediaRepeatMode) {
        self.isShuffling = isShuffling
        self.repeatMode = repeatMode
    }
}

/// Reads and sets shuffle and repeat on the player that owns playback.
///
/// Both are in Spotify's and Music's scripting dictionaries — Spotify as the
/// booleans `shuffling` and `repeating`, Music as `shuffle enabled` and the
/// three-position `song repeat` — so this drives the player's own state rather
/// than keeping a shadow copy that would drift the moment the user touched the
/// app itself. Anything else playing (a browser tab, another app on the
/// MediaRemote bridge) reports nothing and the controls stay hidden, because a
/// shuffle button that silently does nothing is worse than no button.
public actor MediaPlaybackModeService {
    public static let shared = MediaPlaybackModeService()

    static let fieldSeparator = "\u{1F}"

    private enum Player: String {
        case music = "com.apple.Music"
        case spotify = "com.spotify.client"

        var applicationName: String {
            switch self {
            case .music: "Music"
            case .spotify: "Spotify"
            }
        }
    }

    private let executor = AppleScriptExecutor()

    public init() {}

    public nonisolated static func supportsModes(bundleID: String?) -> Bool {
        player(for: bundleID) != nil
    }

    private nonisolated static func player(for bundleID: String?) -> Player? {
        guard let bundleID else { return nil }
        return Player(rawValue: bundleID)
    }

    /// Nil when the player could not be asked — not scriptable right now, or
    /// Automation still denied.
    public func modes(for bundleID: String?) async -> MediaPlaybackModes? {
        guard let player = Self.player(for: bundleID) else { return nil }
        guard let output = await executor.execute(readScript(for: player)).stringValue else {
            return nil
        }
        return Self.parse(output)
    }

    @discardableResult
    public func setShuffle(_ enabled: Bool, for bundleID: String?) async -> MediaPlaybackModes? {
        guard let player = Self.player(for: bundleID) else { return nil }
        let value = enabled ? "true" : "false"
        let property = player == .music ? "shuffle enabled" : "shuffling"
        _ = await executor.execute(
            "tell application \"\(player.applicationName)\" to set \(property) to \(value)"
        )
        return await modes(for: bundleID)
    }

    /// Advances repeat one position and returns the state the player confirms.
    @discardableResult
    public func cycleRepeat(from current: MediaRepeatMode, for bundleID: String?) async -> MediaPlaybackModes? {
        guard let player = Self.player(for: bundleID) else { return nil }
        let next = Self.next(after: current, supportsSingleTrack: player == .music)
        let command: String
        switch player {
        case .music:
            command = "set song repeat to \(next.rawValue)"
        case .spotify:
            command = "set repeating to \(next == .off ? "false" : "true")"
        }
        _ = await executor.execute(
            "tell application \"\(player.applicationName)\" to \(command)"
        )
        return await modes(for: bundleID)
    }

    /// Spotify has no "repeat this track", so its cycle is two positions, not
    /// three. Offering `one` there would set a state the player cannot hold and
    /// the button would spring back on the next read.
    static func next(after current: MediaRepeatMode, supportsSingleTrack: Bool) -> MediaRepeatMode {
        switch current {
        case .off: .all
        case .all: supportsSingleTrack ? .one : .off
        case .one: .off
        }
    }

    private func readScript(for player: Player) -> String {
        let properties = player == .music
            ? "(shuffle enabled as string) & fieldSeparator & (song repeat as string)"
            : "(shuffling as string) & fieldSeparator & (repeating as string)"
        return """
        tell application "\(player.applicationName)"
            set fieldSeparator to ASCII character 31
            try
                return \(properties)
            on error
                return ""
            end try
        end tell
        """
    }

    static func parse(_ output: String) -> MediaPlaybackModes? {
        let fields = output.components(separatedBy: fieldSeparator)
        guard fields.count == 2 else { return nil }
        let shuffle = fields[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let repeatValue = fields[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Spotify answers with a boolean, Music with off/one/all. Both spellings
        // are accepted so one player's vocabulary never blanks the control.
        let repeatMode: MediaRepeatMode
        switch repeatValue {
        case "one": repeatMode = .one
        case "all", "true": repeatMode = .all
        default: repeatMode = .off
        }
        return MediaPlaybackModes(
            isShuffling: shuffle == "true",
            repeatMode: repeatMode
        )
    }
}
