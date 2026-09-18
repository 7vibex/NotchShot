import Foundation

public enum IslandEventSeverity: String, Sendable, Codable, Equatable {
    case informational
    case success
    case warning
    case error

    /// Serious states get restrained motion; only good news may bounce.
    public var allowsPlayfulMotion: Bool { self == .success || self == .informational }
}

/// Short-lived events that are not worth a place in the activity set.
public enum IslandTransientKind: String, Sendable, Codable, Equatable, Hashable {
    case focus
    case transferCompleted
    case transferFailed
    case activityCompleted
    case activityFailed
    case captureSaved
}

/// A burst: the island stretches, shows an icon and a line, holds briefly,
/// then returns to whatever was underneath. Nothing underneath is destroyed.
public struct IslandTransientEvent: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: IslandTransientKind
    public var severity: IslandEventSeverity
    /// Events with the same key replace each other instead of queueing, so a
    /// Focus flip-flop or a burst of completions shows once, current.
    public var coalescingKey: String
    public var symbolName: String
    public var title: String
    public var detail: String?
    public var createdAt: Date
    public var holdDuration: TimeInterval

    public init(
        id: UUID = UUID(),
        kind: IslandTransientKind,
        severity: IslandEventSeverity = .informational,
        coalescingKey: String? = nil,
        symbolName: String,
        title: String,
        detail: String? = nil,
        createdAt: Date = Date(),
        holdDuration: TimeInterval? = nil
    ) {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.coalescingKey = coalescingKey ?? kind.rawValue
        self.symbolName = symbolName
        self.title = String(title.prefix(IslandTransientQueue.maximumTitleLength))
        self.detail = detail.map { String($0.prefix(IslandTransientQueue.maximumDetailLength)) }
        self.createdAt = createdAt
        let fallback: TimeInterval = severity == .error || severity == .warning ? 3.2 : 2.2
        self.holdDuration = min(8, max(0.8, holdDuration ?? fallback))
    }

    public var expiresAt: Date { createdAt.addingTimeInterval(holdDuration) }
}

/// Bounded FIFO of bursts with coalescing.
public struct IslandTransientQueue: Sendable, Equatable {
    public static let maximumPending = 4
    public static let maximumTitleLength = 48
    public static let maximumDetailLength = 80

    public private(set) var current: IslandTransientEvent?
    public private(set) var pending: [IslandTransientEvent] = []

    public init() {}

    /// Presents or queues an event. Returns `true` when `current` changed.
    @discardableResult
    public mutating func enqueue(_ event: IslandTransientEvent) -> Bool {
        if let current, current.coalescingKey == event.coalescingKey {
            // Replace in place and restart the hold: the user sees the latest
            // state for its full duration rather than a stale one cut short.
            self.current = event
            return true
        }
        if let index = pending.firstIndex(where: { $0.coalescingKey == event.coalescingKey }) {
            pending[index] = event
            return false
        }
        guard current != nil else {
            current = event
            return true
        }
        pending.append(event)
        if pending.count > Self.maximumPending {
            // Drop the oldest informational event first; errors survive.
            if let dropIndex = pending.firstIndex(where: { $0.severity == .informational }) {
                pending.remove(at: dropIndex)
            } else {
                pending.removeFirst()
            }
        }
        return false
    }

    /// Advances past an expired current event. Returns `true` when `current`
    /// changed. Pending events start their hold when they become current.
    @discardableResult
    public mutating func expire(now: Date) -> Bool {
        guard let current, current.expiresAt <= now else { return false }
        advance(now: now)
        return true
    }

    public mutating func dismissCurrent(now: Date = Date()) {
        advance(now: now)
    }

    public mutating func removeAll() {
        current = nil
        pending.removeAll()
    }

    private mutating func advance(now: Date) {
        guard !pending.isEmpty else {
            current = nil
            return
        }
        var next = pending.removeFirst()
        next.createdAt = now
        current = next
    }
}

/// Which card the overlay draws, reduced to what the layout needs. It never
/// carries a live value, so a volume key repeat does not change it.
public enum IslandOverlayLayoutClass: String, Sendable, Codable, Equatable, Hashable {
    case systemLevel
    case lowBattery
    case networkOffline
    case networkOnline
    case audioRoute
    case contextNotice
    case event
}

/// The transient layer presented over the activity set.
public enum IslandOverlay: Sendable, Equatable {
    case systemLevel(SystemLevel)
    case context(ContextSnapshot)
    case event(IslandTransientEvent)

    public var layoutClass: IslandOverlayLayoutClass {
        switch self {
        case .systemLevel: .systemLevel
        case .event: .event
        case .context(let snapshot):
            if PowerModePresentationPolicy.isLowBatteryAlert(snapshot) { .lowBattery }
            else if NetworkContextPolicy.isNetworkCard(snapshot) {
                NetworkContextPolicy.isOfflineAlert(snapshot) ? .networkOffline : .networkOnline
            } else if snapshot.kind == .audioRoute { .audioRoute }
            else { .contextNotice }
        }
    }

    /// Stable identity of the overlay *occurrence*, excluding live values.
    public var structuralKey: String {
        switch self {
        case .systemLevel(let level): "level-" + level.kind.rawValue
        case .context(let snapshot): "context-" + snapshot.kind.rawValue
        case .event(let event): "event-" + event.coalescingKey
        }
    }

    public var severity: IslandEventSeverity {
        switch self {
        case .systemLevel: .informational
        case .event(let event): event.severity
        case .context(let snapshot):
            switch layoutClass {
            case .lowBattery, .networkOffline: .warning
            default: snapshot.kind == .document ? .success : .informational
            }
        }
    }
}
