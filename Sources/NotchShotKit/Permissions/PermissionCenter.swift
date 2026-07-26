import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import Observation

public enum PermissionKind: String, Sendable, CaseIterable, Identifiable {
    case screenRecording
    case microphone
    case automation
    case accessibility

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .screenRecording: "Screen & System Audio Recording"
        case .microphone: "Microphone"
        case .automation: "Automation (Music & Spotify)"
        case .accessibility: "Accessibility"
        }
    }

    public var rationale: String {
        switch self {
        case .screenRecording: "Required for every screenshot and recording."
        case .microphone: "Only used when you record your voice."
        case .automation: "Only used if the system Now Playing bridge is unavailable."
        case .accessibility: "Not used in this version."
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
        case .accessibility:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
    }
}

public enum PermissionState: String, Sendable, Equatable {
    case granted
    /// The user may have enabled access, but ScreenCaptureKit only picks up a
    /// new grant in a freshly launched process.
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

    /// Set when a permission was denied, so the UI can offer remediation.
    public var pendingRemediation: PermissionKind?

    /// True when Screen Recording was approved in an earlier launch but macOS
    /// still refuses this build — a Privacy entry belonging to a different
    /// signing identity. Toggling the switch will not fix it; the record has to
    /// be reset.
    public private(set) var isScreenRecordingGrantStale = false

    private var screenRecordingPoll: Timer?
    private var requestedScreenRecordingThisLaunch = false

    /// The two TCC calls, injectable so tests can drive both branches. A test
    /// process has its own Screen Recording status — usually the terminal's —
    /// which has nothing to do with the app's, so calling the real API in a test
    /// would assert against whatever the machine happens to be set to.
    private let preflight: () -> Bool
    private let request: () -> Bool

    public init(
        preflight: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
        request: @escaping () -> Bool = { CGRequestScreenCaptureAccess() }
    ) {
        self.preflight = preflight
        self.request = request
        refresh()
    }

    public func refresh() {
        if preflight() {
            // macOS honours the grant again, so whatever was stale no longer is.
            isScreenRecordingGrantStale = false
            screenRecording = requestedScreenRecordingThisLaunch ? .restartRequired : .granted
        } else {
            screenRecording = screenRecordingFallbackState()
        }
        microphone = Self.state(for: AVCaptureDevice.authorizationStatus(for: .audio))
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
            if requestedScreenRecordingThisLaunch {
                screenRecording = .restartRequired
                pendingRemediation = .screenRecording
                return false
            }
            screenRecording = .granted
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

        // Whether or not the call reported the new toggle, ScreenCaptureKit only
        // honours a fresh grant in a newly launched process.
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
    public func resetScreenRecordingPermission() -> Bool {
        let identifier = Bundle.main.bundleIdentifier ?? "com.notchshot.app"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "ScreenCapture", identifier]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Log.permissions.error("Could not reset Screen Recording: \(error.localizedDescription)")
            return false
        }
        guard process.terminationStatus == 0 else {
            Log.permissions.error("tccutil exited with \(process.terminationStatus)")
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
                    // Do not mark the current process usable. ScreenCaptureKit
                    // begins working only after the user relaunches the app.
                    self.isScreenRecordingGrantStale = false
                    self.screenRecording = self.requestedScreenRecordingThisLaunch
                        ? .restartRequired : .granted
                    self.stopPollingScreenRecording()
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

    /// Starts a fresh app instance, then terminates this one. This is the
    /// shortest reliable route from granting Screen Recording to a working
    /// capture, and avoids telling the user to hunt for a menu-bar process.
    public func relaunchApplication() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, error in
            Task { @MainActor in
                if let error {
                    Log.permissions.error("Relaunch failed: \(error.localizedDescription)")
                    self.screenRecording = .restartRequired
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
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
