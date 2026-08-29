import Foundation
import OSLog

public enum Log {
    private static let subsystem = "com.notchshot.app"

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let window = Logger(subsystem: subsystem, category: "window")
    public static let capture = Logger(subsystem: subsystem, category: "capture")
    public static let recording = Logger(subsystem: subsystem, category: "recording")
    public static let media = Logger(subsystem: subsystem, category: "media")
    public static let history = Logger(subsystem: subsystem, category: "history")
    public static let annotation = Logger(subsystem: subsystem, category: "annotation")
    public static let permissions = Logger(subsystem: subsystem, category: "permissions")
    public static let ocr = Logger(subsystem: subsystem, category: "ocr")
}

public enum NotchShotError: LocalizedError, Equatable {
    case screenRecordingPermissionDenied
    /// Asked, prompt shown, grant not yet in effect for this process.
    case screenRecordingPermissionPending
    /// Approved in an earlier launch, but the stored grant belongs to a
    /// different signing identity, so macOS keeps refusing this build.
    case screenRecordingGrantStale
    /// The running bundle carries an ad-hoc signature, so its identity is its
    /// own code hash and no TCC grant can outlive a rebuild.
    case unstableSigningIdentity
    case microphonePermissionDenied
    case noShareableContent
    case displayNotFound
    case windowNotFound
    case captureFailed(String)
    case recordingFailed(String)
    case exportFailed(String)
    case stitchFailed(String)
    case cancelled
    case diskSpaceUnavailable
    case destinationUnwritable(String)

    public var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionDenied:
            "NotchShot needs Screen & System Audio Recording permission."
        case .screenRecordingPermissionPending:
            "Allow NotchShot in Screen & System Audio Recording, then quit and reopen it."
        case .screenRecordingGrantStale:
            "macOS is still refusing Screen Recording even though NotchShot looks approved. Reset the permission in Settings › Privacy."
        case .unstableSigningIdentity:
            "This build of NotchShot is ad-hoc signed, so macOS treats every rebuild as a different app and drops the permissions you granted. Rebuild it with a code-signing certificate."
        case .microphonePermissionDenied:
            "NotchShot needs Microphone permission to record your voice."
        case .noShareableContent:
            "The macOS capture service returned no displays. Wake every display; if they are already awake, log out or restart the Mac, then reopen NotchShot."
        case .displayNotFound:
            "That display is no longer connected."
        case .windowNotFound:
            "That window is no longer available."
        case .captureFailed(let reason):
            "Capture failed: \(reason)"
        case .recordingFailed(let reason):
            "Recording failed: \(reason)"
        case .exportFailed(let reason):
            "Export failed: \(reason)"
        case .stitchFailed(let reason):
            "Could not stitch the scrolling capture: \(reason)"
        case .cancelled:
            "Cancelled."
        case .diskSpaceUnavailable:
            "Not enough free disk space to finish this capture."
        case .destinationUnwritable(let path):
            "Can't write to \(path)."
        }
    }

    /// Short text suited to the notch's error banner.
    public var notchMessage: String {
        switch self {
        case .screenRecordingPermissionDenied: "Screen Recording denied"
        case .screenRecordingPermissionPending: "Allow Screen Recording, then reopen NotchShot"
        case .screenRecordingGrantStale: "Screen Recording needs resetting — open Settings › Privacy"
        case .unstableSigningIdentity: "This build is ad-hoc signed — permissions cannot stick"
        case .microphonePermissionDenied: "Microphone denied"
        case .noShareableContent: "macOS capture service is unavailable — log out or restart"
        case .cancelled: "Cancelled"
        case .diskSpaceUnavailable: "Disk full"
        default: errorDescription ?? "Something went wrong"
        }
    }
}
