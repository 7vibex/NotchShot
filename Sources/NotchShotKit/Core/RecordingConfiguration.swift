import AVFoundation
import CoreGraphics
import Foundation

public enum RecordingTarget: Sendable, Equatable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    /// Global (top-left origin) rect on the given display.
    case area(CGRect, CGDirectDisplayID)

    public var displayID: CGDirectDisplayID? {
        switch self {
        case .display(let id): id
        case .area(_, let id): id
        case .window: nil
        }
    }
}

/// The user-facing scope used before ScreenCaptureKit resolves a concrete
/// display/window identifier or an area rectangle.
public enum RecordingTargetMode: String, Sendable, Codable, CaseIterable, Identifiable {
    case area
    case window
    case display

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .area: "Area"
        case .window: "Window"
        case .display: "Display"
        }
    }

    public var symbolName: String {
        switch self {
        case .area: "viewfinder"
        case .window: "macwindow"
        case .display: "display"
        }
    }
}

public struct RecordingAudioSources: OptionSet, Sendable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let system = RecordingAudioSources(rawValue: 1 << 0)
    public static let microphone = RecordingAudioSources(rawValue: 1 << 1)

    public var isEmpty: Bool { rawValue == 0 }
}

// `RecordingQuality` was removed deliberately, not mislaid.
//
// It set a bitrate, and this recorder writes through
// `SCRecordingOutputConfiguration`, whose entire surface is `outputURL`,
// `videoCodecType`, and `outputFileType` — there is no bitrate to set. The
// picker had no production caller and changed nothing about the MP4, so it
// promised the user control the backend cannot give. Resolution and frame rate
// are the real size controls and both still apply.

/// Longest edge the recording is downscaled to. `native` keeps source pixels.
public enum RecordingResolution: String, Sendable, Codable, CaseIterable, Identifiable {
    case native
    case p2160
    case p1440
    case p1080
    case p720

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .native: "Native"
        case .p2160: "2160p"
        case .p1440: "1440p"
        case .p1080: "1080p"
        case .p720: "720p"
        }
    }

    /// Target height in pixels, or nil for native.
    public var targetHeight: Int? {
        switch self {
        case .native: nil
        case .p2160: 2160
        case .p1440: 1440
        case .p1080: 1080
        case .p720: 720
        }
    }
}

public struct RecordingConfiguration: Sendable, Equatable {
    public var target: RecordingTarget
    public var audioSources: RecordingAudioSources
    public var microphoneDeviceID: String?
    public var resolution: RecordingResolution
    public var framesPerSecond: Int
    public var showsCursor: Bool
    public var highlightsClicks: Bool
    public var autoZoomsOnClicks: Bool
    public var framesWithBackground: Bool

    public init(
        target: RecordingTarget,
        audioSources: RecordingAudioSources = .system,
        microphoneDeviceID: String? = nil,
        resolution: RecordingResolution = .native,
        framesPerSecond: Int = 60,
        showsCursor: Bool = true,
        highlightsClicks: Bool = false,
        autoZoomsOnClicks: Bool = false,
        framesWithBackground: Bool = false
    ) {
        self.target = target
        self.audioSources = audioSources
        self.microphoneDeviceID = microphoneDeviceID
        self.resolution = resolution
        self.framesPerSecond = Self.sanitizedFramesPerSecond(framesPerSecond)
        self.showsCursor = showsCursor
        self.highlightsClicks = highlightsClicks
        self.autoZoomsOnClicks = autoZoomsOnClicks
        self.framesWithBackground = framesWithBackground
    }

    /// Scales `sourcePixelSize` down to the configured resolution, preserving
    /// aspect ratio and keeping both dimensions even (H.264 requirement).
    public func outputPixelSize(for sourcePixelSize: CGSize) -> CGSize {
        guard sourcePixelSize.width.isFinite,
              sourcePixelSize.height.isFinite,
              sourcePixelSize.width > 0,
              sourcePixelSize.height > 0 else {
            return CGSize(width: 2, height: 2)
        }
        let maximumDimension: CGFloat = 32_768
        var size = CGSize(
            width: min(sourcePixelSize.width, maximumDimension),
            height: min(sourcePixelSize.height, maximumDimension)
        )
        if let targetHeight = resolution.targetHeight, sourcePixelSize.height > CGFloat(targetHeight) {
            let factor = CGFloat(targetHeight) / size.height
            size = CGSize(width: size.width * factor, height: CGFloat(targetHeight))
        }
        return CGSize(width: evenValue(size.width), height: evenValue(size.height))
    }

    public static func sanitizedFramesPerSecond(_ value: Int) -> Int {
        switch value {
        case 30, 60: value
        default: 60
        }
    }

    /// Insets and aspect-fits the captured pixels into a restrained matte.
    /// The canvas dimensions stay unchanged, so enabling framing never exceeds
    /// the selected resolution or bitrate cap.
    public func destinationRect(
        for sourcePixelSize: CGSize,
        outputPixelSize: CGSize
    ) -> CGRect {
        let canvas = CGRect(origin: .zero, size: outputPixelSize)
        guard framesWithBackground,
              sourcePixelSize.width > 0, sourcePixelSize.height > 0 else {
            return canvas
        }

        let inset = max(16, min(outputPixelSize.width, outputPixelSize.height) * 0.055)
        let available = canvas.insetBy(dx: inset, dy: inset)
        let scale = min(
            available.width / sourcePixelSize.width,
            available.height / sourcePixelSize.height
        )
        let fitted = CGSize(
            width: sourcePixelSize.width * scale,
            height: sourcePixelSize.height * scale
        )
        return CGRect(
            x: (outputPixelSize.width - fitted.width) / 2,
            y: (outputPixelSize.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        ).integral
    }

    private func evenValue(_ value: CGFloat) -> CGFloat {
        let rounded = max(2, (value / 2).rounded() * 2)
        return rounded
    }
}

/// Live state published while a recording runs.
public struct RecordingStatus: Sendable, Equatable {
    public static let waveformSampleCount = 18

    public var elapsed: TimeInterval = 0
    /// 0…1 normalised power for the system-audio tap.
    public var systemLevel: Float = 0
    /// 0…1 normalised power for the microphone tap.
    public var microphoneLevel: Float = 0
    /// Recent real meter samples, oldest first. The UI renders these directly
    /// instead of inventing a decorative oscillation from one scalar value.
    public var systemWaveform = Array(repeating: Float.zero, count: waveformSampleCount)
    public var microphoneWaveform = Array(repeating: Float.zero, count: waveformSampleCount)
    public var isMicrophoneEnabled = false
    public var isSystemAudioEnabled = false
    /// A source can be captured into the MP4 even when its optional visual
    /// meter tap could not be registered or does not support the native PCM
    /// sample format. Keep those states distinct so a flat line never lies.
    public var isMicrophoneMeterAvailable = false
    public var isSystemMeterAvailable = false
    public var fileSizeBytes: Int64 = 0

    public init() {}

    public var elapsedDescription: String {
        let total = Int(elapsed)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }

    mutating func appendMeterSnapshot(system: Float, microphone: Float) {
        systemLevel = isSystemAudioEnabled ? Self.clampLevel(system) : 0
        microphoneLevel = isMicrophoneEnabled ? Self.clampLevel(microphone) : 0
        Self.append(systemLevel, to: &systemWaveform)
        Self.append(microphoneLevel, to: &microphoneWaveform)
    }

    private static func append(_ level: Float, to waveform: inout [Float]) {
        if waveform.count >= waveformSampleCount {
            waveform.removeFirst(waveform.count - waveformSampleCount + 1)
        }
        waveform.append(level)
        if waveform.count < waveformSampleCount {
            waveform.insert(
                contentsOf: repeatElement(0, count: waveformSampleCount - waveform.count),
                at: 0
            )
        }
    }

    private static func clampLevel(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
