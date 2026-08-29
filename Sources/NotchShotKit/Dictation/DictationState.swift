import CoreGraphics
import Foundation

/// Dedicated state machine for Notch Dictation. Separate from Voice Notes.
/// Transient, system-wide, no persistence.
public enum DictationState: Sendable, Equatable {
    case idle
    case requestingMicrophone
    case preparingModel(progress: Double)
    case listening
    case finalizing
    case inserting
    case copied
    case completed
    case cancelled
    case failed(String)

    public var isActive: Bool {
        switch self {
        case .idle, .completed, .cancelled, .failed: false
        case .requestingMicrophone, .preparingModel, .listening, .finalizing, .inserting, .copied: true
        }
    }

    public var isListening: Bool {
        if case .listening = self { return true }
        return false
    }

    public var debugName: String {
        switch self {
        case .idle: "idle"
        case .requestingMicrophone: "requestingMicrophone"
        case .preparingModel(let p): "preparingModel(\(p))"
        case .listening: "listening"
        case .finalizing: "finalizing"
        case .inserting: "inserting"
        case .copied: "copied"
        case .completed: "completed"
        case .cancelled: "cancelled"
        case .failed(let m): "failed(\(m))"
        }
    }

    /// Whether a visible Stop control makes sense.
    ///
    /// Only a live recording can be finalized. Permission and model-download
    /// states have no analyzer to finish, so offering Stop there sent the
    /// session through finalization to a spurious "No speech detected"; they
    /// offer Cancel instead, matching `toggleIntent`.
    public var isStoppable: Bool {
        toggleIntent == .stop
    }

    public var toggleIntent: DictationToggleIntent {
        switch self {
        case .idle, .completed, .cancelled, .failed, .copied: .start
        case .requestingMicrophone, .preparingModel: .cancel
        case .listening: .stop
        case .finalizing, .inserting: .ignore
        }
    }
}

public enum DictationToggleIntent: Sendable, Equatable {
    case start
    case cancel
    case stop
    case ignore
}

public enum DictationTriggerMode: String, Sendable, CaseIterable, Identifiable, Codable {
    case toggle
    case holdToTalk

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .toggle: "Toggle"
        case .holdToTalk: "Hold to Talk"
        }
    }
}

public enum DictationEngineKind: String, Sendable, CaseIterable, Identifiable, Codable {
    case speechAnalyzer

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .speechAnalyzer: "On-Device (SpeechAnalyzer)"
        }
    }
}

public enum DictationPostProcessingMode: String, Sendable, CaseIterable, Identifiable, Codable {
    case verbatim
    case clean
    case localPolish

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .verbatim: "Verbatim"
        case .clean: "Clean Dictation"
        case .localPolish: "Local Polish"
        }
    }
}

public enum DictationAppendMode: String, Sendable, CaseIterable, Identifiable, Codable {
    case nothing
    case space
    case newline

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .nothing: "Nothing"
        case .space: "Space"
        case .newline: "Newline"
        }
    }
}

public enum DictationInsertMode: String, Sendable, CaseIterable, Identifiable, Codable {
    case automatic
    case copyOnly

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .automatic: "Insert Automatically"
        case .copyOnly: "Copy Only"
        }
    }
}

/// The live microphone trace, kept deliberately *outside* `DictationSnapshot`.
///
/// The snapshot travels through `NotchActivity`, so anything stored on it
/// re-renders — and, worse, re-animates — the entire notch whenever it changes.
/// A waveform updating 25 times a second there sprang a new content animation
/// on every frame and spammed one VoiceOver announcement per tick. Only the
/// waveform view observes this type, so the cost stays where the motion is.
public struct DictationMeter: Sendable, Equatable {
    /// Columns in the scrolling trace. One is appended per tick, so the count
    /// is also the length of the visible history.
    public static let columnCount = 34
    /// Baseline so silence still reads as a centre line rather than nothing.
    public static let floorValue: Float = 0.055

    /// Smoothed level of the newest column, 0…1.
    public var level: Float
    /// Oldest-to-newest trace. Always `columnCount` long.
    public var columns: [Float]
    /// False while the microphone is not actually running, so the view can
    /// show a flat line instead of inventing motion.
    public var isCapturing: Bool

    public init(
        level: Float = 0,
        columns: [Float] = Array(repeating: DictationMeter.floorValue, count: DictationMeter.columnCount),
        isCapturing: Bool = false
    ) {
        self.level = level
        self.columns = columns
        self.isCapturing = isCapturing
    }

    /// Advances the trace by exactly one column per call. Scroll speed is
    /// therefore the tick rate, not however many audio buffers happened to
    /// land in the last frame — which is what made the old trace jump.
    public mutating func advance(level newLevel: Float) {
        let clamped = max(Self.floorValue, min(1, newLevel))
        level = clamped
        if columns.count == Self.columnCount {
            columns.removeFirst()
            columns.append(clamped)
        } else {
            columns = Array(
                (Array(repeating: Self.floorValue, count: Self.columnCount) + columns + [clamped])
                    .suffix(Self.columnCount)
            )
        }
    }

    /// Lets the trace fall away and scroll out instead of freezing mid-word
    /// when capture stops.
    public mutating func settle() {
        advance(level: level * 0.55)
    }

    public var isSilent: Bool {
        columns.allSatisfy { $0 <= Self.floorValue + 0.001 }
    }
}

public struct DictationSnapshot: Sendable, Equatable {
    public var state: DictationState
    public var sessionID: UInt64
    public var displayID: CGDirectDisplayID?
    public var elapsed: TimeInterval
    public var finalizedText: String
    public var volatileText: String
    public var isHoverExpanded: Bool
    public var errorMessage: String?
    public var languageCode: String

    public init(
        state: DictationState = .idle,
        sessionID: UInt64 = 0,
        displayID: CGDirectDisplayID? = nil,
        elapsed: TimeInterval = 0,
        finalizedText: String = "",
        volatileText: String = "",
        isHoverExpanded: Bool = false,
        errorMessage: String? = nil,
        languageCode: String = Locale.current.identifier
    ) {
        self.state = state
        self.sessionID = sessionID
        self.displayID = displayID
        self.elapsed = elapsed
        self.finalizedText = finalizedText
        self.volatileText = volatileText
        self.isHoverExpanded = isHoverExpanded
        self.errorMessage = errorMessage
        self.languageCode = languageCode
    }

    public var combinedText: String {
        let v = volatileText.trimmingCharacters(in: .whitespacesAndNewlines)
        let f = finalizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if f.isEmpty { return v }
        if v.isEmpty { return f }
        return f + " " + v
    }

    public var isActive: Bool { state.isActive }
}
