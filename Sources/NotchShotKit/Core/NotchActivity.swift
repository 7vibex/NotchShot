import Foundation

/// Everything the notch can be doing. Exactly one activity is presented at a
/// time; `ActivityArbiter` decides which when several are live at once.
public enum NotchActivity: Sendable, Equatable {
    case idle
    /// Compact media presentation (artwork + title + progress).
    case media
    /// User opened the full interface deliberately (click / shortcut / drag).
    case expanded
    /// A selection overlay is on screen.
    case selecting(CaptureIntent)
    /// Timer capture is counting down.
    case countdown(remaining: Int, intent: CaptureIntent)
    /// A recording is in progress.
    case recording
    /// Post-capture work (stitching, encoding, OCR) is running.
    case processing(String)
    /// A finished capture is sitting in the shelf.
    case result
    /// A transient error banner.
    case error(String)

    /// Higher wins. The ordering is the product rule:
    /// recording → capture ready → file drop → expanded → media → idle.
    ///
    /// Selection and countdown sit above `recording` because they are modal to
    /// the user's current action, and `processing`/`error` sit alongside so a
    /// track change can never steal the notch mid-capture.
    public var priority: Int {
        switch self {
        case .error: 100
        case .selecting: 90
        case .countdown: 85
        case .recording: 80
        case .processing: 70
        case .result: 60
        case .expanded: 40
        case .media: 20
        case .idle: 0
        }
    }

    /// Activities the user is actively driving. Auto-dismiss timers and media
    /// updates must not interrupt these.
    public var isInteractive: Bool {
        switch self {
        case .selecting, .countdown, .recording, .processing: true
        default: false
        }
    }

    /// Whether the notch should render its large layout.
    public var isExpanded: Bool {
        switch self {
        case .idle, .media: false
        default: true
        }
    }

    public var debugName: String {
        switch self {
        case .idle: "idle"
        case .media: "media"
        case .expanded: "expanded"
        case .selecting(let i): "selecting(\(i))"
        case .countdown(let r, _): "countdown(\(r))"
        case .recording: "recording"
        case .processing(let s): "processing(\(s))"
        case .result: "result"
        case .error(let s): "error(\(s))"
        }
    }
}

/// Resolves the presented activity from every live source. Kept free of UI so
/// the priority rule is unit-testable in isolation.
public struct ActivityArbiter: Sendable {
    public var isRecording = false
    public var isProcessing: String?
    public var selection: CaptureIntent?
    public var countdown: (remaining: Int, intent: CaptureIntent)?
    public var hasResult = false
    public var isDraggingFiles = false
    public var userExpanded = false
    public var hasMedia = false
    public var error: String?

    public init() {}

    public func resolve() -> NotchActivity {
        if let error { return .error(error) }
        if let selection { return .selecting(selection) }
        if let countdown { return .countdown(remaining: countdown.remaining, intent: countdown.intent) }
        if isRecording { return .recording }
        if let isProcessing { return .processing(isProcessing) }
        if hasResult { return .result }
        if isDraggingFiles { return .expanded }
        if userExpanded { return .expanded }
        if hasMedia { return .media }
        return .idle
    }
}
