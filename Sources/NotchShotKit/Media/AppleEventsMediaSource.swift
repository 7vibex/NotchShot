import AppKit
import Foundation
import ImageIO

struct AppleEventsSnapshotFields: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval?
    var position: TimeInterval?
    var isPlaying: Bool
}

/// The last few covers, by track, for every Apple Events source in the
/// process.
final class AppleEventsArtworkCache: @unchecked Sendable {
    private let lock = NSLock()
    /// Guarded by `lock`.
    private var entries: [String: Data] = [:]
    private var order: [String] = []
    private let limit: Int

    /// Album art is a few hundred KB apiece; a handful is plenty of history.
    init(limit: Int = 8) {
        self.limit = limit
    }

    func data(for key: String) -> Data? {
        lock.withLock { entries[key] }
    }

    func insert(_ data: Data, for key: String) {
        lock.withLock {
            // Two sources can miss the same track at once; keep it listed once.
            if entries.updateValue(data, forKey: key) == nil { order.append(key) }
            while order.count > limit {
                entries.removeValue(forKey: order.removeFirst())
            }
        }
    }
}

struct AppleScriptExecution: Sendable {
    var stringValue: String?
    var data: Data?
    var errorNumber: Int?
}

/// `NSAppleScript` is synchronous and may wait several seconds for another
/// application. Every script runs on one dedicated thread, so a slow player
/// delays a poll tick rather than the interface.
///
/// Not the main thread: there, every Apple Event blocked AppKit until the
/// other app answered. Profiled with Spotify playing, polls held the main
/// thread for hundreds of milliseconds and once for over a second, which
/// froze the island mid-open. Not a pool of threads either: `NSAppleScript`
/// is not safe to use concurrently, so compilation, the script cache, and
/// execution are confined to the one thread, one script at a time.
actor AppleScriptExecutor {
    private let timeoutSeconds = 2

    func execute(_ source: String) async -> AppleScriptExecution {
        await ScriptThreadRunner.shared.execute(source, timeoutSeconds: timeoutSeconds)
    }
}

/// Owns every `NSAppleScript` and the thread they run on. One shared runner
/// also means one shared cache: the queue, shuffle/repeat, and Now Playing
/// services read the same compiled scripts instead of each keeping their own.
private final class ScriptThreadRunner: @unchecked Sendable {
    static let shared = ScriptThreadRunner()

    private let condition = NSCondition()
    /// Guarded by `condition`.
    private var jobs: [() -> Void] = []
    /// Touched only on the script thread.
    private var scripts: [String: NSAppleScript] = [:]
    private var scriptOrder: [String] = []
    private let maximumCachedScripts = 16

    private init() {
        let thread = Thread { [unowned self] in run() }
        thread.name = "NotchShot.AppleScript"
        thread.qualityOfService = .utility
        thread.start()
    }

    func execute(_ source: String, timeoutSeconds: Int) async -> AppleScriptExecution {
        await withCheckedContinuation { continuation in
            enqueue {
                continuation.resume(returning: self.run(source, timeoutSeconds: timeoutSeconds))
            }
        }
    }

    private func enqueue(_ job: @escaping () -> Void) {
        condition.lock()
        jobs.append(job)
        condition.signal()
        condition.unlock()
    }

    private func run() {
        while true {
            condition.lock()
            while jobs.isEmpty { condition.wait() }
            let job = jobs.removeFirst()
            condition.unlock()
            autoreleasepool { job() }
        }
    }

    private func run(_ source: String, timeoutSeconds: Int) -> AppleScriptExecution {
        let boundedSource = """
        with timeout of \(timeoutSeconds) seconds
            \(source)
        end timeout
        """
        let cachedScript = scripts[source]
        guard let script = cachedScript ?? NSAppleScript(source: boundedSource) else {
            return AppleScriptExecution(errorNumber: errOSAScriptError)
        }
        if cachedScript == nil {
            scripts[source] = script
            scriptOrder.append(source)
            while scriptOrder.count > maximumCachedScripts {
                scripts.removeValue(forKey: scriptOrder.removeFirst())
            }
        }

        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        let errorNumber = error?[NSAppleScript.errorNumber] as? Int
        return AppleScriptExecution(
            stringValue: error == nil ? result.stringValue : nil,
            data: error == nil && !result.data.isEmpty ? result.data : nil,
            errorNumber: errorNumber
        )
    }
}

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

    static let fieldSeparator = "\u{1F}"

    public nonisolated let kind: MediaSourceKind = .appleEvents

    /// The apps this source can follow, by bundle identifier.
    static let playerBundleIdentifiers: Set<String> = Set(Player.allCases.map(\.rawValue))

    /// Whether an app with this bundle identifier is running.
    @MainActor
    static func isRunning(_ bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

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
    /// rather than on every poll tick. Shared by every instance: the
    /// coordinator builds a new source at each unlock and wake, and a cache of
    /// its own downloaded the same Spotify cover again every time.
    static let artworkCache = AppleEventsArtworkCache()
    private let scriptExecutor = AppleScriptExecutor()
    private let maximumArtworkBytes = 8_000_000
    private let maximumArtworkDimension = 4_096
    private let maximumArtworkPixels = 16_000_000
    private let artworkSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()
    /// Apple Events are synchronous and comparatively expensive, so the poll is
    /// slow by design — the notch interpolates playback position between ticks.
    static let pollInterval: Duration = .seconds(2)
    /// While the Mac is locked and the Lock Screen shows no notch. The poll was
    /// most of what a locked app still did. The coordinator selects a fresh
    /// source at unlock, so this only bounds how old the track is until that
    /// source's first answer.
    static let backgroundPollInterval: Duration = .seconds(10)
    private var pollsInBackground = false

    public init() {}

    /// Takes effect from the next tick.
    func setPollsInBackground(_ background: Bool) {
        pollsInBackground = background
    }

    func nextPollInterval() -> Duration {
        pollsInBackground ? Self.backgroundPollInterval : Self.pollInterval
    }

    public func healthCheck() async -> Bool {
        await runningPlayer() != nil
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
                    try? await Task.sleep(for: await self.nextPollInterval())
                }
            }
        }
    }

    public func send(_ command: MediaCommand) async throws {
        guard let player = await runningPlayer() else { return }
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
        _ = await run(script: "tell application \"\(player.applicationName)\" to \(script)")
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
        var snapshot = await snapshot()
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
        if let cached = Self.artworkCache.data(for: key) { return cached }

        let data: Data?
        switch snapshot.applicationBundleID {
        case Player.music.rawValue:
            data = await musicArtworkData()
        case Player.spotify.rawValue:
            guard let urlString = await spotifyArtworkURL(),
                  let url = URL(string: urlString),
                  url.scheme == "https"
            else { return nil }
            data = await remoteArtwork(from: url)
        default:
            data = nil
        }

        guard let data, !data.isEmpty else { return nil }
        Self.artworkCache.insert(data, for: key)
        return data
    }

    private func remoteArtwork(from url: URL) async -> Data? {
        do {
            let (bytes, response) = try await artworkSession.bytes(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200 ..< 300).contains(http.statusCode),
                  http.url?.scheme?.lowercased() == "https",
                  response.mimeType?.lowercased().hasPrefix("image/") == true,
                  response.expectedContentLength <= Int64(maximumArtworkBytes) else {
                return nil
            }

            var data = Data()
            data.reserveCapacity(max(0, Int(response.expectedContentLength)))
            for try await byte in bytes {
                guard data.count < maximumArtworkBytes else { return nil }
                data.append(byte)
            }
            guard !data.isEmpty, isSafeArtwork(data) else { return nil }
            return data
        } catch {
            return nil
        }
    }

    private func isSafeArtwork(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0,
              width <= maximumArtworkDimension,
              height <= maximumArtworkDimension,
              width <= maximumArtworkPixels / height else {
            return false
        }
        return true
    }

    private static func cacheKey(for snapshot: MediaSnapshot) -> String? {
        guard let title = snapshot.title else { return nil }
        return "\(snapshot.artist ?? "")—\(title)"
    }

    private func musicArtworkData() async -> Data? {
        let source = """
        tell application "Music"
            if player state is stopped then return missing value
            if (count of artworks of current track) is 0 then return missing value
            return raw data of artwork 1 of current track
        end tell
        """
        // `raw data` arrives as a typed image descriptor, not a string.
        return await execute(script: source).data
    }

    private func spotifyArtworkURL() async -> String? {
        await run(script: "tell application \"Spotify\" to get artwork url of current track")
    }

    private func runningPlayer() async -> Player? {
        // Asked by identifier: reading `bundleIdentifier` off every running
        // app went to LaunchServices for most of them on every poll, about
        // 10 M instructions and 5 ms on the main thread each time.
        let running = await MainActor.run {
            Player.allCases.map(\.rawValue).filter(Self.isRunning)
        }
        // Prefer whichever is actually playing, then another responsive player.
        // A merely open app is not a healthy source: treating a timed-out player
        // as usable would start a poll loop that spends two seconds waiting on
        // every cycle while never producing metadata.
        var firstResponsivePlayer: Player?
        for player in Player.allCases where running.contains(player.rawValue) {
            guard let state = await run(
                script: "tell application \"\(player.applicationName)\" to player state as string"
            )?.lowercased() else { continue }
            if state == "playing" {
                return player
            }
            firstResponsivePlayer = firstResponsivePlayer ?? player
        }
        return firstResponsivePlayer
    }

    private func snapshot() async -> MediaSnapshot {
        guard let player = await runningPlayer() else {
            return MediaSnapshot(source: .none)
        }

        let script = Self.snapshotScript(applicationName: player.applicationName)

        guard let output = await run(script: script), output != "stopped" else {
            return MediaSnapshot(
                source: .appleEvents,
                applicationBundleID: player.rawValue,
                applicationName: player.applicationName
            )
        }

        guard let fields = Self.parseSnapshotFields(
            output,
            spotifyDurationIsMilliseconds: player == .spotify
        ) else {
            return MediaSnapshot(source: .appleEvents, applicationBundleID: player.rawValue)
        }

        return MediaSnapshot(
            source: .appleEvents,
            applicationBundleID: player.rawValue,
            applicationName: player.applicationName,
            title: fields.title.isEmpty ? nil : fields.title,
            artist: fields.artist.isEmpty ? nil : fields.artist,
            album: fields.album.isEmpty ? nil : fields.album,
            artworkData: nil,
            duration: fields.duration,
            position: fields.position,
            positionTimestamp: Date(),
            isPlaying: fields.isPlaying,
            supportedCommands: [.play, .pause, .togglePlayPause, .nextTrack, .previousTrack, .seek]
        )
    }

    /// One round-trip for everything: each `tell` is a separate Apple Event
    /// and they add up quickly. The state is asked once, as text, the same
    /// way `runningPlayer()` asks it, and the stopped check reads that text.
    /// `character id` is built in; `ASCII character` is a scripting addition,
    /// which inside the `tell` went to the player, was refused, and was sent
    /// again to this process: two more events, one of them a round trip to
    /// the player, on every poll.
    static func snapshotScript(applicationName: String) -> String {
        """
        tell application "\(applicationName)"
            set theState to player state as string
            if theState is "stopped" then return "stopped"
            set theTitle to name of current track
            set theArtist to artist of current track
            set theAlbum to album of current track
            set theDuration to (duration of current track) as integer
            set thePosition to (player position) as integer
            set fieldSeparator to character id 31
            return theTitle & fieldSeparator & theArtist & fieldSeparator & theAlbum & fieldSeparator & theDuration & fieldSeparator & thePosition & fieldSeparator & theState
        end tell
        """
    }

    static func parseSnapshotFields(
        _ output: String,
        spotifyDurationIsMilliseconds: Bool
    ) -> AppleEventsSnapshotFields? {
        let fields = output.components(separatedBy: fieldSeparator)
        guard fields.count == 6 else { return nil }

        var duration = Double(fields[3])
        if spotifyDurationIsMilliseconds, let value = duration {
            duration = value / 1_000
        }
        if duration?.isFinite != true || (duration ?? 0) <= 0 {
            duration = nil
        }

        var position = Double(fields[4])
        if position?.isFinite != true || (position ?? -1) < 0 {
            position = nil
        }

        return AppleEventsSnapshotFields(
            title: fields[0],
            artist: fields[1],
            album: fields[2],
            duration: duration,
            position: position,
            isPlaying: fields[5].lowercased().contains("playing")
        )
    }

    private func execute(script source: String) async -> AppleScriptExecution {
        let execution = await scriptExecutor.execute(source)
        if let code = execution.errorNumber {
            // -1743 is "not authorised to send Apple Events"; anything else is
            // usually the player simply not being scriptable right now.
            if code == -1743 {
                Log.media.notice("Apple Events denied for Now Playing fallback")
                await MainActor.run {
                    PermissionCenter.shared.pendingRemediation = .automation
                }
            }
        }
        return execution
    }

    private func run(script source: String) async -> String? {
        await execute(script: source).stringValue
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
