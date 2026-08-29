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
    private let approvedIdentity: ExternalFileIdentity?
    private let arguments: [String]
    private let runnerURL: URL?
    private var process: Process?
    private var processGroupID: pid_t?
    private var outputPipe: Pipe?
    private var continuation: AsyncStream<MediaSnapshot>.Continuation?
    private var buffer = Data()

    var runningProcessIdentifier: pid_t? { process?.processIdentifier }

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

    public init(
        executableURL: URL,
        arguments: [String] = ["stream"],
        approvedIdentity: ExternalFileIdentity? = nil,
        runnerURL: URL? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.approvedIdentity = approvedIdentity ?? SafeAssetFile.identity(
            at: executableURL,
            maximumBytes: SafeAssetFile.maximumExternalBytes
        )
        self.runnerURL = runnerURL ?? Self.defaultRunnerURL
    }

    /// Builds a source from the configured preference, if it points at
    /// something that exists and is executable.
    @MainActor
    public static func configured() -> MediaRemoteAdapterSource? {
        guard let path = Preferences.shared.mediaRemoteAdapterPath, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let approvedIdentity = Preferences.shared.mediaRemoteAdapterIdentity,
              Self.isApprovedExecutable(url, identity: approvedIdentity)
        else {
            Log.media.notice("Adapter path changed or is no longer executable: \(path)")
            return nil
        }
        return MediaRemoteAdapterSource(
            executableURL: url,
            approvedIdentity: approvedIdentity
        )
    }

    // MARK: MediaSource

    /// Runs the adapter once with a short timeout. Anything other than a clean,
    /// parseable response counts as unhealthy.
    public func healthCheck() async -> Bool {
        guard let data = await Self.runOnce(
            executableURL: executableURL,
            approvedIdentity: approvedIdentity,
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
        case .seek(let position):
            guard position.isFinite,
                  position >= 0,
                  position <= Double(Int32.max) else {
                throw AdapterCommandError.failed
            }
            arguments = ["send", "seek", String(Int(position.rounded()))]
        }
        guard await Self.runOnce(
            executableURL: executableURL,
            approvedIdentity: approvedIdentity,
            arguments: arguments
        ) != nil else {
            throw AdapterCommandError.failed
        }
    }

    public func stop() async {
        let runningProcess = process
        process = nil
        let groupID = processGroupID
        processGroupID = nil
        let pipe = outputPipe
        outputPipe = nil
        pipe?.fileHandleForReading.readabilityHandler = nil
        runningProcess?.terminationHandler = nil
        if let runningProcess, runningProcess.isRunning {
            if let groupID {
                _ = kill(-groupID, SIGTERM)
            } else {
                runningProcess.terminate()
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 0.3
            while (groupID.map(Self.processGroupExists) ?? runningProcess.isRunning),
                  ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            if let groupID {
                if Self.processGroupExists(groupID) {
                    _ = kill(-groupID, SIGKILL)
                }
            } else if runningProcess.isRunning {
                _ = kill(runningProcess.processIdentifier, SIGKILL)
            }
            runningProcess.waitUntilExit()
        }
        pipe?.fileHandleForReading.closeFile()
        continuation?.finish()
        continuation = nil
        buffer.removeAll()
    }

    // MARK: Process plumbing

    private func start(continuation: AsyncStream<MediaSnapshot>.Continuation) {
        guard let approvedIdentity,
              Self.isApprovedExecutable(executableURL, identity: approvedIdentity),
              let runnerURL,
              Self.isTrustedRunner(runnerURL) else {
            Log.media.error("The approved media adapter changed before launch")
            continuation.yield(.empty)
            continuation.finish()
            return
        }
        let process = Process()
        process.executableURL = runnerURL
        process.arguments = Self.runnerArguments(
            executableURL: executableURL,
            identity: approvedIdentity,
            arguments: arguments
        )
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

        process.terminationHandler = { terminated in
            Task {
                Log.media.notice("Media adapter exited; falling back")
                await self.handleTermination(processID: terminated.processIdentifier)
            }
        }

        do {
            try process.run()
            let pid = process.processIdentifier
            guard Self.waitForDedicatedProcessGroup(processID: pid) else {
                process.terminate()
                process.waitUntilExit()
                throw AdapterCommandError.failed
            }
            processGroupID = pid
            self.process = process
            self.outputPipe = output
            Log.media.info("Media adapter started: \(self.executableURL.lastPathComponent)")
        } catch {
            Log.media.error("Could not start media adapter: \(error.localizedDescription)")
            continuation.yield(.empty)
            continuation.finish()
        }
    }

    private func handleTermination(processID: pid_t) {
        guard process?.processIdentifier == processID else { return }
        if processGroupID == processID, Self.processGroupExists(processID) {
            _ = kill(-processID, SIGKILL)
        }
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        processGroupID = nil
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
        approvedIdentity: ExternalFileIdentity? = nil,
        arguments: [String],
        timeout: TimeInterval = 3,
        maximumOutputBytes: Int = 1_000_000
    ) async -> Data? {
        guard let approvedIdentity = approvedIdentity ?? SafeAssetFile.identity(
            at: executableURL,
            maximumBytes: SafeAssetFile.maximumExternalBytes
        ), isApprovedExecutable(executableURL, identity: approvedIdentity),
           let runnerURL = defaultRunnerURL,
           isTrustedRunner(runnerURL) else {
            return nil
        }
        let cancellation = CancellationFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let process = Process()
                process.executableURL = runnerURL
                process.arguments = runnerArguments(
                    executableURL: executableURL,
                    identity: approvedIdentity,
                    arguments: arguments
                )
                process.environment = Self.sanitizedEnvironment
                process.standardInput = FileHandle.nullDevice
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                    guard waitForDedicatedProcessGroup(
                        processID: process.processIdentifier
                    ) else {
                        process.terminate()
                        process.waitUntilExit()
                        continuation.resume(returning: nil)
                        return
                    }
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
                        _ = kill(-process.processIdentifier, SIGTERM)
                        let graceDeadline = ProcessInfo.processInfo.systemUptime + 0.2
                        while processGroupExists(process.processIdentifier),
                              ProcessInfo.processInfo.systemUptime < graceDeadline {
                            usleep(10_000)
                        }
                        if processGroupExists(process.processIdentifier) {
                            _ = kill(-process.processIdentifier, SIGKILL)
                        }
                    }

                    process.waitUntilExit()
                    // A helper can exit successfully after forking. Never let
                    // descendants escape merely because their parent returned.
                    if processGroupExists(process.processIdentifier) {
                        _ = kill(-process.processIdentifier, SIGTERM)
                        usleep(20_000)
                        if processGroupExists(process.processIdentifier) {
                            _ = kill(-process.processIdentifier, SIGKILL)
                        }
                    }
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

    nonisolated static func isApprovedExecutable(
        _ url: URL,
        identity: ExternalFileIdentity
    ) -> Bool {
        SafeAssetFile.identity(
            at: url,
            maximumBytes: SafeAssetFile.maximumExternalBytes
        ) == identity && FileManager.default.isExecutableFile(atPath: url.path)
    }

    nonisolated static var defaultRunnerURL: URL? {
        let fileManager = FileManager.default
        return runnerCandidates().first {
            fileManager.isExecutableFile(atPath: $0.path)
        }
    }

    private nonisolated static func isTrustedRunner(_ url: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return false }
        return runnerCandidates().contains(url.standardizedFileURL)
    }

    private nonisolated static func runnerCandidates() -> [URL] {
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        let bundled = bundleURL
            .appendingPathComponent("Contents/MacOS/NotchShotAdapterRunner")
            .standardizedFileURL
        guard Bundle.main.bundleIdentifier != "com.notchshot.app" else { return [bundled] }

#if !DEBUG
        // The search below exists so a test host, which has neither the app's
        // bundle identifier nor its layout, can still find the runner. A
        // shipped build has no use for it and should not carry a widened notion
        // of "trusted runner" on a path that ends in `execv`.
        return [bundled]
#else
        var candidates = [bundled]
        var directory = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .standardizedFileURL
        for _ in 0 ..< 5 {
            candidates.append(
                directory.appendingPathComponent("NotchShotAdapterRunner").standardizedFileURL
            )
            directory.deleteLastPathComponent()
        }
        for index in 0 ..< _dyld_image_count() {
            guard let name = _dyld_get_image_name(index) else { continue }
            let path = String(cString: name)
            guard path.contains(".xctest/") else { continue }
            var imageDirectory = URL(fileURLWithPath: path).deletingLastPathComponent()
            for _ in 0 ..< 5 {
                candidates.append(
                    imageDirectory
                        .appendingPathComponent("NotchShotAdapterRunner")
                        .standardizedFileURL
                )
                imageDirectory.deleteLastPathComponent()
            }
        }
        var unique: [URL] = []
        for candidate in candidates where !unique.contains(candidate) {
            unique.append(candidate)
        }
        return unique
#endif
    }

    private nonisolated static func waitForDedicatedProcessGroup(processID: pid_t) -> Bool {
        for _ in 0 ..< 100 {
            if getpgid(processID) == processID { return true }
            // A short-lived command may finish before the parent observes its
            // group. There can be no surviving group if the PID no longer
            // exists, so let normal exit-status validation decide success.
            if kill(processID, 0) != 0 { return true }
            usleep(1_000)
        }
        return false
    }

    private nonisolated static func runnerArguments(
        executableURL: URL,
        identity: ExternalFileIdentity,
        arguments: [String]
    ) -> [String] {
        [
            String(identity.device),
            String(identity.inode),
            String(identity.size),
            String(identity.modifiedSeconds),
            String(identity.modifiedNanoseconds),
            executableURL.path,
        ] + arguments
    }

    private nonisolated static func processGroupExists(_ processGroupID: pid_t) -> Bool {
        errno = 0
        return kill(-processGroupID, 0) == 0 || errno == EPERM
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

        // `totalDiscNumber` used to sit in this chain. It is a disc count, not a
        // time, so a payload that spelled duration differently handed the notch
        // a one- or two-second track: the progress bar pinned instantly and the
        // seek range collapsed.
        let duration = number(payload, "duration", "playbackDuration", "totalDuration")
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
            if let value = payload[key] as? Double, value.isFinite, value >= 0 { return value }
            if let value = payload[key] as? Int, value >= 0 { return Double(value) }
            if let value = payload[key] as? String,
               let parsed = Double(value), parsed.isFinite, parsed >= 0 { return parsed }
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
