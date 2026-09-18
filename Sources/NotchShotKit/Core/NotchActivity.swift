import Foundation

/// Everything the notch can be doing. Exactly one activity *presentation* is
/// resolved at a time; `ActivityArbiter` decides which when several are live.
///
/// Long-lived work — media, recording, timers, agents, transfers, external
/// activities — is not a case of its own once the multi-activity island is on:
/// it is folded into `.island`, whose descriptor says which activities are
/// visible and where. The remaining cases are modal takeovers the user is
/// driving (selection, countdown, dictation, file drop, the capture menu) or
/// legacy single-activity presentations used when the island is disabled.
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
    /// A transient, memory-only mirror of a banner Notification Center is
    /// visibly presenting while the user session is unlocked.
    case systemNotification(SystemNotificationSnapshot)
    /// A transient error banner.
    case error(String)
    /// Transient dictation island morphed from the physical notch.
    case dictation(DictationSnapshot)
    /// The multi-activity island: one primary, up to two satellites, and an
    /// optional transient overlay. See `IslandPresentationEngine`.
    case island(IslandLayoutDescriptor)

    /// Activities the user is actively driving. Auto-dismiss timers and media
    /// updates must not interrupt these.
    public var isInteractive: Bool {
        switch self {
        case .fileDrop, .selecting, .countdown, .recording, .processing: true
        case .dictation(let snap): snap.state.isActive
        case .island(let descriptor): descriptor.primaryKind == .recording
        default: false
        }
    }

    /// Whether the notch should render its large layout.
    public var isExpanded: Bool {
        switch self {
        case .idle, .media: false
        case .context(let snapshot): snapshot.presentation == .expanded
        case .systemNotification: true
        case .dictation: true
        case .island(let descriptor): descriptor.isExpanded || descriptor.overlay != nil
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
        case .systemNotification(let snapshot): "systemNotification(\(snapshot.id))"
        case .error(let s): "error(\(s))"
        case .dictation(let snap): "dictation(\(snap.state.debugName))"
        case .island(let descriptor): descriptor.identity
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
        case .systemNotification(let snapshot):
            "systemNotification(\(snapshot.id))"
        case .island(let descriptor):
            // Stable activity IDs, level, slots and overlay kind only.
            descriptor.identity
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
    public var systemNotification: SystemNotificationSnapshot?
    public var hasMedia = false
    public var error: String?
    public var dictation: DictationSnapshot?
    /// The multi-activity island, when enabled and non-empty. It already
    /// contains media, recording (when the island presents it), agents,
    /// timers, transfers and external activities, so those flags are ignored
    /// in its favour at their own rung.
    public var island: IslandLayoutDescriptor?
    /// Set while the island is enabled. Media and persistent contexts (agents,
    /// timers, voice notes, calendar) are then island activities, so their
    /// legacy single-activity rungs must stay silent even when the island has
    /// hidden them by preference.
    public var islandOwnsAmbientActivities = false
    /// Whether an interrupting context card may overlay an island primary.
    public var allowsContextOverlay = true

    public init() {}

    /// The single source of truth for what the notch shows. Earlier returns
    /// win, and the order is the product rule:
    ///
    ///     error → selecting → countdown → dictation → recording → processing →
    ///     file drop → result → expanded → notification → system level →
    ///     interrupting context → media → passive context → idle
    ///
    /// With the multi-activity island enabled, a recording the island presents
    /// resolves to `.island` at the recording rung (so processing, a result, or
    /// the capture menu still cannot hide it), and every other island resolves
    /// just below notification banners. A volume change or an interrupting
    /// context then becomes the island's *overlay* instead of replacing it, so
    /// the underlying primary survives the burst.
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
        if isRecording {
            if let island, island.containsRecording { return .island(islandWithOverlay(island)) }
            return .recording
        }
        if let isProcessing { return .processing(isProcessing) }
        if isDraggingFiles { return .fileDrop }
        if hasResult { return .result }
        if userExpanded { return .expanded }
        if let systemNotification { return .systemNotification(systemNotification) }
        // A burst with nothing underneath waits behind a level HUD rather than
        // hiding it; with a primary, the HUD becomes the island's overlay.
        if let island, island.hasPrimary || (island.overlay != nil && systemLevel == nil) {
            return .island(islandWithOverlay(island))
        }
        if let systemLevel { return .systemLevel(systemLevel) }
        let context = islandOwnsAmbientActivities
            ? self.context.flatMap { Self.isTransientContext($0) ? $0 : nil }
            : self.context
        let hasMedia = hasMedia && !islandOwnsAmbientActivities
        if let context, context.mayInterruptMedia || !hasMedia { return .context(context) }
        if hasMedia { return .media }
        if let context { return .context(context) }
        return .idle
    }

    /// Folds a level HUD or an interrupting transient context into an island
    /// that has a primary to return to. Without a primary, the legacy
    /// single-activity cards keep presenting those on their own.
    func islandWithOverlay(_ island: IslandLayoutDescriptor) -> IslandLayoutDescriptor {
        guard island.hasPrimary else { return island }
        var result = island
        if let systemLevel {
            let overlay = IslandOverlay.systemLevel(systemLevel)
            result.overlay = overlay.layoutClass
            result.overlayKey = overlay.structuralKey
            result.overlayDisplayID = systemLevel.displayID
        } else if let context,
                  allowsContextOverlay,
                  Self.isTransientContext(context),
                  context.mayInterruptMedia,
                  !island.isExpanded {
            // A card with its own controls never covers an island the user
            // opened; it waits until the island collapses (or expires).
            let overlay = IslandOverlay.context(context)
            result.overlay = overlay.layoutClass
            result.overlayKey = overlay.structuralKey
            result.overlayDisplayID = nil
        }
        return result
    }

    /// Context kinds that are bursts rather than island activities.
    public static func isTransientContext(_ snapshot: ContextSnapshot) -> Bool {
        switch snapshot.kind {
        case .power, .audioRoute, .network, .document: true
        case .ai, .calendar, .timer, .voiceNote: false
        }
    }
}
