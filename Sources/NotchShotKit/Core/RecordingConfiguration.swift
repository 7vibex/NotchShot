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

public struct RecordingAudioSources: OptionSet, Sendable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let system = RecordingAudioSources(rawValue: 1 << 0)
    public static let microphone = RecordingAudioSources(rawValue: 1 << 1)

    public var isEmpty: Bool { rawValue == 0 }
}

public enum RecordingQuality: String, Sendable, Codable, CaseIterable, Identifiable {
    case high
    case balanced
    case small

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .high: "High Quality"
        case .balanced: "Balanced"
        case .small: "Small File"
        }
    }

    /// Bits per pixel per frame, used to derive a bitrate from the output size.
    var bitsPerPixel: Double {
        switch self {
        case .high: 0.20
        case .balanced: 0.12
        case .small: 0.07
        }
    }
}

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
    public var quality: RecordingQuality
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
        quality: RecordingQuality = .balanced,
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
        self.quality = quality
        self.resolution = resolution
        self.framesPerSecond = framesPerSecond
        self.showsCursor = showsCursor
        self.highlightsClicks = highlightsClicks
        self.autoZoomsOnClicks = autoZoomsOnClicks
        self.framesWithBackground = framesWithBackground
    }

    /// Scales `sourcePixelSize` down to the configured resolution, preserving
    /// aspect ratio and keeping both dimensions even (H.264 requirement).
    public func outputPixelSize(for sourcePixelSize: CGSize) -> CGSize {
        guard sourcePixelSize.width > 0, sourcePixelSize.height > 0 else {
            return CGSize(width: 2, height: 2)
        }
        var size = sourcePixelSize
        if let targetHeight = resolution.targetHeight, sourcePixelSize.height > CGFloat(targetHeight) {
            let factor = CGFloat(targetHeight) / sourcePixelSize.height
            size = CGSize(width: sourcePixelSize.width * factor, height: CGFloat(targetHeight))
        }
        return CGSize(width: evenValue(size.width), height: evenValue(size.height))
    }

    public func averageBitRate(for outputPixelSize: CGSize) -> Int {
        let pixels = Double(outputPixelSize.width * outputPixelSize.height)
        let raw = pixels * Double(framesPerSecond) * quality.bitsPerPixel
        // Keep within sane bounds so a 4K/60 capture doesn't produce a 200 Mbps file.
        return Int(min(max(raw, 1_000_000), 60_000_000))
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
