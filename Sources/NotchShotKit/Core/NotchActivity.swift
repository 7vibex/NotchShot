import Foundation

/// Everything the notch can be doing. Exactly one activity is presented at a
/// time; `ActivityArbiter` decides which when several are live at once.
public enum NotchActivity: Sendable, Equatable {
    case idle
    /// Compact media presentation (artwork + title + progress).
    case media
    /// User opened the full interface deliberately (click / shortcut).
    case expanded
    /// Finder files are being held over the notch action tray.
    case fileDrop
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
    /// Mirroring a system volume or brightness change.
    case systemLevel(SystemLevel)
    /// A normalized, privacy-bounded calendar, power, audio, or document event.
    case context(ContextSnapshot)
    /// A transient error banner.
    case error(String)
    /// Transient dictation island morphed from the physical notch.
    case dictation(DictationSnapshot)

    /// Activities the user is actively driving. Auto-dismiss timers and media
    /// updates must not interrupt these.
    public var isInteractive: Bool {
        switch self {
        case .fileDrop, .selecting, .countdown, .recording, .processing: true
        case .dictation(let snap): snap.state.isActive
        default: false
        }
    }

    /// Whether the notch should render its large layout.
    public var isExpanded: Bool {
        switch self {
        case .idle, .media: false
        case .context(let snapshot): snapshot.presentation == .expanded
        case .dictation: true
        default: true
        }
    }

    public var debugName: String {
        switch self {
        case .idle: "idle"
        case .media: "media"
        case .expanded: "expanded"
        case .fileDrop: "fileDrop"
        case .selecting(let i): "selecting(\(i))"
        case .countdown(let r, _): "countdown(\(r))"
        case .recording: "recording"
        case .processing(let s): "processing(\(s))"
        case .result: "result"
        case .systemLevel(let level): "systemLevel(\(level.kind.rawValue))"
        case .context(let snapshot): "context(\(snapshot.kind.rawValue))"
        case .error(let s): "error(\(s))"
        case .dictation(let snap): "dictation(\(snap.state.debugName))"
        }
    }

    /// What the content transition should react to.
    ///
    /// Animating on the whole activity means a spring transaction over the
    /// entire content tree every time any field changes — and dictation changes
    /// its transcript several times a second while the user is still talking,
    /// which made the island wobble continuously. Only presentation-shaping
    /// fields belong here; live text and timers must not restart the animation.
    public var presentationIdentity: String {
        switch self {
        case .dictation(let snap):
            "dictation(\(snap.state.debugName))-hover:\(snap.isHoverExpanded)-text:\(snap.combinedText.isEmpty)"
        case .systemLevel(let level):
            // The HUD bar is the animation here, so its value has to be part of
            // the identity.
            "systemLevel(\(level.kind.rawValue))-\(level.value)-\(level.isMuted)"
        default:
            debugName
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
    public var systemLevel: SystemLevel?
    public var context: ContextSnapshot?
    public var hasMedia = false
    public var error: String?
    public var dictation: DictationSnapshot?

    public init() {}

    /// The single source of truth for what the notch shows. Earlier returns
    /// win, and the order is the product rule:
    ///
    ///     error → selecting → countdown → recording → processing → file drop →
    ///     result → expanded → system level → interrupting context →
    ///     media → passive context → idle
    ///
    /// Selection and countdown sit above `recording` because they are modal to
    /// the user's current action, and `processing`/`error` sit alongside so a
    /// track change can never steal the notch mid-capture. A system level sits
    /// above media so a volume nudge is visible while a track is showing, and
    /// below `expanded` so it cannot shove aside a menu the user opened. A
    /// context only outranks media when it is worth interrupting for; a passive
    /// one waits until the notch is otherwise idle.
    public func resolve() -> NotchActivity {
        if let error { return .error(error) }
        if let selection { return .selecting(selection) }
        if let countdown { return .countdown(remaining: countdown.remaining, intent: countdown.intent) }
        if let dictation, dictation.state != .idle { return .dictation(dictation) }
        if isRecording { return .recording }
        if let isProcessing { return .processing(isProcessing) }
        if isDraggingFiles { return .fileDrop }
        if hasResult { return .result }
        if userExpanded { return .expanded }
        if let systemLevel { return .systemLevel(systemLevel) }
        if let context, context.mayInterruptMedia || !hasMedia { return .context(context) }
        if hasMedia { return .media }
        if let context { return .context(context) }
        return .idle
    }
}
