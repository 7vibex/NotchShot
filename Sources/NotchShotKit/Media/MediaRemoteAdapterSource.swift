import AppKit
import Darwin
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
/// * the adapter path is explicitly selected by the user,
/// * a compatibility check runs after every macOS build
///   change (`AdapterCompatibility`),
/// * everything sits behind `MediaSource`, so an App Store build can drop this
///   file entirely and lose nothing but universal-app support.
public actor MediaRemoteAdapterSource: MediaSource {

    public nonisolated let kind: MediaSourceKind = .mediaRemote

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

    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isCancelled: Bool {
            lock.withLock { value }
        }

        func cancel() {
            lock.withLock { value = true }
        }
    }

    private enum AdapterCommandError: LocalizedError {
        case failed

        var errorDescription: String? {
            "The Now Playing adapter command failed or timed out."
        }
    }

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
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values?.isRegularFile == true,
              values?.isSymbolicLink != true,
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
        guard let data = await Self.runOnce(
            executableURL: executableURL,
            arguments: ["get"]
        ) else { return false }
        return AdapterPayload.snapshot(from: data) != nil
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
        guard await Self.runOnce(executableURL: executableURL, arguments: arguments) != nil else {
            throw AdapterCommandError.failed
        }
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
        process.environment = Self.sanitizedEnvironment

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

    /// Runs an untrusted, user-selected adapter with hard time and output caps.
    ///
    /// A Foundation Process does not inherit Swift task cancellation. The old
    /// task-group timeout therefore waited forever if the helper hung because a
    /// cancelled child still had to finish. This runner polls a nonblocking
    /// pipe, terminates on timeout/cancellation, and bounds retained output.
    static func runOnce(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval = 3,
        maximumOutputBytes: Int = 1_000_000
    ) async -> Data? {
        let cancellation = CancellationFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let process = Process()
                process.executableURL = executableURL
                process.arguments = arguments
                process.environment = Self.sanitizedEnvironment
                process.standardInput = FileHandle.nullDevice
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
                    let descriptor = output.fileHandleForReading.fileDescriptor
                    let existingFlags = fcntl(descriptor, F_GETFL)
                    if existingFlags >= 0 {
                        _ = fcntl(descriptor, F_SETFL, existingFlags | O_NONBLOCK)
                    }

                    let limit = max(1, maximumOutputBytes)
                    let deadline = ProcessInfo.processInfo.systemUptime + max(0.05, timeout)
                    var data = Data()
                    var exceededLimit = false
                    var timedOut = false
                    var readBuffer = [UInt8](repeating: 0, count: 16_384)

                    func drainAvailableOutput() {
                        while !exceededLimit {
                            let count = readBuffer.withUnsafeMutableBytes { bytes in
                                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
                            }
                            if count > 0 {
                                let remaining = limit - data.count
                                guard count <= remaining else {
                                    if remaining > 0 {
                                        data.append(contentsOf: readBuffer.prefix(remaining))
                                    }
                                    exceededLimit = true
                                    return
                                }
                                data.append(contentsOf: readBuffer.prefix(count))
                                continue
                            }
                            if count == 0 { return }
                            if errno == EINTR { continue }
                            if errno == EAGAIN || errno == EWOULDBLOCK { return }
                            exceededLimit = true
                        }
                    }

                    while process.isRunning {
                        drainAvailableOutput()
                        if exceededLimit || cancellation.isCancelled {
                            break
                        }
                        if ProcessInfo.processInfo.systemUptime >= deadline {
                            timedOut = true
                            break
                        }
                        var pollDescriptor = pollfd(
                            fd: descriptor,
                            events: Int16(POLLIN | POLLHUP),
                            revents: 0
                        )
                        _ = poll(&pollDescriptor, 1, 25)
                    }

                    let mustStop = process.isRunning
                        && (exceededLimit || timedOut || cancellation.isCancelled)
                    if mustStop {
                        process.terminate()
                        let graceDeadline = ProcessInfo.processInfo.systemUptime + 0.2
                        while process.isRunning,
                              ProcessInfo.processInfo.systemUptime < graceDeadline {
                            usleep(10_000)
                        }
                        if process.isRunning {
                            _ = kill(process.processIdentifier, SIGKILL)
                        }
                    }

                    process.waitUntilExit()
                    drainAvailableOutput()
                    output.fileHandleForReading.closeFile()

                    let succeeded = process.terminationStatus == 0
                        && !timedOut
                        && !exceededLimit
                        && !cancellation.isCancelled
                    continuation.resume(returning: succeeded ? data : nil)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static var sanitizedEnvironment: [String: String] {
        [
            "PATH": "/usr/bin:/bin",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "TMPDIR": NSTemporaryDirectory(),
        ]
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
