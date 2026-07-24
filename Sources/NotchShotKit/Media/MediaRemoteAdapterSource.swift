import AppKit
import Foundation

/// Bridges to the third-party `mediaremote-adapter` helper (BSD-licensed),
/// which is the only way to read system-wide Now Playing state — Spotify,
/// Music, Safari, Chrome — on current macOS without private linkage.
///
/// The helper is **not vendored**. NotchShot spawns whatever the user points it
/// at, reads newline-delimited JSON from its stdout, and treats every failure as
/// "no media" rather than an error, because a broken bridge must never take the
/// notch down with it.
///
/// Because it rides on undocumented system behaviour, three guards apply:
///
/// * the adapter path and its expected version are pinned in preferences,
/// * a compatibility check runs on first launch and after every macOS build
///   change (`AdapterCompatibility`),
/// * everything sits behind `MediaSource`, so an App Store build can drop this
///   file entirely and lose nothing but universal-app support.
public actor MediaRemoteAdapterSource: MediaSource {

    public nonisolated let kind: MediaSourceKind = .mediaRemote

    /// The adapter release this integration was written against.
    public static let pinnedAdapterVersion = "1.0"
    /// Kept with the binary as required by the adapter's BSD licence.
    public static let licenseNotice = """
    NotchShot optionally uses mediaremote-adapter, distributed under the \
    BSD 3-Clause License. The adapter is not bundled with NotchShot; it is \
    launched from a location you choose. See the adapter's own LICENSE file \
    for the full text and copyright notice.
    """

    private let executableURL: URL
    private let arguments: [String]
    private var process: Process?
    private var continuation: AsyncStream<MediaSnapshot>.Continuation?
    private var buffer = Data()

    public init(executableURL: URL, arguments: [String] = ["stream"]) {
        self.executableURL = executableURL
        self.arguments = arguments
    }

    /// Builds a source from the configured preference, if it points at
    /// something that exists and is executable.
    @MainActor
    public static func configured() -> MediaRemoteAdapterSource? {
        guard let path = Preferences.shared.mediaRemoteAdapterPath, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: url.path)
        else {
            Log.media.notice("Adapter path is missing or not executable: \(path)")
            return nil
        }
        return MediaRemoteAdapterSource(executableURL: url)
    }

    // MARK: MediaSource

    /// Runs the adapter once with a short timeout. Anything other than a clean,
    /// parseable response counts as unhealthy.
    public func healthCheck() async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { [executableURL] in
                await Self.runOnce(executableURL: executableURL, arguments: ["get"]) != nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    public func updates() -> AsyncStream<MediaSnapshot> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { _ in
                Task { await self.stop() }
            }
            start(continuation: continuation)
        }
    }

    public func send(_ command: MediaCommand) async throws {
        let arguments: [String]
        switch command {
        case .play: arguments = ["send", "play"]
        case .pause: arguments = ["send", "pause"]
        case .togglePlayPause: arguments = ["send", "togglePlayPause"]
        case .nextTrack: arguments = ["send", "nextTrack"]
        case .previousTrack: arguments = ["send", "previousTrack"]
        case .seek(let position): arguments = ["send", "seek", String(Int(position))]
        }
        _ = await Self.runOnce(executableURL: executableURL, arguments: arguments)
    }

    public func stop() async {
        process?.terminationHandler = nil
        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        continuation?.finish()
        continuation = nil
        buffer.removeAll()
    }

    // MARK: Process plumbing

    private func start(continuation: AsyncStream<MediaSnapshot>.Continuation) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let output = Pipe()
        process.standardOutput = output
        // The adapter is chatty on stderr about system quirks; that is not our
        // business and must not fill a pipe buffer and stall the child.
        process.standardError = FileHandle.nullDevice

        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self.ingest(data) }
        }

        process.terminationHandler = { _ in
            Task {
                Log.media.notice("Media adapter exited; falling back")
                await self.handleTermination()
            }
        }

        do {
            try process.run()
            self.process = process
            Log.media.info("Media adapter started: \(self.executableURL.lastPathComponent)")
        } catch {
            Log.media.error("Could not start media adapter: \(error.localizedDescription)")
            continuation.yield(.empty)
            continuation.finish()
        }
    }

    private func handleTermination() {
        continuation?.yield(.empty)
        continuation?.finish()
        continuation = nil
        process = nil
    }

    /// Accumulates stdout and emits one snapshot per complete JSON line. A
    /// malformed line is skipped, never fatal.
    private func ingest(_ data: Data) {
        buffer.append(data)
        // Cap the buffer so a wedged adapter emitting no newlines can't grow
        // memory without bound.
        if buffer.count > 4_000_000 {
            Log.media.error("Adapter output exceeded the buffer limit; resetting")
            buffer.removeAll()
            return
        }

        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex ..< newlineIndex]
            buffer.removeSubrange(buffer.startIndex ... newlineIndex)
            guard !lineData.isEmpty else { continue }
            if let snapshot = AdapterPayload.snapshot(from: Data(lineData)) {
                continuation?.yield(snapshot)
            }
        }
    }

    private static func runOnce(executableURL: URL, arguments: [String]) async -> Data? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
                return
            }

            DispatchQueue.global(qos: .utility).async {
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let succeeded = process.terminationStatus == 0 && !data.isEmpty
                continuation.resume(returning: succeeded ? data : nil)
            }
        }
    }
}

/// Tolerant decoder for the adapter's JSON.
///
/// Key names are matched leniently on purpose: the adapter's payload has
/// changed spelling between releases, and a renamed field should degrade one
/// piece of metadata, not blank the whole notch.
enum AdapterPayload {

    static func snapshot(from data: Data) -> MediaSnapshot? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // Some releases wrap everything in `payload`, some don't.
        let payload = (object["payload"] as? [String: Any]) ?? object

        let title = string(payload, "title")
        let artist = string(payload, "artist", "trackArtist", "albumArtist")
        let album = string(payload, "album")
        let bundleID = string(payload, "bundleIdentifier", "bundleID", "parentApplicationBundleIdentifier")

        // A payload with no identifying metadata means nothing is playing.
        guard title != nil || artist != nil else {
            return MediaSnapshot(source: .mediaRemote, applicationBundleID: bundleID)
        }

        let duration = number(payload, "duration", "totalDiscNumber", "playbackDuration")
        let elapsed = number(payload, "elapsedTime", "currentTime", "position")
        let isPlaying = boolean(payload, "playing", "isPlaying", "playbackRate") ?? false

        var artworkData: Data?
        if let base64 = string(payload, "artworkData", "artwork") {
            artworkData = Data(base64Encoded: base64, options: .ignoreUnknownCharacters)
        }

        let applicationName = bundleID.flatMap { identifier -> String? in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
                return nil
            }
            return FileManager.default.displayName(atPath: url.path)
        }

        return MediaSnapshot(
            source: .mediaRemote,
            applicationBundleID: bundleID,
            applicationName: applicationName,
            title: title,
            artist: artist,
            album: album,
            artworkData: artworkData,
            duration: duration,
            position: elapsed,
            positionTimestamp: elapsed != nil ? Date() : nil,
            isPlaying: isPlaying,
            supportedCommands: [.play, .pause, .togglePlayPause, .nextTrack, .previousTrack, .seek]
        )
    }

    private static func string(_ payload: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            if let value = payload[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func number(_ payload: [String: Any], _ keys: String...) -> Double? {
        for key in keys {
            if let value = payload[key] as? Double { return value }
            if let value = payload[key] as? Int { return Double(value) }
            if let value = payload[key] as? String, let parsed = Double(value) { return parsed }
        }
        return nil
    }

    private static func boolean(_ payload: [String: Any], _ keys: String...) -> Bool? {
        for key in keys {
            if let value = payload[key] as? Bool { return value }
            if let value = payload[key] as? Int { return value != 0 }
            if let value = payload[key] as? Double { return value > 0 }
        }
        return nil
    }
}

/// Tracks whether the adapter has been verified against the running OS build.
@MainActor
public enum AdapterCompatibility {

    public static var currentSystemBuild: String {
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buffer = [UInt8](repeating: 0, count: size)
        sysctlbyname("kern.osversion", &buffer, &size, nil, 0)
        // sysctl returns a NUL-terminated C string; trim it before decoding.
        let bytes = buffer.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// True when the adapter needs re-testing: never tested, or macOS has been
    /// updated since the last successful test.
    public static var needsCheck: Bool {
        Preferences.shared.lastAdapterCheckBuild != currentSystemBuild
    }

    public static func recordSuccessfulCheck() {
        Preferences.shared.lastAdapterCheckBuild = currentSystemBuild
    }

    public static func recordFailedCheck() {
        Preferences.shared.lastAdapterCheckBuild = nil
    }
}
