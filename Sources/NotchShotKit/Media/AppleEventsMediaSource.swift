import AppKit
import Foundation

/// Fallback Now Playing source driven by Apple Events.
///
/// Only knows about Music and Spotify — they are the two mainstream macOS
/// players with a stable scripting dictionary. Browsers publish nothing over
/// Apple Events, which is precisely why the MediaRemote bridge exists.
///
/// Requires Automation permission, so it is never started until it is actually
/// needed, and a denial degrades to the disabled source rather than prompting
/// repeatedly.
public actor AppleEventsMediaSource: MediaSource {

    public nonisolated let kind: MediaSourceKind = .appleEvents

    private enum Player: String, CaseIterable {
        case music = "com.apple.Music"
        case spotify = "com.spotify.client"

        var applicationName: String {
            switch self {
            case .music: "Music"
            case .spotify: "Spotify"
            }
        }
    }

    private var pollTask: Task<Void, Never>?
    private var continuation: AsyncStream<MediaSnapshot>.Continuation?
    private var lastSnapshot = MediaSnapshot.empty
    /// Artwork keyed by "artist — title", so it is fetched once per track
    /// rather than on every poll tick.
    private var artworkCache: [String: Data] = [:]
    private var artworkCacheOrder: [String] = []
    /// Apple Events are synchronous and comparatively expensive, so the poll is
    /// slow by design — the notch interpolates playback position between ticks.
    private let pollInterval: Duration = .seconds(2)

    public init() {}

    public func healthCheck() async -> Bool {
        await MainActor.run { Self.runningPlayer() != nil }
    }

    public func updates() -> AsyncStream<MediaSnapshot> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { _ in
                Task { await self.stop() }
            }
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.poll()
                    try? await Task.sleep(for: self.pollInterval)
                }
            }
        }
    }

    public func send(_ command: MediaCommand) async throws {
        guard let player = await MainActor.run(body: { Self.runningPlayer() }) else { return }
        let script: String
        switch command {
        case .play: script = "play"
        case .pause: script = "pause"
        case .togglePlayPause: script = "playpause"
        case .nextTrack: script = "next track"
        case .previousTrack: script = "previous track"
        case .seek(let position):
            script = player == .spotify
                ? "set player position to \(Int(position))"
                : "set player position to \(Int(position))"
        }
        await MainActor.run {
            _ = Self.run(script: "tell application \"\(player.applicationName)\" to \(script)")
        }
        await poll()
    }

    public func stop() async {
        pollTask?.cancel()
        pollTask = nil
        continuation?.finish()
        continuation = nil
    }

    // MARK: Polling

    private func poll() async {
        var snapshot = await MainActor.run { Self.snapshot() }
        snapshot.artworkData = await artwork(for: snapshot)

        // Only emit when something the UI cares about actually changed, so the
        // 2 s tick doesn't churn SwiftUI or reload artwork.
        if !snapshot.isMateriallyEqual(to: lastSnapshot) || snapshot.position != lastSnapshot.position {
            lastSnapshot = snapshot
            continuation?.yield(snapshot)
        }
    }

    /// Album art for the current track.
    ///
    /// Music stores the image locally, so it comes back as raw bytes over Apple
    /// Events. Spotify only exposes a CDN URL, so that one costs a single
    /// request per track — the only network access in the app, and only when
    /// Spotify is the active player.
    private func artwork(for snapshot: MediaSnapshot) async -> Data? {
        guard let key = Self.cacheKey(for: snapshot) else { return nil }
        if let cached = artworkCache[key] { return cached }

        let data: Data?
        switch snapshot.applicationBundleID {
        case Player.music.rawValue:
            data = await MainActor.run { Self.musicArtworkData() }
        case Player.spotify.rawValue:
            guard let urlString = await MainActor.run(body: { Self.spotifyArtworkURL() }),
                  let url = URL(string: urlString),
                  url.scheme == "https"
            else { return nil }
            data = try? await URLSession.shared.data(from: url).0
        default:
            data = nil
        }

        guard let data, !data.isEmpty else { return nil }
        cache(data, for: key)
        return data
    }

    private static func cacheKey(for snapshot: MediaSnapshot) -> String? {
        guard let title = snapshot.title else { return nil }
        return "\(snapshot.artist ?? "")—\(title)"
    }

    private func cache(_ data: Data, for key: String) {
        artworkCache[key] = data
        artworkCacheOrder.append(key)
        // Album art is a few hundred KB apiece; a handful is plenty of history.
        while artworkCacheOrder.count > 8 {
            artworkCache.removeValue(forKey: artworkCacheOrder.removeFirst())
        }
    }

    @MainActor
    private static func musicArtworkData() -> Data? {
        let source = """
        tell application "Music"
            if player state is stopped then return missing value
            if (count of artworks of current track) is 0 then return missing value
            return raw data of artwork 1 of current track
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        // `raw data` arrives as a typed image descriptor, not a string.
        return result.data.isEmpty ? nil : result.data
    }

    @MainActor
    private static func spotifyArtworkURL() -> String? {
        run(script: "tell application \"Spotify\" to get artwork url of current track")
    }

    @MainActor
    private static func runningPlayer() -> Player? {
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        // Prefer whichever is actually playing; fall back to whichever is open.
        for player in Player.allCases where running.contains(player.rawValue) {
            if run(script: "tell application \"\(player.applicationName)\" to player state as string")?
                .lowercased() == "playing" {
                return player
            }
        }
        return Player.allCases.first { running.contains($0.rawValue) }
    }

    @MainActor
    private static func snapshot() -> MediaSnapshot {
        guard let player = runningPlayer() else {
            return MediaSnapshot(source: .none)
        }

        // One round-trip for everything: each `tell` is a separate Apple Event
        // and they add up quickly.
        let script = """
        tell application "\(player.applicationName)"
            if player state is stopped then return "stopped"
            set theTitle to name of current track
            set theArtist to artist of current track
            set theAlbum to album of current track
            set theDuration to duration of current track
            set thePosition to player position
            set theState to player state as string
            return theTitle & "\\n" & theArtist & "\\n" & theAlbum & "\\n" & theDuration & "\\n" & thePosition & "\\n" & theState
        end tell
        """

        guard let output = run(script: script), output != "stopped" else {
            return MediaSnapshot(
                source: .appleEvents,
                applicationBundleID: player.rawValue,
                applicationName: player.applicationName
            )
        }

        let fields = output.components(separatedBy: "\n")
        guard fields.count >= 6 else {
            return MediaSnapshot(source: .appleEvents, applicationBundleID: player.rawValue)
        }

        // Spotify reports duration in milliseconds, Music in seconds.
        var duration = Double(fields[3]) ?? 0
        if player == .spotify, duration > 1000 { duration /= 1000 }

        return MediaSnapshot(
            source: .appleEvents,
            applicationBundleID: player.rawValue,
            applicationName: player.applicationName,
            title: fields[0].isEmpty ? nil : fields[0],
            artist: fields[1].isEmpty ? nil : fields[1],
            album: fields[2].isEmpty ? nil : fields[2],
            artworkData: nil,
            duration: duration > 0 ? duration : nil,
            position: Double(fields[4]),
            positionTimestamp: Date(),
            isPlaying: fields[5].lowercased().contains("playing"),
            supportedCommands: [.play, .pause, .togglePlayPause, .nextTrack, .previousTrack, .seek]
        )
    }

    /// `NSAppleScript` must be used from the main thread.
    @MainActor
    private static func run(script source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            // -1743 is "not authorised to send Apple Events"; anything else is
            // usually the player simply not being scriptable right now.
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -1743 {
                Log.media.notice("Apple Events denied for Now Playing fallback")
                Task { @MainActor in
                    PermissionCenter.shared.pendingRemediation = .automation
                }
            }
            return nil
        }
        return result.stringValue
    }
}

/// Used when neither the adapter nor Apple Events can work. Emits one empty
/// snapshot so the notch settles into its media-free layout immediately.
public struct DisabledMediaSource: MediaSource {
    public nonisolated let kind: MediaSourceKind = .none

    public init() {}

    public func healthCheck() async -> Bool { true }

    public func updates() -> AsyncStream<MediaSnapshot> {
        AsyncStream { continuation in
            continuation.yield(.empty)
            continuation.finish()
        }
    }

    public func send(_ command: MediaCommand) async throws {}
    public func stop() async {}
}
