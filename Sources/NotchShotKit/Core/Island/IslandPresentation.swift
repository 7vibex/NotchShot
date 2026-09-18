import CoreGraphics
import Foundation

/// A satellite position beside the primary island.
public enum IslandSlot: String, Sendable, Codable, Hashable, CaseIterable {
    case leading
    case trailing
}

/// Horizontal direction for navigation between simultaneous activities.
public enum IslandNavigationDirection: Sendable, Equatable {
    case leading
    case trailing
}

/// The resolved state of the multi-activity island.
public struct IslandPresentation: Sendable, Equatable {
    public var primary: IslandActivity?
    public var leading: IslandActivity?
    public var trailing: IslandActivity?
    /// Level of the primary. Satellites are always `.minimal`.
    public var level: IslandPresentationLevel
    public var expandedActivityID: IslandActivityID?
    public var transientOverlay: IslandOverlay?
    /// Live activities that did not fit in the visible slots.
    public var hiddenCount: Int
    /// When the primary just changed by promoting a satellite, the side it
    /// came from — so content can travel in from that side instead of
    /// crossfading. Not structural: it never affects layout or identity.
    public var primaryArrivalEdge: IslandSlot?

    public init(
        primary: IslandActivity? = nil,
        leading: IslandActivity? = nil,
        trailing: IslandActivity? = nil,
        level: IslandPresentationLevel = .compact,
        expandedActivityID: IslandActivityID? = nil,
        transientOverlay: IslandOverlay? = nil,
        hiddenCount: Int = 0,
        primaryArrivalEdge: IslandSlot? = nil
    ) {
        self.primary = primary
        self.leading = leading
        self.trailing = trailing
        self.level = level
        self.expandedActivityID = expandedActivityID
        self.transientOverlay = transientOverlay
        self.hiddenCount = hiddenCount
        self.primaryArrivalEdge = primaryArrivalEdge
    }

    public static let empty = IslandPresentation()

    /// Up to two satellites, leading first.
    public var secondary: [IslandActivity] { [leading, trailing].compactMap { $0 } }

    /// Every visible activity, in on-screen order.
    public var visibleActivities: [IslandActivity] {
        [leading, primary, trailing].compactMap { $0 }
    }

    public var isEmpty: Bool { primary == nil && transientOverlay == nil }

    public func slot(of id: IslandActivityID) -> IslandSlot? {
        if leading?.id == id { return .leading }
        if trailing?.id == id { return .trailing }
        return nil
    }

    public func activity(in slot: IslandSlot) -> IslandActivity? {
        slot == .leading ? leading : trailing
    }

    public func neighbor(_ direction: IslandNavigationDirection) -> IslandActivity? {
        direction == .leading ? leading : trailing
    }

    public func presentationLevel(of id: IslandActivityID) -> IslandPresentationLevel? {
        if primary?.id == id { return level }
        return slot(of: id) == nil ? nil : .minimal
    }

    /// Structural description for layout and animation.
    public func descriptor(overlayDisplayID: CGDirectDisplayID? = nil) -> IslandLayoutDescriptor {
        IslandLayoutDescriptor(
            primaryID: primary?.id,
            level: level,
            leadingID: leading?.id,
            trailingID: trailing?.id,
            overlay: transientOverlay?.layoutClass,
            overlayKey: transientOverlay?.structuralKey,
            overlayDisplayID: overlayDisplayID
        )
    }
}

/// What the notch geometry and the animation system need to know about the
/// island — and nothing else.
///
/// This is carried by `NotchActivity.island`, so it is compared on every
/// refresh. It contains only stable identities and presentation-shaping
/// state: a timer tick, a new percentage, or a transcript word never changes
/// it, which is what keeps the shell from wobbling under live data.
public struct IslandLayoutDescriptor: Sendable, Equatable, Hashable {
    public var primaryID: IslandActivityID?
    public var level: IslandPresentationLevel
    public var leadingID: IslandActivityID?
    public var trailingID: IslandActivityID?
    public var overlay: IslandOverlayLayoutClass?
    public var overlayKey: String?
    /// Display a display-specific overlay (a brightness change) belongs to.
    public var overlayDisplayID: CGDirectDisplayID?

    public init(
        primaryID: IslandActivityID? = nil,
        level: IslandPresentationLevel = .compact,
        leadingID: IslandActivityID? = nil,
        trailingID: IslandActivityID? = nil,
        overlay: IslandOverlayLayoutClass? = nil,
        overlayKey: String? = nil,
        overlayDisplayID: CGDirectDisplayID? = nil
    ) {
        self.primaryID = primaryID
        self.level = level
        self.leadingID = leadingID
        self.trailingID = trailingID
        self.overlay = overlay
        self.overlayKey = overlayKey
        self.overlayDisplayID = overlayDisplayID
    }

    public var primaryKind: IslandActivityKind? { primaryID?.kind }
    public var hasPrimary: Bool { primaryID != nil }
    public var satelliteCount: Int { (leadingID == nil ? 0 : 1) + (trailingID == nil ? 0 : 1) }
    public var isExpanded: Bool { level == .expanded }

    /// Satellites step aside while the primary is expanded or a burst is
    /// stretching the shell, so they never drift out from under the pointer.
    public var showsSatellites: Bool {
        satelliteCount > 0 && level != .expanded && overlay == nil
    }

    public var containsRecording: Bool {
        [primaryID, leadingID, trailingID].contains { $0?.kind == .recording }
    }

    /// Identity string for `NotchActivity.presentationIdentity`.
    public var identity: String {
        let parts = [
            "p:" + (primaryID?.description ?? "-"),
            "l:" + level.rawValue,
            "a:" + (leadingID?.description ?? "-"),
            "b:" + (trailingID?.description ?? "-"),
            "o:" + (overlayKey ?? "-"),
        ]
        return "island(" + parts.joined(separator: "|") + ")"
    }

    /// The same island as a secondary display should draw it: never expanded,
    /// never carrying another display's burst.
    public func restingCopy() -> IslandLayoutDescriptor {
        var copy = self
        copy.level = .compact
        copy.overlay = nil
        copy.overlayKey = nil
        copy.overlayDisplayID = nil
        return copy
    }

    /// Strips an overlay that belongs to a different display.
    public func routed(to displayID: CGDirectDisplayID) -> IslandLayoutDescriptor {
        guard let overlayDisplayID, overlayDisplayID != displayID else { return self }
        var copy = self
        copy.overlay = nil
        copy.overlayKey = nil
        copy.overlayDisplayID = nil
        return copy
    }
}

/// Which island a given display draws. Shared by the window controller (hit
/// testing) and the root view (drawing) so the two can never disagree.
public enum IslandDisplayPolicy {
    public static func activity(
        for descriptor: IslandLayoutDescriptor,
        displayID: CGDirectDisplayID,
        isActiveDisplay: Bool,
        mirrorsPassiveContext: Bool
    ) -> NotchActivity {
        if isActiveDisplay {
            return .island(descriptor.routed(to: displayID))
        }
        // A display-specific burst (brightness) still shows where it happened.
        if let overlayDisplayID = descriptor.overlayDisplayID, overlayDisplayID == displayID {
            var routed = descriptor
            routed.level = .compact
            return .island(routed)
        }
        guard let kind = descriptor.primaryKind else { return .idle }
        let mirrors: Bool = switch kind {
        case .media: true
        // A capture state belongs to the display being worked on.
        case .recording: false
        case .ai, .timer, .calendar, .transfer, .external, .voiceNote: mirrorsPassiveContext
        }
        return mirrors ? .island(descriptor.restingCopy()) : .idle
    }
}

public struct IslandEngineConfiguration: Sendable, Equatable {
    /// 1 disables satellites entirely.
    public var maximumVisibleActivities: Int
    /// Whether hover-peeking may present the primary at its expanded level.
    public var expandsOnHover: Bool

    public init(maximumVisibleActivities: Int = 3, expandsOnHover: Bool = true) {
        self.maximumVisibleActivities = min(3, max(1, maximumVisibleActivities))
        self.expandsOnHover = expandsOnHover
    }
}

public struct IslandSyncResult: Sendable, Equatable {
    public var inserted: [IslandActivityID] = []
    public var removed: [IslandActivityID] = []
    /// Activities whose lifecycle changed — the events worth a transition.
    public var lifecycleChanged: [IslandActivityID] = []

    public var isStructural: Bool {
        !inserted.isEmpty || !removed.isEmpty || !lifecycleChanged.isEmpty
    }
}

/// Resolves which activities the island shows, and where.
///
/// Pure value type: no timers, no UI, no singletons. Callers feed it the
/// current activity set, user intent (select, expand) and the clock, and get a
/// deterministic presentation back. Every rule below is pinned by
/// `IslandPresentationEngineTests`.
///
/// Primary selection, in order:
/// 1. A user selection wins — unless a `.pinned` activity (a recording)
///    arrived *after* the user chose.
/// 2. Otherwise the earliest-arrived `.pinned` activity.
/// 3. Otherwise the previous primary, while nothing of higher priority exists
///    (hysteresis: relevance never flips a settled primary).
/// 4. Otherwise the best by priority, then relevance, then arrival.
///    `.passive` activities are only candidates when nothing else is live.
///
/// Satellite slots are sticky: an activity keeps its side while visible, and a
/// promoted satellite trades places with the primary it replaced, so the
/// activities physically swap instead of reshuffling.
public struct IslandPresentationEngine: Sendable {
    public private(set) var activities: [IslandActivityID: IslandActivity] = [:]
    public private(set) var selectedID: IslandActivityID?
    public private(set) var expandedID: IslandActivityID?
    public private(set) var lastPrimaryID: IslandActivityID?

    private var arrival: [IslandActivityID: UInt64] = [:]
    private var arrivalCounter: UInt64 = 0
    private var selectionArrivalMark: UInt64 = 0
    private var slots: [IslandActivityID: IslandSlot] = [:]
    private var lastArrivalEdge: IslandSlot?

    public init() {}

    // MARK: Activity set

    /// Replaces the whole activity set with the sources' current view.
    @discardableResult
    public mutating func sync(_ incoming: [IslandActivity], now: Date) -> IslandSyncResult {
        var result = IslandSyncResult()
        var seen = Set<IslandActivityID>()
        for activity in incoming where !activity.isExpired(at: now) {
            guard seen.insert(activity.id).inserted else { continue }
            if let existing = activities[activity.id] {
                if existing.lifecycle != activity.lifecycle {
                    result.lifecycleChanged.append(activity.id)
                }
                activities[activity.id] = activity
            } else {
                insert(activity)
                result.inserted.append(activity.id)
            }
        }
        for id in activities.keys where !seen.contains(id) {
            forget(id)
            result.removed.append(id)
        }
        result.removed.sort { $0.description < $1.description }
        return result
    }

    public mutating func upsert(_ activity: IslandActivity) {
        if activities[activity.id] == nil {
            insert(activity)
        } else {
            activities[activity.id] = activity
        }
    }

    public mutating func remove(_ id: IslandActivityID) {
        forget(id)
    }

    @discardableResult
    public mutating func removeExpired(now: Date) -> [IslandActivityID] {
        let expired = activities.values.filter { $0.isExpired(at: now) }.map(\.id)
        for id in expired { forget(id) }
        return expired
    }

    /// Earliest moment an activity leaves on its own, for scheduling one wake.
    public var nextExpiry: Date? {
        activities.values.compactMap(\.expiresAt).min()
    }

    // MARK: User intent

    /// Makes an activity primary. Returns `false` for an unknown or expired one.
    @discardableResult
    public mutating func select(_ id: IslandActivityID, expand: Bool = false, now: Date = Date()) -> Bool {
        guard let activity = activities[id], !activity.isExpired(at: now) else { return false }
        selectedID = id
        selectionArrivalMark = arrivalCounter
        if expand {
            expandedID = id
        } else if expandedID != nil, expandedID != id {
            // Swiping while expanded carries the expansion to the new primary.
            expandedID = id
        }
        return true
    }

    /// Selects the satellite in `direction` of the given presentation.
    @discardableResult
    public mutating func selectNeighbor(
        _ direction: IslandNavigationDirection,
        in presentation: IslandPresentation,
        now: Date = Date()
    ) -> IslandActivityID? {
        guard let target = presentation.neighbor(direction) else { return nil }
        return select(target.id, now: now) ? target.id : nil
    }

    public mutating func expand(_ id: IslandActivityID) {
        guard activities[id] != nil else { return }
        expandedID = id
        lastArrivalEdge = nil
    }

    public mutating func collapse() {
        expandedID = nil
        lastArrivalEdge = nil
    }

    public mutating func clearSelection() {
        selectedID = nil
    }

    // MARK: Resolution

    /// Resolves the presentation and commits slot memory for the next call.
    public mutating func present(
        configuration: IslandEngineConfiguration = IslandEngineConfiguration(),
        isHoverPreviewing: Bool = false,
        overlay: IslandOverlay? = nil,
        now: Date
    ) -> IslandPresentation {
        removeExpired(now: now)
        let live = Array(activities.values)
        guard !live.isEmpty else {
            lastPrimaryID = nil
            selectedID = nil
            expandedID = nil
            slots.removeAll()
            return IslandPresentation(transientOverlay: overlay)
        }

        let primary = resolvePrimary(from: live)
        let previousPrimaryID = lastPrimaryID
        lastPrimaryID = primary.id

        if expandedID != nil, expandedID != primary.id {
            expandedID = nil
        }

        var others = live.filter { $0.id != primary.id }
        others.sort(by: rankedBefore)
        let satelliteCapacity = configuration.maximumVisibleActivities - 1
        let visibleSecondary = Array(others.prefix(max(0, satelliteCapacity)))
        let hiddenCount = others.count - visibleSecondary.count

        let arrivalEdge: IslandSlot? = previousPrimaryID != primary.id ? slots[primary.id] : lastArrivalEdge
        lastArrivalEdge = arrivalEdge

        // A promoted satellite hands its side to the primary it replaced.
        if let previousPrimaryID,
           previousPrimaryID != primary.id,
           let vacated = slots[primary.id],
           visibleSecondary.contains(where: { $0.id == previousPrimaryID }) {
            slots[previousPrimaryID] = vacated
        }
        slots[primary.id] = nil

        let visibleIDs = Set(visibleSecondary.map(\.id))
        slots = slots.filter { visibleIDs.contains($0.key) }
        // Two activities cannot share a side; the better-ranked keeps it.
        var taken: [IslandSlot: IslandActivityID] = [:]
        for activity in visibleSecondary {
            guard let slot = slots[activity.id] else { continue }
            if taken[slot] == nil {
                taken[slot] = activity.id
            } else {
                slots[activity.id] = nil
            }
        }
        for activity in visibleSecondary where slots[activity.id] == nil {
            let free = IslandSlot.allCases.first { taken[$0] == nil }
            guard let free else { break }
            slots[activity.id] = free
            taken[free] = activity.id
        }

        let level: IslandPresentationLevel
        if expandedID == primary.id {
            level = .expanded
        } else if isHoverPreviewing, configuration.expandsOnHover {
            level = .expanded
        } else {
            level = .compact
        }
        // The arrival side describes one promotion. Once the level changes,
        // the next content swap is a level change, not a sideways arrival.
        if level != .compact {
            lastArrivalEdge = nil
        }

        return IslandPresentation(
            primary: primary,
            leading: taken[.leading].flatMap { activities[$0] },
            trailing: taken[.trailing].flatMap { activities[$0] },
            level: level,
            expandedActivityID: expandedID,
            transientOverlay: overlay,
            hiddenCount: hiddenCount,
            primaryArrivalEdge: level == .compact ? arrivalEdge : nil
        )
    }

    // MARK: Internals

    private mutating func insert(_ activity: IslandActivity) {
        arrivalCounter &+= 1
        arrival[activity.id] = arrivalCounter
        activities[activity.id] = activity
    }

    private mutating func forget(_ id: IslandActivityID) {
        activities[id] = nil
        arrival[id] = nil
        slots[id] = nil
        if selectedID == id { selectedID = nil }
        if expandedID == id { expandedID = nil }
    }

    private mutating func resolvePrimary(from live: [IslandActivity]) -> IslandActivity {
        let pinned = live
            .filter { $0.interruptionPolicy == .pinned }
            .sorted { order(of: $0) < order(of: $1) }

        if let selectedID, let selected = activities[selectedID] {
            let interruptedBy = pinned.first {
                $0.id != selectedID && order(of: $0) > selectionArrivalMark
            }
            if interruptedBy == nil { return selected }
            self.selectedID = nil
        }

        if let firstPinned = pinned.first { return firstPinned }

        let hasNonPassive = live.contains { $0.interruptionPolicy != .passive }
        let candidates = hasNonPassive
            ? live.filter { $0.interruptionPolicy != .passive }
            : live
        let best = candidates.sorted(by: rankedBefore)[0]

        if let lastPrimaryID,
           let previous = candidates.first(where: { $0.id == lastPrimaryID }),
           previous.priority >= best.priority {
            return previous
        }
        return best
    }

    private func order(of activity: IslandActivity) -> UInt64 {
        arrival[activity.id] ?? .max
    }

    private func rankedBefore(_ lhs: IslandActivity, _ rhs: IslandActivity) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
        if lhs.relevance != rhs.relevance { return lhs.relevance > rhs.relevance }
        return order(of: lhs) < order(of: rhs)
    }
}
