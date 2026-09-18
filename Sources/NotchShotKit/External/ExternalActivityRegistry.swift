import Foundation
import NotchShotAIReporterSupport

/// An activity published through the local Live Activity API.
public struct ExternalLiveActivity: Sendable, Equatable, Identifiable {
    public enum Lifecycle: String, Sendable, Equatable {
        case active
        case succeeded
        case failed
    }

    public var id: String
    public var source: String
    public var title: String
    public var subtitle: String?
    public var stateLabel: String?
    public var progress: Double?
    public var current: Int64?
    public var total: Int64?
    public var unit: LiveActivityUnit?
    public var estimatedCompletion: Date?
    public var icon: LiveActivityIcon
    public var accent: LiveActivityAccent
    public var urgency: LiveActivityUrgency
    public var lifecycle: Lifecycle
    public var startedAt: Date
    public var updatedAt: Date
    /// Reporter-requested expiry, already clamped.
    public var expiresAt: Date?
    public var completedAt: Date?

    /// Progress the island may show: the explicit fraction, else one derived
    /// from a measured current/total pair, else nothing.
    public var effectiveProgress: Double? {
        if let progress { return progress }
        guard let current, let total, total > 0 else { return nil }
        return min(1, Double(current) / Double(total))
    }
}

/// Bounds and rules for untrusted Live Activity input. Pure value type; the
/// store adds the socket and the timers.
public struct ExternalActivityRegistry: Sendable, Equatable {
    public struct Limits: Sendable, Equatable {
        public var maximumLiveActivities = 8
        public var maximumHistory = 30
        /// An active activity with no update for this long is dropped.
        public var staleInterval: TimeInterval = 15 * 60
        /// Hard ceiling on any activity's life, updates or not.
        public var maximumLifetime: TimeInterval = 12 * 60 * 60
        /// How long a success stays visible before it moves to history.
        public var successLinger: TimeInterval = 3
        /// Failures stay a little longer so they can be read.
        public var failureLinger: TimeInterval = 6
        /// Token bucket: sustained messages per second across all clients…
        public var messagesPerSecond: Double = 20
        /// …and the burst allowed on top of it.
        public var burst: Double = 40

        public init() {}
    }

    public var limits: Limits
    public private(set) var live: [ExternalLiveActivity] = []
    public private(set) var history: [ExternalLiveActivity] = []
    private var tokens: Double
    private var lastRefill: Date?

    public init(limits: Limits = Limits()) {
        self.limits = limits
        self.tokens = limits.burst
    }

    /// Applies one validated update. Returns an error the client should see.
    @discardableResult
    public mutating func apply(_ update: LiveActivityUpdate, now: Date) -> LiveActivityValidationError? {
        guard consumeToken(now: now) else { return .init("rate limited") }
        expire(now: now)

        let index = live.firstIndex { $0.id == update.id }
        switch update.command {
        case .dismiss:
            guard let index else { return nil }
            live.remove(at: index)
            return nil

        case .start, .update:
            if let index {
                if update.command == .start {
                    // Restarting an id is a fresh run, not a merge.
                    live[index] = makeActivity(update, now: now)
                } else {
                    merge(update, into: &live[index], now: now)
                }
                return nil
            }
            guard update.title != nil else {
                return .init("unknown id; start it with a title first")
            }
            guard live.count < limits.maximumLiveActivities else {
                return .init("too many live activities")
            }
            live.append(makeActivity(update, now: now))
            return nil

        case .finish, .fail:
            let lifecycle: ExternalLiveActivity.Lifecycle = update.command == .finish ? .succeeded : .failed
            if let index {
                merge(update, into: &live[index], now: now)
                live[index].lifecycle = lifecycle
                live[index].completedAt = now
                if lifecycle == .succeeded, live[index].total != nil {
                    live[index].current = live[index].total
                }
                if lifecycle == .succeeded, live[index].progress != nil {
                    live[index].progress = 1
                }
                live[index].estimatedCompletion = nil
                return nil
            }
            // A finish for an activity never started still belongs in history
            // when it names itself, e.g. `notchshot activity finish` after a
            // crash of the app mid-run.
            guard update.title != nil else { return .init("unknown id") }
            var activity = makeActivity(update, now: now)
            activity.lifecycle = lifecycle
            activity.completedAt = now
            appendHistory(activity)
            return nil
        }
    }

    /// Removes stale, over-age, and finished-and-lingered activities.
    /// Returns `true` when anything changed.
    @discardableResult
    public mutating func expire(now: Date) -> Bool {
        var changed = false
        var kept: [ExternalLiveActivity] = []
        for activity in live {
            if let completedAt = activity.completedAt {
                let linger = activity.lifecycle == .failed ? limits.failureLinger : limits.successLinger
                if now.timeIntervalSince(completedAt) >= linger {
                    appendHistory(activity)
                    changed = true
                    continue
                }
            } else if let expiresAt = activity.expiresAt, expiresAt <= now {
                changed = true
                continue
            } else if now.timeIntervalSince(activity.updatedAt) >= limits.staleInterval
                        || now.timeIntervalSince(activity.startedAt) >= limits.maximumLifetime {
                changed = true
                continue
            }
            kept.append(activity)
        }
        live = kept
        return changed
    }

    /// Next moment `expire(now:)` could change something.
    public var nextDeadline: Date? {
        live.map { activity -> Date in
            if let completedAt = activity.completedAt {
                let linger = activity.lifecycle == .failed ? limits.failureLinger : limits.successLinger
                return completedAt.addingTimeInterval(linger)
            }
            let stale = activity.updatedAt.addingTimeInterval(limits.staleInterval)
            let ceiling = activity.startedAt.addingTimeInterval(limits.maximumLifetime)
            return [stale, ceiling, activity.expiresAt].compactMap { $0 }.min() ?? stale
        }.min()
    }

    public mutating func clearHistory() {
        history.removeAll()
    }

    public mutating func dismiss(id: String) {
        live.removeAll { $0.id == id }
    }

    public mutating func removeAll() {
        live.removeAll()
    }

    // MARK: Internals

    private func makeActivity(_ update: LiveActivityUpdate, now: Date) -> ExternalLiveActivity {
        var activity = ExternalLiveActivity(
            id: update.id,
            source: update.source ?? "External",
            title: update.title ?? update.id,
            subtitle: update.subtitle,
            stateLabel: update.stateLabel,
            progress: update.progress,
            current: update.current,
            total: update.total,
            unit: update.unit,
            estimatedCompletion: nil,
            icon: update.icon ?? .gear,
            accent: update.accent ?? .blue,
            urgency: update.urgency ?? .normal,
            lifecycle: .active,
            startedAt: now,
            updatedAt: now,
            expiresAt: update.expiresIn.map { now.addingTimeInterval($0) },
            completedAt: nil
        )
        if let eta = update.etaSeconds { activity.estimatedCompletion = now.addingTimeInterval(eta) }
        return activity
    }

    private func merge(_ update: LiveActivityUpdate, into activity: inout ExternalLiveActivity, now: Date) {
        if let source = update.source { activity.source = source }
        if let title = update.title { activity.title = title }
        if let subtitle = update.subtitle { activity.subtitle = subtitle }
        if let state = update.stateLabel { activity.stateLabel = state }
        if let progress = update.progress { activity.progress = progress }
        if let current = update.current { activity.current = current }
        if let total = update.total { activity.total = total }
        if let current = activity.current, let total = activity.total, current > total {
            activity.current = total
        }
        if let unit = update.unit { activity.unit = unit }
        if let eta = update.etaSeconds { activity.estimatedCompletion = now.addingTimeInterval(eta) }
        if let icon = update.icon { activity.icon = icon }
        if let accent = update.accent { activity.accent = accent }
        if let urgency = update.urgency { activity.urgency = urgency }
        if let expires = update.expiresIn { activity.expiresAt = now.addingTimeInterval(expires) }
        activity.updatedAt = now
    }

    private mutating func appendHistory(_ activity: ExternalLiveActivity) {
        history.removeAll { $0.id == activity.id }
        history.insert(activity, at: 0)
        if history.count > limits.maximumHistory {
            history.removeLast(history.count - limits.maximumHistory)
        }
    }

    private mutating func consumeToken(now: Date) -> Bool {
        if let lastRefill {
            let elapsed = max(0, now.timeIntervalSince(lastRefill))
            tokens = min(limits.burst, tokens + elapsed * limits.messagesPerSecond)
        }
        lastRefill = now
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}
