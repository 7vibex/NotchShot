import Foundation

/// What kind of long-lived work an island activity stands for.
///
/// Kinds are few and closed on purpose: the island's layout and its shared
/// elements are designed per kind, and an external reporter can only ever
/// produce `.external` — it cannot claim to be a recording or a timer.
public enum IslandActivityKind: String, Sendable, Codable, CaseIterable, Hashable {
    case recording
    case voiceNote
    case media
    case timer
    case ai
    case transfer
    case external
    case calendar

    public var title: String {
        switch self {
        case .recording: "Recording"
        case .voiceNote: "Voice Note"
        case .media: "Now Playing"
        case .timer: "Timer"
        case .ai: "AI Activity"
        case .transfer: "Transfer"
        case .external: "Activity"
        case .calendar: "Calendar"
        }
    }
}

/// Stable identity for an activity.
///
/// Identity is the kind plus a source-owned key, never a value that changes
/// while the activity lives. A title, a percentage, a transcript, or the
/// remaining time on a timer must not appear here: SwiftUI animates between
/// identities, so a changing identity is what makes a view flicker and restart.
public struct IslandActivityID: Hashable, Sendable, Codable, CustomStringConvertible {
    public var kind: IslandActivityKind
    public var key: String

    public init(kind: IslandActivityKind, key: String) {
        self.kind = kind
        self.key = key
    }

    public var description: String { kind.rawValue + ":" + key }
}

/// Coarse ordering. Priority decides who *may* take the primary slot;
/// relevance only breaks ties inside a priority band.
public enum IslandPriority: Int, Sendable, Codable, Comparable, CaseIterable {
    /// Ambient information: an upcoming calendar event.
    case passive = 0
    /// Ordinary ongoing work: media, a timer, a transfer, an agent.
    case normal = 1
    /// Work asking for the user: an agent waiting on a permission decision.
    case elevated = 2
    /// Work the user started and must always be able to see: a recording.
    case critical = 3

    public static func < (lhs: IslandPriority, rhs: IslandPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum IslandLifecycle: String, Sendable, Codable, Equatable {
    case active
    case paused
    /// Blocked on the user.
    case waiting
    case succeeded
    case failed

    public var isTerminal: Bool { self == .succeeded || self == .failed }
}

/// Progress as the source reports it. There is no case for an estimate: a
/// source without a measured total is `.indeterminate`, and the island shows a
/// spinner-like state instead of inventing a number.
public enum IslandProgress: Sendable, Equatable {
    case none
    case indeterminate
    case determinate(Double)

    /// Builds progress from an optional reported fraction, clamping and
    /// rejecting non-finite values rather than trusting them.
    public static func reported(_ fraction: Double?) -> IslandProgress {
        guard let fraction, fraction.isFinite else { return .indeterminate }
        return .determinate(min(1, max(0, fraction)))
    }

    public var fraction: Double? {
        if case .determinate(let value) = self { return value }
        return nil
    }
}

/// A measured quantity behind the progress, when the source has one.
public struct IslandMeasurement: Sendable, Equatable {
    public enum Unit: String, Sendable, Codable, Equatable {
        case bytes
        case items
        case count
    }

    public var completed: Int64
    public var total: Int64?
    public var unit: Unit
    /// Measured throughput in units per second, if the source sampled one.
    public var ratePerSecond: Double?
    /// Only set when derived from real measurements or supplied explicitly.
    public var estimatedCompletion: Date?

    public init(
        completed: Int64,
        total: Int64? = nil,
        unit: Unit,
        ratePerSecond: Double? = nil,
        estimatedCompletion: Date? = nil
    ) {
        self.completed = max(0, completed)
        self.total = total.map { max(0, $0) }
        self.unit = unit
        self.ratePerSecond = ratePerSecond
        self.estimatedCompletion = estimatedCompletion
    }
}

/// How an activity treats the primary slot when it arrives or changes.
public enum IslandInterruptionPolicy: String, Sendable, Codable, Equatable {
    /// Takes the primary slot on arrival and cannot be displaced by any
    /// arrival afterwards. Only an explicit user selection demotes it.
    case pinned
    /// Competes by priority and relevance. Never steals a user selection.
    case standard
    /// Never becomes primary while any non-passive activity exists.
    case passive
}

/// Commands an activity can expose. The island maps these to real handlers; an
/// external reporter can request only `cancel`/`dismiss`, and only for its own
/// activity.
public enum IslandActivityAction: String, Sendable, Codable, Equatable, CaseIterable {
    case playPause
    case nextTrack
    case previousTrack
    case pause
    case resume
    case stop
    case cancel
    case dismiss
    case approve
    case deny
}

public enum IslandPresentationLevel: String, Sendable, Codable, Equatable, Hashable {
    case minimal
    case compact
    case expanded
}

/// One piece of long-lived work the island can present.
///
/// This is a normalized *summary*: the island decides placement from it, and
/// the views read the rich source model (the media snapshot, the timer, the
/// agent records) for detail. It deliberately carries no full payloads.
public struct IslandActivity: Identifiable, Sendable, Equatable {
    public var id: IslandActivityID
    public var priority: IslandPriority
    /// 0...1, ordering within one priority band.
    public var relevance: Double
    public var lifecycle: IslandLifecycle
    public var progress: IslandProgress
    public var measurement: IslandMeasurement?
    public var startedAt: Date
    public var updatedAt: Date
    public var actions: [IslandActivityAction]
    public var interruptionPolicy: IslandInterruptionPolicy
    /// When set, the activity leaves the island at this moment even if its
    /// source forgot to remove it.
    public var expiresAt: Date?

    public var title: String
    public var subtitle: String?
    /// A short changing state word: "Working", "Paused", "Connected".
    public var stateLabel: String?
    /// A short changing metric: "04:31", "42%".
    public var metric: String?
    public var symbolName: String
    public var accentHex: String

    public var kind: IslandActivityKind { id.kind }

    public init(
        id: IslandActivityID,
        priority: IslandPriority = .normal,
        relevance: Double = 0.5,
        lifecycle: IslandLifecycle = .active,
        progress: IslandProgress = .none,
        measurement: IslandMeasurement? = nil,
        startedAt: Date,
        updatedAt: Date? = nil,
        actions: [IslandActivityAction] = [],
        interruptionPolicy: IslandInterruptionPolicy = .standard,
        expiresAt: Date? = nil,
        title: String,
        subtitle: String? = nil,
        stateLabel: String? = nil,
        metric: String? = nil,
        symbolName: String,
        accentHex: String = "#FFFFFF"
    ) {
        self.id = id
        self.priority = priority
        self.relevance = relevance.isFinite ? min(1, max(0, relevance)) : 0
        self.lifecycle = lifecycle
        self.progress = progress
        self.measurement = measurement
        self.startedAt = startedAt
        self.updatedAt = updatedAt ?? startedAt
        self.actions = actions
        self.interruptionPolicy = interruptionPolicy
        self.expiresAt = expiresAt
        self.title = title
        self.subtitle = subtitle
        self.stateLabel = stateLabel
        self.metric = metric
        self.symbolName = symbolName
        self.accentHex = accentHex
    }

    public func isExpired(at now: Date) -> Bool {
        expiresAt.map { $0 <= now } ?? false
    }

    /// Activities blocked on the user keep an expanded island open after the
    /// pointer leaves; everything else collapses back on its own.
    public var requiresPersistentInteraction: Bool {
        lifecycle == .waiting
    }

    /// A readable one-line summary for VoiceOver.
    public var accessibilitySummary: String {
        [title, stateLabel, metric]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: ", ")
    }
}
