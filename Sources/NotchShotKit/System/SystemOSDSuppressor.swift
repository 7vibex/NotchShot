import AppKit
import Darwin
import Foundation
import Security

/// Experimental direct-distribution replacement for the shared macOS OSD.
///
/// Apple exposes no supported suppression API. Every SIGSTOP is therefore
/// leased to a separately signed watchdog. If NotchShot quits, crashes, or is
/// force-killed, the kernel closes the lease and the watchdog sends SIGCONT.
@MainActor
public final class SystemOSDSuppressor {
    public static let shared = SystemOSDSuppressor()

    nonisolated private static let bundleIdentifier = "com.apple.OSDUIHelper"
    nonisolated private static let bundleURL = URL(
        fileURLWithPath: "/System/Library/CoreServices/OSDUIHelper.app"
    )
    nonisolated private static let executablePath = bundleURL
        .appendingPathComponent("Contents/MacOS/OSDUIHelper")
        .standardizedFileURL.path
    private static let recoveryExecutableName = "NotchShotOSDRecovery"

    private struct Watchdog {
        var token: UUID
        var process: Process
        var lease: Pipe
    }

    private struct ProcessIdentity: Equatable {
        var processID: pid_t
        var startSeconds: UInt64
        var startMicroseconds: UInt64
        var status: UInt32
    }

    private var isEnabled = false
    private var observers: [NSObjectProtocol] = []
    private var pausedProcessIDs: Set<pid_t> = []
    private var watchdogs: [pid_t: Watchdog] = [:]
    private var launchTask: Task<Void, Never>?
    private let mediaKeyInterceptor = SystemMediaKeyInterceptor()

    var onSystemMediaKey: ((SystemMediaKeyAction) -> Bool)? {
        didSet { mediaKeyInterceptor.onKeyDown = onSystemMediaKey }
    }

    /// Internal, not public. The suppressor owns a SIGSTOP lease on an Apple
    /// system process and an event tap keyed to its own address; a second
    /// instance would be a second, uncoordinated owner of both.
    init() {}

    public var isSuppressing: Bool {
        isEnabled && !pausedProcessIDs.isEmpty
    }

    public var needsInputMonitoringPermission: Bool {
        guard #available(macOS 26.5, *) else { return false }
        return isEnabled && !mediaKeyInterceptor.isRunning
    }

    public var isCrashRecoveryAvailable: Bool {
        recoveryExecutableURL != nil
    }

    public var hasStoppedSystemOSD: Bool {
        runningHelpers().contains { application in
            Self.processIdentity(for: application.processIdentifier)?.status == UInt32(SSTOP)
        }
    }

    public func start() {
        guard !isEnabled else {
            if pausedProcessIDs.isEmpty { pauseHelper() }
            return
        }
        setEnabled(Preferences.shared.suppressesSystemOSD)
    }

    /// One-time migration for pre-watchdog builds. This deliberately operates
    /// only on Apple's exact helper identity and is never part of normal stop,
    /// quit, or setting changes.
    public func recoverLegacySuspension() {
        for application in runningHelpers() {
            let processID = application.processIdentifier
            // Only resume a helper that is actually suspended. `pause()` is
            // careful never to claim one another utility already stopped; this
            // path has to be equally careful not to release one.
            guard let identity = Self.processIdentity(for: processID),
                  identity.status == UInt32(SSTOP) else { continue }
            _ = kill(processID, SIGCONT)
        }
    }

    public func setEnabled(_ enabled: Bool, requestInputAccess: Bool = false) {
        if enabled {
            guard !isEnabled else {
                if #available(macOS 26.5, *) {
                    _ = mediaKeyInterceptor.start(requestAccess: requestInputAccess)
                }
                if pausedProcessIDs.isEmpty { pauseHelper() }
                return
            }
            guard isCrashRecoveryAvailable else {
                Log.app.error("System OSD replacement unavailable: recovery helper is missing")
                isEnabled = false
                return
            }
            isEnabled = true
            if #available(macOS 26.5, *) {
                _ = mediaKeyInterceptor.start(requestAccess: requestInputAccess)
            }
            installLaunchObserver()
            pauseHelper()
        } else {
            // `mediaKeyInterceptor` is part of the condition because fail-open
            // can leave it running with everything else already cleared, and a
            // guard that ignored it made that state permanent.
            guard isEnabled || !pausedProcessIDs.isEmpty || !watchdogs.isEmpty
                    || mediaKeyInterceptor.isRunning else { return }
            isEnabled = false
            removeLaunchObserver()
            launchTask?.cancel()
            launchTask = nil
            mediaKeyInterceptor.stop()
            resumeAll()
        }
    }

    public func stop() {
        isEnabled = false
        removeLaunchObserver()
        launchTask?.cancel()
        launchTask = nil
        mediaKeyInterceptor.stop()
        resumeAll()
    }

    private func pauseHelper() {
        let running = runningHelpers()
        if running.isEmpty {
            launchThenPause()
            return
        }
        for application in running {
            pause(application.processIdentifier)
        }
    }

    private func launchThenPause() {
        guard launchTask == nil else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.hides = true

        launchTask = Task { [weak self] in
            defer { Task { @MainActor in self?.launchTask = nil } }
            do {
                let application = try await NSWorkspace.shared.openApplication(
                    at: Self.bundleURL,
                    configuration: configuration
                )
                guard let self, self.isEnabled else { return }
                self.pause(application.processIdentifier)
            } catch {
                Log.app.notice(
                    "Could not start the system overlay helper: \(error.localizedDescription)"
                )
            }
        }
    }

    private func pause(_ processID: pid_t) {
        guard processID > 1, !pausedProcessIDs.contains(processID) else { return }
        guard let application = NSRunningApplication(processIdentifier: processID),
              Self.isExpectedHelper(application) else {
            Log.app.error("Refusing to pause a process that is not Apple's OSD helper")
            return
        }
        guard let identity = Self.processIdentity(for: processID) else {
            Log.app.error("Refusing to pause an OSD helper whose process identity is unavailable")
            return
        }
        // SIGSTOP is idempotent. Claiming a helper another utility already
        // stopped would make our later SIGCONT violate that utility's lease.
        guard identity.status != UInt32(SSTOP) else {
            Log.app.notice("OSD helper is already stopped; leaving its existing owner untouched")
            return
        }
        guard let watchdog = armWatchdog(for: identity) else {
            Log.app.error("Refusing to pause system OSD without crash recovery")
            failOpen()
            return
        }
        watchdogs[processID] = watchdog

        guard kill(processID, SIGSTOP) == 0 else {
            Log.app.notice("Could not pause the system overlay (errno \(errno))")
            disarmWatchdog(for: processID)
            return
        }
        guard let stopped = NSRunningApplication(processIdentifier: processID),
              Self.isExpectedHelper(stopped),
              Self.processIdentity(for: processID).map({ current in
                  current.processID == identity.processID
                      && current.startSeconds == identity.startSeconds
                      && current.startMicroseconds == identity.startMicroseconds
              }) == true else {
            // We issued the stop, so if identity changed in the narrow signal
            // race, immediately undo our own action rather than abandoning an
            // unrelated process in a suspended state.
            _ = kill(processID, SIGCONT)
            disarmWatchdog(for: processID)
            return
        }
        pausedProcessIDs.insert(processID)
    }

    private func resumeAll() {
        for processID in pausedProcessIDs {
            if let application = NSRunningApplication(processIdentifier: processID),
               Self.isExpectedHelper(application) {
                _ = kill(processID, SIGCONT)
            }
        }
        pausedProcessIDs.removeAll()

        // Remove ownership before closing leases so expected helper exits do
        // not look like watchdog failures.
        let armed = watchdogs
        watchdogs.removeAll()
        for watchdog in armed.values {
            watchdog.process.terminationHandler = nil
            try? watchdog.lease.fileHandleForWriting.close()
        }
    }

    private var recoveryExecutableURL: URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(Self.recoveryExecutableName)
        guard FileManager.default.isExecutableFile(atPath: url.path),
              Self.hasMatchingValidSignature(helperURL: url) else {
            Log.app.error("OSD recovery helper is missing or has an invalid signature")
            return nil
        }
        return url
    }

    nonisolated private static func hasMatchingValidSignature(
        helperURL: URL
    ) -> Bool {
        guard let appCode = staticCode(at: Bundle.main.bundleURL),
              let helperCode = staticCode(at: helperURL) else { return false }

        let strict = SecCSFlags(rawValue:
            kSecCSCheckAllArchitectures | kSecCSStrictValidate
        )
        let appFlags = SecCSFlags(rawValue:
            strict.rawValue | kSecCSCheckNestedCode
        )
        guard SecStaticCodeCheckValidity(appCode, appFlags, nil) == errSecSuccess,
              SecStaticCodeCheckValidity(helperCode, strict, nil) == errSecSuccess else {
            return false
        }
        // Apple Development / Developer ID builds must share a Team ID. Ad-hoc
        // local builds have nil for both and are still internally consistent.
        return signingTeam(for: appCode) == signingTeam(for: helperCode)
    }

    nonisolated private static func staticCode(at url: URL) -> SecStaticCode? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            url as CFURL,
            SecCSFlags(),
            &code
        ) == errSecSuccess else { return nil }
        return code
    }

    nonisolated private static func signingTeam(
        for code: SecStaticCode
    ) -> String? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
            let dictionary = information as? [String: Any]
        else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private func armWatchdog(for identity: ProcessIdentity) -> Watchdog? {
        guard let executableURL = recoveryExecutableURL else { return nil }
        let processID = identity.processID
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            String(processID),
            String(identity.startSeconds),
            String(identity.startMicroseconds),
        ]
        let lease = Pipe()
        process.standardInput = lease
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let token = UUID()
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.watchdogExited(for: processID, token: token)
            }
        }
        do {
            try process.run()
        } catch {
            Log.app.error("Could not arm OSD recovery watchdog: \(error.localizedDescription)")
            return nil
        }

        // `Process.run()` returns as soon as the child has been spawned, but
        // the kernel's dynamic-code registry and proc path can lag that return
        // by a few scheduling quanta. Validate for a tightly bounded 200 ms
        // window instead of spuriously failing open on a healthy signed child.
        var isValidatedChild = false
        for _ in 0..<20 where process.isRunning {
            if Self.isExpectedRecoveryProcess(
                processID: process.processIdentifier,
                executableURL: executableURL
            ) {
                isValidatedChild = true
                break
            }
            usleep(10_000)
        }
        guard process.isRunning, isValidatedChild else {
            try? lease.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            Log.app.error("OSD recovery watchdog failed live code-signature validation")
            return nil
        }
        let watchdog = Watchdog(token: token, process: process, lease: lease)
        return watchdog
    }

    nonisolated private static func isExpectedRecoveryProcess(
        processID: pid_t,
        executableURL: URL
    ) -> Bool {
        var pathBuffer = [CChar](repeating: 0, count: Int(PROC_PIDPATHINFO_SIZE))
        let pathLength = proc_pidpath(
            processID,
            &pathBuffer,
            UInt32(pathBuffer.count)
        )
        guard pathLength > 0 else { return false }
        let path = String(
            decoding: pathBuffer.prefix(Int(pathLength)).map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        guard URL(fileURLWithPath: path).standardizedFileURL.path
                == executableURL.standardizedFileURL.path else { return false }

        var dynamicCode: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: processID)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            SecCSFlags(),
            &dynamicCode
        ) == errSecSuccess,
            let dynamicCode
        else { return false }
        // `kSecCSCheckAllArchitectures` is valid for `SecStaticCode` but
        // Security.framework rejects it for a live `SecCode` with
        // errSecCSInvalidFlags. Strictly validate the running architecture;
        // the enclosing bundle's all-architecture check already ran before
        // this child was spawned.
        let strict = SecCSFlags(rawValue: kSecCSStrictValidate)
        guard SecCodeCheckValidity(dynamicCode, strict, nil) == errSecSuccess else { return false }

        var childStaticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(dynamicCode, SecCSFlags(), &childStaticCode) == errSecSuccess,
              let childStaticCode,
              let appCode = staticCode(at: Bundle.main.bundleURL) else { return false }
        return signingTeam(for: childStaticCode) == signingTeam(for: appCode)
    }

    nonisolated private static func processIdentity(for processID: pid_t) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(
            processID,
            PROC_PIDTBSDINFO,
            0,
            &info,
            expectedSize
        ) == expectedSize else { return nil }
        return ProcessIdentity(
            processID: processID,
            startSeconds: UInt64(info.pbi_start_tvsec),
            startMicroseconds: UInt64(info.pbi_start_tvusec),
            status: info.pbi_status
        )
    }

    private func disarmWatchdog(for processID: pid_t) {
        guard let watchdog = watchdogs.removeValue(forKey: processID) else { return }
        watchdog.process.terminationHandler = nil
        try? watchdog.lease.fileHandleForWriting.close()
    }

    private func watchdogExited(for processID: pid_t, token: UUID) {
        guard watchdogs[processID]?.token == token else { return }
        watchdogs.removeValue(forKey: processID)
        Log.app.error("OSD recovery watchdog exited unexpectedly; restoring native OSD")
        failOpen()
    }

    private func failOpen() {
        isEnabled = false
        removeLaunchObserver()
        launchTask?.cancel()
        launchTask = nil
        // Failing open has to give the *whole* native path back. Leaving the
        // tap installed kept swallowing the five hardware keys after the notch
        // had stopped drawing their replacement, and the early return in
        // `setEnabled(false)` then had nothing left to notice, so it survived
        // until quit.
        mediaKeyInterceptor.stop()
        resumeAll()
    }

    private func runningHelpers() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.bundleIdentifier
        ).filter(Self.isExpectedHelper)
    }

    nonisolated private static func isExpectedHelper(
        _ application: NSRunningApplication
    ) -> Bool {
        application.bundleIdentifier == Self.bundleIdentifier
            && application.executableURL?.standardizedFileURL.path == Self.executablePath
    }

    private func installLaunchObserver() {
        guard observers.isEmpty else { return }
        observers.append(observe(
            NSWorkspace.didLaunchApplicationNotification
        ) { [weak self] processID in
            guard let self, self.isEnabled else { return }
            self.pause(processID)
        })
        observers.append(observe(
            NSWorkspace.didTerminateApplicationNotification
        ) { [weak self] processID in
            guard let self else { return }
            self.pausedProcessIDs.remove(processID)
            self.disarmWatchdog(for: processID)
        })
    }

    private func observe(
        _ name: Notification.Name,
        handler: @escaping @MainActor (pid_t) -> Void
    ) -> NSObjectProtocol {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { notification in
            guard let application = notification.userInfo?[
                NSWorkspace.applicationUserInfoKey
            ] as? NSRunningApplication,
                Self.isExpectedHelper(application)
            else { return }
            let processID = application.processIdentifier
            MainActor.assumeIsolated { handler(processID) }
        }
    }

    private func removeLaunchObserver() {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }
}
