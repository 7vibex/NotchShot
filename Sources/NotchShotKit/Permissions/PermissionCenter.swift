import AVFoundation
import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import Observation
import Security

public enum PermissionKind: String, Sendable, CaseIterable, Identifiable {
    case screenRecording
    case microphone
    case automation
    case inputMonitoring
    case accessibility

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .screenRecording: "Screen & System Audio Recording"
        case .microphone: "Microphone"
        case .automation: "Automation (Music & Spotify)"
        case .inputMonitoring: "Input Monitoring"
        case .accessibility: "Accessibility"
        }
    }

    public var rationale: String {
        switch self {
        case .screenRecording: "Required for every screenshot and recording."
        case .microphone: "Only used when you record your voice."
        case .automation: "Only used if the system Now Playing bridge is unavailable."
        case .inputMonitoring: "Only used when you choose to replace the macOS volume and brightness overlay or show keyboard shortcuts in a recording."
        case .accessibility: "Used only for features you enable: automatic scrolling capture, inserting dictation into another app, mirroring visible notification banners, and—on some macOS builds—replacing media-key overlays."
        }
    }

    /// Deep link into the exact System Settings pane.
    public var settingsURL: URL? {
        switch self {
        case .screenRecording:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        case .microphone:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .automation:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        case .inputMonitoring:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        case .accessibility:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
    }
}

public enum PermissionState: String, Sendable, Equatable {
    case granted
    /// The request was handed to macOS, but the current process does not yet
    /// pass the preflight check. A relaunch may be needed for the grant to land.
    case restartRequired
    case denied
    case notDetermined

    public var isUsable: Bool { self == .granted }

    public var displayName: String {
        switch self {
        case .granted: "Granted"
        case .restartRequired: "Relaunch required"
        case .denied: "Denied"
        case .notDetermined: "Not requested"
        }
    }
}

/// Requests permissions lazily — at the moment the feature needs them, never at
/// launch — and reports exactly what to do when one is denied.
@MainActor
@Observable
public final class PermissionCenter {
    public static let shared = PermissionCenter()

    public private(set) var screenRecording: PermissionState = .notDetermined
    public private(set) var microphone: PermissionState = .notDetermined
    public private(set) var inputMonitoringGranted = false
    public var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Set when a permission was denied, so the UI can offer remediation.
    public var pendingRemediation: PermissionKind?

    /// True when Screen Recording was approved in an earlier launch but macOS
    /// still refuses this build — a Privacy entry belonging to a different
    /// signing identity. Toggling the switch will not fix it; the record has to
    /// be reset.
    public private(set) var isScreenRecordingGrantStale = false

    /// True when this bundle carries an ad-hoc signature.
    ///
    /// Worth reporting on its own, because it explains a symptom that otherwise
    /// looks like two unrelated bugs. macOS keys a TCC grant to the app's
    /// designated requirement; under an ad-hoc signature that requirement *is*
    /// the code hash, so every rebuild is a different app to TCC. The Privacy
    /// pane keeps showing NotchShot switched on — that row belongs to the
    /// build that asked — while `CGPreflightScreenCaptureAccess` and
    /// `CGPreflightListenEventAccess` both answer false for the build actually
    /// running. Capture fails, the media-key tap never installs, and the macOS
    /// volume and brightness overlay reappears with nothing replacing it.
    /// Toggling the switch cannot fix any of that; only a stable signature can.
    public let hasUnstableSigningIdentity = PermissionCenter.isAdHocSigned()

    /// Reads the running code's signature rather than the bundle on disk, so it
    /// describes the process whose permissions are actually being refused.
    nonisolated static func isAdHocSigned() -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess,
              let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
            let dictionary = information as? [String: Any]
        else { return false }
        // `kSecCodeSignatureAdhoc` is the authoritative bit. A missing Team ID
        // agrees with it in practice but is not decisive on its own, so it is
        // only the fallback for a build whose flags could not be read.
        if let flags = dictionary[kSecCodeInfoFlags as String] as? UInt32 {
            return flags & SecCodeSignatureFlags.adhoc.rawValue != 0
        }
        return dictionary[kSecCodeInfoTeamIdentifier as String] == nil
    }

    private var screenRecordingPoll: Timer?
    private var requestedScreenRecordingThisLaunch = false

    /// The two TCC calls, injectable so tests can drive both branches. A test
    /// process has its own Screen Recording status — usually the terminal's —
    /// which has nothing to do with the app's, so calling the real API in a test
    /// would assert against whatever the machine happens to be set to.
    private let preflight: () -> Bool
    private let request: () -> Bool
    private let inputMonitoringPreflight: () -> Bool

    public init(
        preflight: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
        request: @escaping () -> Bool = { CGRequestScreenCaptureAccess() },
        inputMonitoringPreflight: @escaping () -> Bool = { CGPreflightListenEventAccess() }
    ) {
        self.preflight = preflight
        self.request = request
        self.inputMonitoringPreflight = inputMonitoringPreflight
        refresh()
    }

    public func refresh() {
        if preflight() {
            markScreenRecordingGranted()
        } else {
            screenRecording = screenRecordingFallbackState()
        }
        microphone = Self.state(for: AVCaptureDevice.authorizationStatus(for: .audio))
        inputMonitoringGranted = inputMonitoringPreflight()
    }

    private func screenRecordingFallbackState() -> PermissionState {
        // CGPreflight can't distinguish "never asked" from "refused", so use
        // the permission request itself as evidence. The old first-run flag
        // incorrectly labelled access denied merely because Settings had been
        // opened once.
        hasRequestedScreenRecording ? .denied : .notDetermined
    }

    // MARK: Screen recording

    @discardableResult
    public func requestScreenRecordingAccess() -> Bool {
        if preflight() {
            markScreenRecordingGranted()
            return true
        }

        // Asking again in the same launch cannot produce a second prompt, so
        // report the denial and let the UI offer remediation.
        //
        // A *previous* launch having asked is deliberately not a reason to skip
        // the request. It used to be, and that was a dead end: once the flag was
        // stored, every later attempt reported denied without ever asking macOS
        // again, so an approval that did not land — a stale Privacy entry from a
        // build signed with a different identity is the usual cause — could
        // never be recovered from inside the app. `CGRequestScreenCaptureAccess`
        // is safe to repeat: it prompts when TCC holds no decision for this
        // identity, and returns false without a prompt when it holds a refusal.
        if requestedScreenRecordingThisLaunch {
            screenRecording = .denied
            pendingRemediation = .screenRecording
            startPollingScreenRecording()
            return false
        }

        // `CGRequestScreenCaptureAccess` returns *immediately* with the
        // current (still-false) state while the system prompt is on screen —
        // it does not wait for the user. Treating its `false` as a refusal is
        // why the first capture used to fail with "denied" the moment the
        // prompt appeared.
        let hadAskedBefore = hasRequestedScreenRecording
        requestedScreenRecordingThisLaunch = true
        hasRequestedScreenRecording = true
        _ = request()

        // The preflight API answers for this process. If macOS has already
        // applied the grant, blocking capture behind a relaunch prompt is a
        // false denial even when this launch initiated the request.
        if preflight() {
            markScreenRecordingGranted()
            return true
        }

        // The request has been handed to macOS, but this process still lacks
        // access. Keep the relaunch path available while the poll watches for an
        // immediately effective grant.
        screenRecording = .restartRequired
        pendingRemediation = .screenRecording
        // Whether this is a stale grant cannot be decided here: the request API
        // returns false both while its prompt is on screen and when TCC already
        // holds a refusal. The poll settles it — a real prompt is answered in
        // seconds, a mismatched record never resolves at all.
        startPollingScreenRecording(reportsStaleGrant: hadAskedBefore)
        return false
    }

    /// Clears this app's Screen Recording decision so macOS prompts fresh.
    ///
    /// The recovery path for a Privacy entry left behind by a build signed with
    /// a different identity: the switch in Settings looks enabled but no longer
    /// matches, and only removing the record fixes it. Scoped to this bundle
    /// identifier — no other app's permissions are touched.
    @discardableResult
    public func resetScreenRecordingPermission() async -> Bool {
        let identifier = Bundle.main.bundleIdentifier ?? "com.notchshot.app"
        // `tccutil` is a subprocess with no bounded runtime, so waiting for it
        // on the main actor froze the whole UI — including the window holding
        // the button that started it.
        let status: Int32? = await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", "ScreenCapture", identifier]
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                Log.permissions.error("Could not reset Screen Recording: \(error.localizedDescription)")
                return nil
            }
            return process.terminationStatus
        }.value
        guard status == 0 else {
            if let status {
                Log.permissions.error("tccutil exited with \(status)")
            }
            return false
        }
        // Start over cleanly: the next capture asks macOS again.
        hasRequestedScreenRecording = false
        requestedScreenRecordingThisLaunch = false
        isScreenRecordingGrantStale = false
        screenRecording = .notDetermined
        pendingRemediation = nil
        return true
    }

    /// True the first time a capture is attempted, when the system prompt is
    /// probably still on screen and a restart will be needed.
    public var requiresScreenRecordingRelaunch: Bool {
        screenRecording == .restartRequired
    }

    private var hasRequestedScreenRecording: Bool {
        get { UserDefaults.standard.bool(forKey: "notchshot.askedScreenRecording") }
        set { UserDefaults.standard.set(newValue, forKey: "notchshot.askedScreenRecording") }
    }

    /// macOS does not notify us when the toggle flips, and the grant only takes
    /// effect for new capture attempts, so a short poll keeps the UI honest.
    private func startPollingScreenRecording(reportsStaleGrant: Bool = false) {
        screenRecordingPoll?.invalidate()
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(120)
        // Long enough that a prompt the user is actually answering has had its
        // chance, short enough to explain the problem while they are still
        // looking at it.
        let staleAfter = startedAt.addingTimeInterval(15)
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.preflight() {
                    self.markScreenRecordingGranted()
                } else {
                    // Approved once before, asked again, and still refused after
                    // the grace period: the stored record does not match this
                    // build and no amount of toggling will change that.
                    if reportsStaleGrant, Date() > staleAfter {
                        self.isScreenRecordingGrantStale = true
                    }
                    if Date() > deadline { self.stopPollingScreenRecording() }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        screenRecordingPoll = timer
    }

    private func stopPollingScreenRecording() {
        screenRecordingPoll?.invalidate()
        screenRecordingPoll = nil
    }

    /// A successful preflight is authoritative for the running process. Clear
    /// stale remediation at the same time so every observer sees one coherent
    /// state instead of a green status beside an obsolete permission prompt.
    private func markScreenRecordingGranted() {
        requestedScreenRecordingThisLaunch = false
        isScreenRecordingGrantStale = false
        screenRecording = .granted
        if pendingRemediation == .screenRecording {
            pendingRemediation = nil
        }
        stopPollingScreenRecording()
    }

    // MARK: Microphone

    public func requestMicrophoneAccess() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            microphone = .granted
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            microphone = granted ? .granted : .denied
            if !granted { pendingRemediation = .microphone }
            return granted
        default:
            microphone = .denied
            pendingRemediation = .microphone
            return false
        }
    }

    public func availableMicrophones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    // MARK: Remediation

    public func openSettings(for kind: PermissionKind) {
        guard let url = kind.settingsURL else { return }
        NSWorkspace.shared.open(url)
        if kind == .screenRecording { startPollingScreenRecording() }
    }

    /// Quits this instance and reopens the bundle once it is gone. This is the
    /// shortest reliable route from granting Screen Recording to a working
    /// capture, and avoids telling the user to hunt for a menu-bar process.
    ///
    /// It deliberately does *not* ask Launch Services for a second instance.
    /// `LSMultipleInstancesProhibited` makes that request succeed while
    /// returning the process that is already running, so the old spelling read
    /// the no-error result as "the replacement is up", terminated, and left the
    /// user with nothing running and no Dock icon to notice it by. Ordering the
    /// two halves through a detached waiter is what makes the promise true.
    public func relaunchApplication() {
        guard let executableURL = Bundle.main.executableURL else {
            Log.permissions.error("Relaunch failed: the running executable could not be located")
            screenRecording = .restartRequired
            return
        }
        let waiter = Process()
        waiter.executableURL = executableURL
        waiter.arguments = [
            "--relaunch-after",
            String(ProcessInfo.processInfo.processIdentifier),
            Bundle.main.bundleURL.standardizedFileURL.path,
        ]
        waiter.standardInput = FileHandle.nullDevice
        waiter.standardOutput = FileHandle.nullDevice
        waiter.standardError = FileHandle.nullDevice
        do {
            try waiter.run()
        } catch {
            // Never terminate on a relaunch that was never armed.
            Log.permissions.error("Relaunch failed: \(error.localizedDescription)")
            screenRecording = .restartRequired
            return
        }
        NSApp.terminate(nil)
    }

    public func dismissRemediation() {
        pendingRemediation = nil
    }

    private static func state(for status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }
}
