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
        case .microphonePermissionDenied:
            "NotchShot needs Microphone permission to record your voice."
        case .noShareableContent:
            "No capturable content is available right now."
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
        case .microphonePermissionDenied: "Microphone denied"
        case .cancelled: "Cancelled"
        case .diskSpaceUnavailable: "Disk full"
        default: errorDescription ?? "Something went wrong"
        }
    }
}
