import AppKit
import CoreGraphics
import Darwin
import Foundation
import Observation

// MARK: - Bounded process

/// Runs a fixed executable with arguments — never through a shell — and
/// returns what it printed. Output is capped and the process is killed at
/// the timeout, so a hung `gh` or a Shortcut waiting on a dialog can't pin a
/// background thread forever.
enum BoundedProcess {
    struct Result: Sendable {
        var status: Int32
        var output: String
        var errorOutput: String
        var timedOut: Bool
    }

    static let maximumOutputBytes = 1_000_000

    static func run(
        _ executable: URL,
        _ arguments: [String],
        timeout: TimeInterval = 30
    ) async throws -> Result {
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try execute(
                            executable, arguments, timeout: timeout, cancellation: cancellation
                        ))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func execute(
        _ executable: URL, _ arguments: [String], timeout: TimeInterval,
        cancellation: CancellationFlag
    ) throws -> Result {
        guard !cancellation.isCancelled else { throw CancellationError() }
        let target = executable.resolvingSymlinksInPath()
        guard let runner = MediaRemoteAdapterSource.defaultRunnerURL,
              let identity = SafeAssetFile.identity(at: target, maximumBytes: SafeAssetFile.maximumExternalBytes) else {
            throw CocoaError(.executableNotLoadable)
        }
        let process = Process()
        process.executableURL = runner
        process.arguments = [
            String(identity.device), String(identity.inode), String(identity.size),
            String(identity.modifiedSeconds), String(identity.modifiedNanoseconds), target.path,
        ] + arguments
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        defer {
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            try? errors.fileHandleForReading.close()
            try? errors.fileHandleForWriting.close()
        }
        try process.run()
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        let pid = process.processIdentifier
        var dedicatedGroup = false
        for _ in 0..<100 {
            if getpgid(pid) == pid || kill(pid, 0) != 0 { dedicatedGroup = true; break }
            usleep(1_000)
        }
        guard dedicatedGroup else {
            _ = kill(pid, SIGKILL)
            _ = exited.wait(timeout: .now() + 1)
            throw CocoaError(.executableNotLoadable)
        }
        let outFD = output.fileHandleForReading.fileDescriptor
        let errFD = errors.fileHandleForReading.fileDescriptor
        for fd in [outFD, errFD] {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                stopGroup(pid)
                _ = exited.wait(timeout: .now() + 1)
                throw CocoaError(.fileReadUnknown)
            }
        }
        var stdout = Data()
        var stderr = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        func drain(_ fd: Int32, into data: inout Data, limit: Int) -> Bool {
            // Yield to the deadline check even if a producer never stops writing.
            for _ in 0..<16 {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    let remaining = max(0, limit - data.count)
                    if remaining > 0 { data.append(contentsOf: buffer.prefix(min(count, remaining))) }
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    return count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)
                }
            }
            return true
        }
        let deadline = ProcessInfo.processInfo.systemUptime + max(1, timeout)
        var timedOut = false
        var outputOpen = true
        var errorsOpen = true
        while process.isRunning {
            if outputOpen { outputOpen = drain(outFD, into: &stdout, limit: maximumOutputBytes) }
            if errorsOpen { errorsOpen = drain(errFD, into: &stderr, limit: 64_000) }
            if cancellation.isCancelled { break }
            if ProcessInfo.processInfo.systemUptime >= deadline { timedOut = true; break }
            var descriptors = [
                pollfd(fd: outputOpen ? outFD : -1, events: Int16(POLLIN | POLLHUP), revents: 0),
                pollfd(fd: errorsOpen ? errFD : -1, events: Int16(POLLIN | POLLHUP), revents: 0),
            ]
            _ = poll(&descriptors, 2, 20)
        }
        // The verified runner owns a dedicated group. Stop descendants even
        // when their parent exited normally but left an inherited pipe open.
        stopGroup(pid)
        guard exited.wait(timeout: .now() + 1) == .success else {
            throw CocoaError(.executableRuntimeMismatch)
        }
        _ = drain(outFD, into: &stdout, limit: maximumOutputBytes)
        _ = drain(errFD, into: &stderr, limit: 64_000)
        guard !cancellation.isCancelled else { throw CancellationError() }
        return Result(
            status: process.terminationStatus,
            output: String(decoding: stdout, as: UTF8.self),
            errorOutput: String(decoding: stderr, as: UTF8.self),
            timedOut: timedOut
        )
    }

    private static func stopGroup(_ pid: pid_t) {
        guard kill(-pid, 0) == 0 || errno == EPERM else { return }
        _ = kill(-pid, SIGTERM)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        while (kill(-pid, 0) == 0 || errno == EPERM), ProcessInfo.processInfo.systemUptime < deadline {
            usleep(10_000)
        }
        _ = kill(-pid, SIGKILL)
    }

    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.withLock { cancelled = true } }
        var isCancelled: Bool { lock.withLock { cancelled } }
    }

    /// The first executable found at any of `paths`.
    static func locate(_ paths: [String]) -> URL? {
        paths.lazy
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

// MARK: - Shortcuts

/// The user's Shortcuts, through Apple's own `shortcuts` command-line tool.
public enum ShortcutsService {
    static let executable = URL(fileURLWithPath: "/usr/bin/shortcuts")

    public enum ShortcutsError: LocalizedError {
        case unavailable
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .unavailable: "The Shortcuts command-line tool isn't available on this Mac."
            case .failed(let message): message
            }
        }
    }

    public static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: executable.path)
    }

    /// Every shortcut name, in the order Shortcuts lists them.
    public static func list() async throws -> [String] {
        guard isAvailable else { throw ShortcutsError.unavailable }
        let result = try await BoundedProcess.run(executable, ["list"], timeout: 20)
        guard result.status == 0 else {
            throw ShortcutsError.failed(result.errorOutput.trimmedNonEmpty ?? "Shortcuts could not be listed.")
        }
        return parseList(result.output)
    }

    static func parseList(_ output: String) -> [String] {
        var seen = Set<String>()
        return output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Runs a shortcut and returns any text it produced, or nil when it
    /// produced none. Shortcuts that ask a question show their own dialog.
    public static func run(_ name: String) async throws -> String? {
        guard isAvailable else { throw ShortcutsError.unavailable }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-shortcut-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let result = try await BoundedProcess.run(
            executable,
            ["run", name, "--output-path", outputURL.path, "--output-type", "public.plain-text"],
            timeout: 120
        )
        if result.timedOut { throw ShortcutsError.failed("\(name) took longer than two minutes and was stopped.") }
        guard result.status == 0 else {
            throw ShortcutsError.failed(result.errorOutput.trimmedNonEmpty ?? "\(name) didn't finish.")
        }
        let text = (try? String(contentsOf: outputURL, encoding: .utf8))?.trimmedNonEmpty
        return text.map { String($0.prefix(2_000)) }
    }
}

// MARK: - Running apps

/// A running app the switcher can bring forward, hide, or quit.
public struct RunningAppEntry: Identifiable, Equatable, Sendable {
    public var id: pid_t
    public var name: String
    public var bundleIdentifier: String?
    public var bundleURL: URL?
    public var isActive: Bool
    public var isHidden: Bool
}

@MainActor
public enum AppSwitcher {
    /// Regular (Dock) apps, the frontmost first, NotchShot itself excluded.
    public static func runningApps() -> [RunningAppEntry] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPID && !$0.isTerminated }
            .map {
                RunningAppEntry(
                    id: $0.processIdentifier,
                    name: $0.localizedName ?? $0.bundleIdentifier ?? "App",
                    bundleIdentifier: $0.bundleIdentifier,
                    bundleURL: $0.bundleURL,
                    isActive: $0.isActive,
                    isHidden: $0.isHidden
                )
            }
            .sorted { lhs, rhs in
                if lhs.isActive != rhs.isActive { return lhs.isActive }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    public static func activate(_ entry: RunningAppEntry) {
        guard let app = NSRunningApplication(processIdentifier: entry.id) else { return }
        app.unhide()
        app.activate()
    }

    public static func hide(_ entry: RunningAppEntry) {
        NSRunningApplication(processIdentifier: entry.id)?.hide()
    }

    /// A normal quit: the app still asks about unsaved documents.
    public static func quit(_ entry: RunningAppEntry) {
        NSRunningApplication(processIdentifier: entry.id)?.terminate()
    }
}

// MARK: - Review queue

/// A pull request waiting for the user's review.
public struct ReviewRequest: Identifiable, Equatable, Sendable, Decodable {
    public struct Repository: Equatable, Sendable, Decodable {
        public var nameWithOwner: String
    }

    public struct Author: Equatable, Sendable, Decodable {
        public var login: String
    }

    public var number: Int
    public var title: String
    public var url: URL
    public var repository: Repository
    public var author: Author?
    public var updatedAt: Date
    public var isDraft: Bool?

    public var id: URL { url }
}

/// Reads review requests through the GitHub CLI the user is already signed
/// in to. NotchShot never sees or stores a GitHub token.
public enum ReviewQueueService {
    public enum ReviewQueueError: LocalizedError {
        case cliMissing
        case notSignedIn
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .cliMissing: "Install the GitHub CLI (gh) to see review requests."
            case .notSignedIn: "Run `gh auth login` in Terminal, then refresh."
            case .failed(let message): message
            }
        }
    }

    static var executable: URL? {
        BoundedProcess.locate(["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"])
    }

    public static func fetch(limit: Int = 30) async throws -> [ReviewRequest] {
        guard let executable else { throw ReviewQueueError.cliMissing }
        let result = try await BoundedProcess.run(executable, [
            "search", "prs",
            "--review-requested=@me",
            "--state=open",
            "--limit", String(max(1, min(limit, 100))),
            "--json", "number,title,url,repository,author,updatedAt,isDraft",
        ], timeout: 30)
        guard result.status == 0 else {
            let message = result.errorOutput.lowercased()
            if message.contains("auth login") || message.contains("not logged") {
                throw ReviewQueueError.notSignedIn
            }
            throw ReviewQueueError.failed(result.errorOutput.trimmedNonEmpty ?? "gh exited with \(result.status).")
        }
        return try decode(Data(result.output.utf8))
    }

    static func decode(_ data: Data) throws -> [ReviewRequest] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([ReviewRequest].self, from: data)
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}

// MARK: - Day progress

/// How far through the working day it is, for the Today page.
public struct DayProgress: Equatable, Sendable {
    public var fraction: Double
    public var remaining: TimeInterval
    public var isBeforeStart: Bool
    public var isAfterEnd: Bool

    public static func at(
        _ date: Date,
        startHour: Int,
        endHour: Int,
        calendar: Calendar = .current
    ) -> DayProgress {
        let start = calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: date) ?? date
        let endHourClamped = max(endHour, startHour + 1)
        let end = endHourClamped >= 24
            ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date
            : calendar.date(bySettingHour: endHourClamped, minute: 0, second: 0, of: date) ?? date
        let total = max(end.timeIntervalSince(start), 1)
        let elapsed = date.timeIntervalSince(start)
        return DayProgress(
            fraction: min(max(elapsed / total, 0), 1),
            remaining: max(end.timeIntervalSince(date), 0),
            isBeforeStart: elapsed < 0,
            isAfterEnd: date >= end
        )
    }
}

// MARK: - Activity sampling

/// Seconds since the last keyboard, mouse or trackpad event.
enum UserIdleTime {
    static func seconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}

// MARK: - Eye breaks

/// The 20-20-20 reminder. Counts continuous use in one-minute samples; a
/// stretch away from the keyboard longer than a break resets the count, so
/// coming back from lunch never triggers a reminder straight away.
public struct EyeBreakTracker: Equatable, Sendable {
    public static let breakResetSeconds: TimeInterval = 5 * 60
    public var activeSeconds: TimeInterval = 0

    /// Feeds one sample. Returns true when a reminder is due, and restarts the
    /// count when it is.
    public mutating func record(
        interval: TimeInterval,
        idleSeconds: TimeInterval,
        reminderAfter threshold: TimeInterval
    ) -> Bool {
        if idleSeconds >= Self.breakResetSeconds {
            activeSeconds = 0
            return false
        }
        // An idle minute still counts if it was shorter than a real break:
        // reading a page without touching the mouse is still screen time.
        activeSeconds += interval
        guard activeSeconds >= threshold else { return false }
        activeSeconds = 0
        return true
    }
}

// MARK: - Screen time

/// Seconds per frontmost app per day, kept on this Mac only.
public struct ScreenTimeLedger: Codable, Equatable, Sendable {
    public static let retainedDays = 14
    /// "yyyy-MM-dd" → bundle identifier → seconds.
    public var days: [String: [String: TimeInterval]] = [:]
    /// Bundle identifier → display name, so a removed app still has a name.
    public var names: [String: String] = [:]

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public mutating func add(_ seconds: TimeInterval, bundleIdentifier: String, name: String, at date: Date) {
        let key = Self.dayKey(date)
        days[key, default: [:]][bundleIdentifier, default: 0] += seconds
        names[bundleIdentifier] = name
        if days.count > Self.retainedDays {
            for stale in days.keys.sorted().dropLast(Self.retainedDays) {
                days.removeValue(forKey: stale)
            }
        }
    }

    /// The day's apps, longest first.
    public func usage(on date: Date) -> [(bundleIdentifier: String, name: String, seconds: TimeInterval)] {
        (days[Self.dayKey(date)] ?? [:])
            .map { ($0.key, names[$0.key] ?? $0.key, $0.value) }
            .sorted { $0.2 > $1.2 }
    }
}

/// Samples the frontmost app every 30 seconds while the user is active, and
/// shows reminders for eye breaks. Both are off until turned on in Settings.
@MainActor
@Observable
public final class WellbeingMonitor {
    public static let sampleInterval: TimeInterval = 30
    /// Idle longer than this and the sample doesn't count as screen time.
    static let activeIdleLimit: TimeInterval = 90

    public private(set) var ledger: ScreenTimeLedger
    @ObservationIgnored private var eyeBreaks = EyeBreakTracker()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let storeURL: URL
    @ObservationIgnored private var unsavedSamples = 0
    @ObservationIgnored var onEyeBreakDue: (() -> Void)?

    public init(storeURL: URL = AppPaths.support.appendingPathComponent("screen-time.json")) {
        self.storeURL = storeURL
        ledger = (try? Data(contentsOf: storeURL))
            .flatMap { try? JSONDecoder().decode(ScreenTimeLedger.self, from: $0) } ?? ScreenTimeLedger()
    }

    /// Starts or stops sampling to match Settings.
    public func refresh() {
        let extras = ExtrasPreferences.shared
        let needed = extras.screenTimeEnabled || extras.eyeBreaksEnabled
        if needed, timer == nil {
            let timer = Timer(timeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sample() }
            }
            timer.tolerance = 5
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !needed {
            timer?.invalidate()
            timer = nil
            save()
        }
    }

    public func clearScreenTime() {
        ledger = ScreenTimeLedger()
        try? FileManager.default.removeItem(at: storeURL)
    }

    private func sample() {
        let extras = ExtrasPreferences.shared
        let idle = UserIdleTime.seconds()
        if extras.eyeBreaksEnabled,
           eyeBreaks.record(
               interval: Self.sampleInterval,
               idleSeconds: idle,
               reminderAfter: TimeInterval(extras.eyeBreakIntervalMinutes * 60)
           ) {
            onEyeBreakDue?()
        }
        guard extras.screenTimeEnabled, idle < Self.activeIdleLimit,
              let app = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = app.bundleIdentifier else { return }
        ledger.add(
            Self.sampleInterval,
            bundleIdentifier: bundleIdentifier,
            name: app.localizedName ?? bundleIdentifier,
            at: Date()
        )
        unsavedSamples += 1
        // Every five minutes rather than every sample: the ledger is small,
        // but there's no reason to touch the disk twice a minute.
        if unsavedSamples >= 10 { save() }
    }

    func save() {
        guard unsavedSamples > 0 else { return }
        unsavedSamples = 0
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
    }
}

extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
