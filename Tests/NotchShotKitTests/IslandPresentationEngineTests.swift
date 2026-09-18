import Foundation
import Testing
@testable import NotchShotKit

/// Pins the multi-activity island rules: one primary, up to two sticky
/// satellites, user selection, pinned interruptions, and expiry.
@Suite("Island presentation engine")
struct IslandPresentationEngineTests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)

    static func activity(
        _ kind: IslandActivityKind,
        _ key: String = "a",
        priority: IslandPriority = .normal,
        relevance: Double = 0.5,
        lifecycle: IslandLifecycle = .active,
        progress: IslandProgress = .none,
        policy: IslandInterruptionPolicy = .standard,
        expiresAt: Date? = nil,
        metric: String? = nil
    ) -> IslandActivity {
        IslandActivity(
            id: IslandActivityID(kind: kind, key: key),
            priority: priority,
            relevance: relevance,
            lifecycle: lifecycle,
            progress: progress,
            startedAt: t0,
            interruptionPolicy: policy,
            expiresAt: expiresAt,
            title: kind.title,
            metric: metric,
            symbolName: "circle"
        )
    }

    static let media = activity(.media, "now-playing")
    static let timer = activity(.timer, "focus")
    static let codex = activity(.ai, "agents", progress: .determinate(0.41), metric: "41%")
    static let transfer = activity(.transfer, "t1", progress: .determinate(0.2))
    static let recording = activity(.recording, "screen", priority: .critical, relevance: 1, policy: .pinned)

    private func present(
        _ engine: inout IslandPresentationEngine,
        _ activities: [IslandActivity],
        now: Date = t0,
        maximum: Int = 3,
        hover: Bool = false,
        overlay: IslandOverlay? = nil
    ) -> IslandPresentation {
        engine.sync(activities, now: now)
        return engine.present(
            configuration: IslandEngineConfiguration(maximumVisibleActivities: maximum),
            isHoverPreviewing: hover,
            overlay: overlay,
            now: now
        )
    }

    // MARK: One activity

    @Test("A single activity becomes a compact primary with no satellites",
          arguments: [media, timer, recording, codex])
    func singleActivity(_ activity: IslandActivity) {
        var engine = IslandPresentationEngine()
        let result = present(&engine, [activity])
        #expect(result.primary?.id == activity.id)
        #expect(result.secondary.isEmpty)
        #expect(result.level == .compact)
        #expect(result.descriptor().satelliteCount == 0)
    }

    @Test("An empty engine presents nothing but can still carry an overlay")
    func emptyWithOverlay() {
        var engine = IslandPresentationEngine()
        let event = IslandTransientEvent(kind: .focus, symbolName: "moon.fill", title: "Focus On", createdAt: Self.t0)
        let result = present(&engine, [], overlay: .event(event))
        #expect(result.primary == nil)
        #expect(result.transientOverlay == .event(event))
        #expect(!result.isEmpty)
    }

    // MARK: Two activities

    @Test("The earlier activity stays primary when a second arrives",
          arguments: [(media, timer), (media, codex), (media, transfer)])
    func twoActivities(_ pair: (IslandActivity, IslandActivity)) {
        var engine = IslandPresentationEngine()
        _ = present(&engine, [pair.0])
        let result = present(&engine, [pair.0, pair.1])
        #expect(result.primary?.id == pair.0.id)
        #expect(result.leading?.id == pair.1.id)
        #expect(result.trailing == nil)
    }

    @Test("A recording takes the primary slot from media and media becomes a satellite")
    func recordingPlusMedia() {
        var engine = IslandPresentationEngine()
        _ = present(&engine, [Self.media])
        let result = present(&engine, [Self.media, Self.recording])
        #expect(result.primary?.id == Self.recording.id)
        #expect(result.secondary.map(\.id) == [Self.media.id])
    }

    // MARK: Three activities

    @Test("Three activities fill primary, leading, trailing in arrival order")
    func threeActivities() {
        var engine = IslandPresentationEngine()
        _ = present(&engine, [Self.media])
        _ = present(&engine, [Self.media, Self.timer])
        let result = present(&engine, [Self.media, Self.timer, Self.codex])
        #expect(result.primary?.id == Self.media.id)
        #expect(result.leading?.id == Self.timer.id)
        #expect(result.trailing?.id == Self.codex.id)
        #expect(result.visibleActivities.map(\.id) == [Self.timer.id, Self.media.id, Self.codex.id])
    }

    @Test("A fourth activity is counted as hidden instead of displacing a slot")
    func overflowIsHidden() {
        var engine = IslandPresentationEngine()
        _ = present(&engine, [Self.media, Self.transfer, Self.timer])
        let result = present(&engine, [Self.media, Self.transfer, Self.timer, Self.codex])
        #expect(result.primary?.id == Self.media.id)
        #expect(result.secondary.count == 2)
        #expect(result.hiddenCount == 1)
    }

    @Test("Limiting visible activities to one removes satellites")
    func maximumOne() {
        var engine = IslandPresentationEngine()
        let result = present(&engine, [Self.media, Self.timer, Self.codex], maximum: 1)
        #expect(result.primary?.id == Self.media.id)
        #expect(result.secondary.isEmpty)
        #expect(result.hiddenCount == 2)
    }

    @Test("Limiting visible activities to two keeps a single satellite")
    func maximumTwo() {
        var engine = IslandPresentationEngine()
        let result = present(&engine, [Self.media, Self.timer, Self.codex], maximum: 2)
        #expect(result.secondary.count == 1)
    }

    // MARK: Priority

    @Test("A passive event never displaces a recording, even via relevance")
    func recordingIsNotDisplaced() {
        var engine = IslandPresentationEngine()
        _ = present(&engine, [Self.recording])
        let passive = Self.activity(.calendar, "upcoming", priority: .passive, relevance: 1, policy: .passive)
        let urgentAgent = Self.activity(.ai, "agents", priority: .elevated, relevance: 1)
        let result = present(&engine, [Self.recording, passive, urgentAgent])
        #expect(result.primary?.id == Self.recording.id)
    }

    @Test("A later recording interrupts a user selection; an earlier one does not")
    func pinnedInterruptsSelection() {
        var engine = IslandPresentationEngine()
        _ = present(&engine, [Self.media, Self.timer])
        let result1 = engine.select(Self.timer.id, now: Self.t0)
        #expect(result1)
        #expect(present(&engine, [Self.media, Self.timer]).primary?.id == Self.timer.id)

        let result = present(&engine, [Self.media, Self.timer, Self.recording])
        #expect(result.primary?.id == Self.recording.id)

        // Now the user deliberately picks media over the running recording.
        let result2 = engine.select(Self.media.id, now: Self.t0)
        #expect(result2)
        let chosen = present(&engine, [Self.media, Self.timer, Self.recording])
        #expect(chosen.primary?.id == Self.media.id)
        #expect(chosen.secondary.contains { $0.id == Self.recording.id },
                "the recording stays visible as a satellite")
    }

    @Test("Passive activities only lead when nothing else is live")
    func passiveWaits() {
        var engine = IslandPresentationEngine()
        let calendar = Self.activity(.calendar, "upcoming", priority: .passive, policy: .passive)
        #expect(present(&engine, [calendar]).primary?.id == calendar.id)
        let result = present(&engine, [calendar, Self.timer])
        #expect(result.primary?.id == Self.timer.id)
        #expect(result.leading?.id == calendar.id)
    }

    @Test("An agent that needs attention takes the primary slot; relevance alone never flips it back")
    func elevatedTakesPrimaryWithHysteresis() {
        var engine = IslandPresentationEngine()
        _ = present(&engine, [Self.media, Self.codex])
        let waiting = Self.activity(.ai, "agents", priority: .elevated, relevance: 1, lifecycle: .waiting)
        #expect(present(&engine, [Self.media, waiting]).primary?.id == waiting.id)

        // Back to ordinary work: same priority as media now, so it stays put.
        #expect(present(&engine, [Self.media, Self.codex]).primary?.id == Self.codex.id)
    }

    @Test("A more relevant ordinary arrival does not steal a settled primary")
    func relevanceDoesNotSteal() {
        var engine = IslandPresentationEngine()
        _ = present(&engine, [Self.media])
        let relevantTimer = Self.activity(.timer, "focus", relevance: 0.95)
        #expect(present(&engine, [Self.media, relevantTimer]).primary?.id == Self.media.id)
    }

    // MARK: Lifecycle

    @Test("An update keeps the same identity and position")
    func updateKeepsIdentity() {
        var engine = IslandPresentationEngine()
        _ = present(&engine, [Self.media, Self.timer, Self.codex])
        var progressed = Self.codex
        progressed.progress = .determinate(0.42)
        progressed.metric = "42%"
        let sync = engine.sync([Self.media, Self.timer, progressed], now: Self.t0)
        #expect(!sync.isStructural)
        let result = engine.present(now: Self.t0)
        #expect(result.trailing?.id == Self.codex.id)
        #expect(result.trailing?.metric == "42%")
    }

    @Test("Finishing removes the activity and the next eligible one becomes primary")
    func primaryFinishingPromotesNext() {
        var engine = IslandPresentationEngine()
        _ = present(&engine, [Self.media, Self.timer])
        let result = present(&engine, [Self.timer])
        #expect(result.primary?.id == Self.timer.id)
        #expect(result.secondary.isEmpty)
    }

    @Test("A stale activity expires and leaves on its own")
    func staleExpires() {
        var engine = IslandPresentationEngine()
        let expiring = Self.activity(.external, "build", expiresAt: Self.t0.addingTimeInterval(5))
        _ = present(&engine, [Self.media, expiring])
        #expect(engine.nextExpiry == Self.t0.addingTimeInterval(5))
        let later = engine.present(now: Self.t0.addingTimeInterval(6))
        #expect(later.visibleActivities.map(\.id) == [Self.media.id])
    }

    @Test("An already expired activity is never inserted")
    func expiredNotInserted() {
        var engine = IslandPresentationEngine()
        let expired = Self.activity(.external, "old", expiresAt: Self.t0.addingTimeInterval(-1))
        let sync = engine.sync([expired], now: Self.t0)
        #expect(sync.inserted.isEmpty)
        #expect(engine.activities.isEmpty)
    }

    @Test("Lifecycle changes are reported as structural")
    func lifecycleIsStructural() {
        var engine = IslandPresentationEngine()
        engine.sync([Self.codex], now: Self.t0)
        var finished = Self.codex
        finished.lifecycle = .succeeded
        #expect(engine.sync([finished], now: Self.t0).lifecycleChanged == [Self.codex.id])
    }

    // MARK: Selection and slots

    @Test("Promoting a satellite swaps it with the primary; the other satellite stays")
    func promotionSwapsSlots() {
        var engine = IslandPresentationEngine()
        _ = present(&engine, [Self.media])
        _ = present(&engine, [Self.media, Self.timer])
        let before = present(&engine, [Self.media, Self.timer, Self.codex])
        let result3 = engine.selectNeighbor(.trailing, in: before, now: Self.t0)
        #expect((result3 == Self.codex.id))
        let after = engine.present(now: Self.t0)
        #expect(after.primary?.id == Self.codex.id)
        #expect(after.trailing?.id == Self.media.id)
        #expect(after.leading?.id == Self.timer.id)
    }

    @Test("Selecting an unknown or expired activity is refused")
    func invalidSelection() {
        var engine = IslandPresentationEngine()
        _ = present(&engine, [Self.media])
        let result4 = engine.select(Self.timer.id, now: Self.t0)
        #expect(!(result4))
    }

    @Test("Clicking a satellite promotes and expands it; expansion follows only the primary")
    func clickPromotesAndExpands() {
        var engine = IslandPresentationEngine()
        _ = present(&engine, [Self.media, Self.timer])
        let result5 = engine.select(Self.timer.id, expand: true, now: Self.t0)
        #expect(result5)
        let result = engine.present(now: Self.t0)
        #expect(result.primary?.id == Self.timer.id)
        #expect(result.level == .expanded)

        // A recording arriving takes over; the stale expansion must not
        // resurface later on the timer.
        _ = present(&engine, [Self.media, Self.timer, Self.recording])
        #expect(engine.expandedID == nil)
    }

    @Test("Hover previewing expands only when configured to")
    func hoverExpansion() {
        var engine = IslandPresentationEngine()
        engine.sync([Self.media], now: Self.t0)
        let hover = engine.present(
            configuration: IslandEngineConfiguration(expandsOnHover: true),
            isHoverPreviewing: true,
            now: Self.t0
        )
        #expect(hover.level == .expanded)
        let noHover = engine.present(
            configuration: IslandEngineConfiguration(expandsOnHover: false),
            isHoverPreviewing: true,
            now: Self.t0
        )
        #expect(noHover.level == .compact)
    }

    // MARK: Transient overlays

    @Test("A transient overlay leaves the primary and satellites intact")
    func overlayKeepsPrimary() {
        var engine = IslandPresentationEngine()
        _ = present(&engine, [Self.media, Self.timer, Self.codex])
        let level = SystemLevel(kind: .volume, value: 0.4, isMuted: false)
        let during = present(&engine, [Self.media, Self.timer, Self.codex], overlay: .systemLevel(level))
        #expect(during.primary?.id == Self.media.id)
        #expect(during.transientOverlay == .systemLevel(level))
        #expect(!during.descriptor().showsSatellites, "satellites step aside during a burst")
        let after = present(&engine, [Self.media, Self.timer, Self.codex])
        #expect(after.primary?.id == Self.media.id)
        #expect(after.leading?.id == Self.timer.id)
        #expect(after.trailing?.id == Self.codex.id)
    }

    // MARK: Identity

    @Test("Live progress, timer ticks and metrics never change the structural identity")
    func liveDataKeepsIdentity() {
        var engine = IslandPresentationEngine()
        let first = present(&engine, [Self.media, Self.timer, Self.codex]).descriptor()
        var ticked = Self.timer
        ticked.metric = "04:30"
        ticked.progress = .determinate(0.51)
        var progressed = Self.codex
        progressed.progress = .determinate(0.42)
        let second = present(&engine, [Self.media, ticked, progressed]).descriptor()
        #expect(first == second)
        #expect(NotchActivity.island(first).presentationIdentity == NotchActivity.island(second).presentationIdentity)
    }

    @Test("Volume value changes do not change the overlay identity")
    func overlayValueKeepsIdentity() {
        var engine = IslandPresentationEngine()
        let a = present(&engine, [Self.media], overlay: .systemLevel(SystemLevel(kind: .volume, value: 0.2, isMuted: false)))
        let b = present(&engine, [Self.media], overlay: .systemLevel(SystemLevel(kind: .volume, value: 0.7, isMuted: false)))
        #expect(a.descriptor() == b.descriptor())
    }

    @Test("Compact to expanded changes the presentation identity")
    func expansionChangesIdentity() {
        var engine = IslandPresentationEngine()
        let compact = present(&engine, [Self.media]).descriptor()
        engine.expand(Self.media.id)
        let expanded = engine.present(now: Self.t0).descriptor()
        #expect(compact != expanded)
        #expect(NotchActivity.island(compact).presentationIdentity != NotchActivity.island(expanded).presentationIdentity)
    }

    @Test("Promotion changes positions but keeps every activity's identity")
    func promotionKeepsIDs() {
        var engine = IslandPresentationEngine()
        let before = present(&engine, [Self.media, Self.timer, Self.codex])
        engine.select(Self.codex.id, now: Self.t0)
        let after = engine.present(now: Self.t0)
        #expect(Set(before.visibleActivities.map(\.id)) == Set(after.visibleActivities.map(\.id)))
        #expect(before.descriptor() != after.descriptor())
    }

    // MARK: Acceptance scenario

    @Test("Music, timer, Codex, swipe, volume, finish, click: the full acceptance scenario")
    func acceptanceScenario() {
        var engine = IslandPresentationEngine()
        var now = Self.t0

        // Music plays.
        var state = present(&engine, [Self.media], now: now)
        #expect(state.primary?.id == Self.media.id)

        // 45-minute timer starts.
        let timer = Self.activity(.timer, "focus-45", metric: "45:00")
        state = present(&engine, [Self.media, timer], now: now)
        #expect(state.primary?.id == Self.media.id)
        #expect(state.secondary.map(\.id) == [timer.id])

        // Codex starts.
        var codex = Self.activity(.ai, "agents", progress: .determinate(0.41), metric: "41%")
        state = present(&engine, [Self.media, timer, codex], now: now)
        #expect(state.leading?.id == timer.id)
        #expect(state.trailing?.id == codex.id)

        // Swipe toward Codex.
        let result6 = engine.selectNeighbor(.trailing, in: state, now: now)
        #expect((result6 == codex.id))
        state = engine.present(now: now)
        #expect(state.primary?.id == codex.id)
        #expect(state.trailing?.id == Self.media.id)
        #expect(state.leading?.id == timer.id)
        let afterSwipe = state.descriptor()

        // 41% → 42%: nothing structural moves.
        codex.progress = .determinate(0.42)
        codex.metric = "42%"
        state = present(&engine, [Self.media, timer, codex], now: now)
        #expect(state.descriptor() == afterSwipe)

        // Volume HUD comes and goes; Codex stays selected.
        let volume = SystemLevel(kind: .volume, value: 0.6, isMuted: false)
        state = present(&engine, [Self.media, timer, codex], now: now, overlay: .systemLevel(volume))
        #expect(state.primary?.id == codex.id)
        state = present(&engine, [Self.media, timer, codex], now: now)
        #expect(state.descriptor() == afterSwipe)

        // Codex reaches 100% and succeeds, briefly.
        codex.progress = .determinate(1)
        codex.lifecycle = .succeeded
        codex.expiresAt = now.addingTimeInterval(IslandActivityAdapters.successLinger)
        state = present(&engine, [Self.media, timer, codex], now: now)
        #expect(state.primary?.id == codex.id)
        #expect(state.primary?.lifecycle == .succeeded)

        // …then leaves; music and timer settle.
        now = now.addingTimeInterval(3)
        state = present(&engine, [Self.media, timer, codex], now: now)
        #expect(state.primary?.id == Self.media.id)
        #expect(state.leading?.id == timer.id)
        #expect(state.trailing == nil)

        // Clicking the timer makes it primary and expands it.
        let result7 = engine.select(timer.id, expand: true, now: now)
        #expect(result7)
        state = engine.present(now: now)
        #expect(state.primary?.id == timer.id)
        #expect(state.level == .expanded)
        #expect(state.leading?.id == Self.media.id)
    }
}

@Suite("Island engine transitions")
struct IslandEngineTransitionTests {
    @Test("The arrival edge describes a promotion only, never a later level change")
    func arrivalEdge() {
        let t0 = IslandPresentationEngineTests.t0
        var engine = IslandPresentationEngine()
        engine.sync([IslandPresentationEngineTests.media, IslandPresentationEngineTests.timer], now: t0)
        let first = engine.present(now: t0)
        #expect(first.primaryArrivalEdge == nil)
        let selected = engine.select(IslandPresentationEngineTests.timer.id, now: t0)
        #expect(selected)
        let promoted = engine.present(now: t0)
        #expect(promoted.primaryArrivalEdge == .leading)
        engine.expand(IslandPresentationEngineTests.timer.id)
        #expect(engine.present(now: t0).primaryArrivalEdge == nil)
        engine.collapse()
        #expect(engine.present(now: t0).primaryArrivalEdge == nil)
    }

    @Test("A completed timer lingers from its published expiry instead of forever")
    func completedTimerExpires() {
        let t0 = IslandPresentationEngineTests.t0
        let timer = FocusTimerSnapshot(label: "Focus", state: .completed, duration: 60, elapsed: 60, startedAt: t0)
        let expiry = t0.addingTimeInterval(72)
        let early = IslandActivityAdapters.timer(timer, expiresAt: expiry, now: t0.addingTimeInterval(61))
        let late = IslandActivityAdapters.timer(timer, expiresAt: expiry, now: t0.addingTimeInterval(500))
        #expect(early.expiresAt == late.expiresAt)
        #expect(late.isExpired(at: t0.addingTimeInterval(500)))
    }
}
