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
    case denied
    case notDetermined

    public var isUsable: Bool { self == .granted }
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

    private var screenRecordingPoll: Timer?

    public init() {
        refresh()
    }

    public func refresh() {
        screenRecording = CGPreflightScreenCaptureAccess() ? .granted : screenRecordingFallbackState()
        microphone = Self.state(for: AVCaptureDevice.authorizationStatus(for: .audio))
    }

    private func screenRecordingFallbackState() -> PermissionState {
        // CGPreflight can't distinguish "never asked" from "refused", so the
        // first-run flag stands in: if we've asked once, a false means denied.
        Preferences.shared.hasCompletedFirstRun ? .denied : .notDetermined
    }

    // MARK: Screen recording

    @discardableResult
    public func requestScreenRecordingAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            screenRecording = .granted
            return true
        }

        // `CGRequestScreenCaptureAccess` returns *immediately* with the
        // current (still-false) state while the system prompt is on screen —
        // it does not wait for the user. Treating its `false` as a refusal is
        // why the first capture used to fail with "denied" the moment the
        // prompt appeared.
        let granted = CGRequestScreenCaptureAccess()
        if granted {
            screenRecording = .granted
            return true
        }

        // So: remember that we asked, poll for the grant, and report a state
        // the UI can explain rather than a flat denial.
        let hasAskedBefore = hasRequestedScreenRecording
        hasRequestedScreenRecording = true
        screenRecording = hasAskedBefore ? .denied : .notDetermined
        pendingRemediation = .screenRecording
        startPollingScreenRecording()
        return false
    }

    /// True the first time a capture is attempted, when the system prompt is
    /// probably still on screen and a restart will be needed.
    public var isAwaitingFirstScreenRecordingGrant: Bool {
        screenRecording != .granted && hasRequestedScreenRecording
    }

    private var hasRequestedScreenRecording: Bool {
        get { UserDefaults.standard.bool(forKey: "notchshot.askedScreenRecording") }
        set { UserDefaults.standard.set(newValue, forKey: "notchshot.askedScreenRecording") }
    }

    /// macOS does not notify us when the toggle flips, and the grant only takes
    /// effect for new capture attempts, so a short poll keeps the UI honest.
    private func startPollingScreenRecording() {
        screenRecordingPoll?.invalidate()
        let deadline = Date().addingTimeInterval(120)
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if CGPreflightScreenCaptureAccess() {
                    self.screenRecording = .granted
                    if self.pendingRemediation == .screenRecording { self.pendingRemediation = nil }
                    self.stopPollingScreenRecording()
                } else if Date() > deadline {
                    self.stopPollingScreenRecording()
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
