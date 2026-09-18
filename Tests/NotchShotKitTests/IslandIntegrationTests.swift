import CoreGraphics
import Foundation
import NotchShotAIReporterSupport
import Testing
@testable import NotchShotKit

@Suite("Island adapters")
struct IslandAdapterTests {
    static let t0 = Date(timeIntervalSince1970: 4_000_000)

    @Test("Media keeps one identity across track changes")
    func mediaIdentity() {
        let first = MediaSnapshot(source: .mediaRemote, title: "One", isPlaying: true)
        let second = MediaSnapshot(source: .mediaRemote, title: "Two", isPlaying: false)
        let a = IslandActivityAdapters.media(first, startedAt: Self.t0)
        let b = IslandActivityAdapters.media(second, startedAt: Self.t0)
        #expect(a?.id == b?.id)
        #expect(b?.lifecycle == .paused)
        #expect(IslandActivityAdapters.media(MediaSnapshot(), startedAt: Self.t0) == nil)
    }

    @Test("A recording is critical and pinned; pausing does not change its identity")
    func recording() {
        let running = IslandActivityAdapters.recording(status: RecordingStatus(), isPaused: false, startedAt: Self.t0)
        let paused = IslandActivityAdapters.recording(status: RecordingStatus(), isPaused: true, startedAt: Self.t0)
        #expect(running.priority == .critical)
        #expect(running.interruptionPolicy == .pinned)
        #expect(running.id == paused.id)
        #expect(paused.lifecycle == .paused)
    }

    @Test("Timer ticks keep identity; progress is the real elapsed fraction")
    func timer() {
        var timer = FocusTimerSnapshot(label: "Focus", state: .running, duration: 45 * 60, elapsed: 30, startedAt: Self.t0)
        let a = IslandActivityAdapters.timer(timer, now: Self.t0)
        timer.elapsed = 31
        let b = IslandActivityAdapters.timer(timer, now: Self.t0)
        #expect(a.id == b.id)
        #expect(a.metric != b.metric)
        #expect(b.progress.fraction == 31.0 / (45 * 60))
    }

    @Test("Agents fold into one activity; a waiting agent elevates it; progress is never invented")
    func agents() {
        let working = AIActivitySnapshot(id: "1", source: .codex, state: .working, title: "Fix export", updatedAt: Self.t0)
        let activity = IslandActivityAdapters.ai([working], now: Self.t0)
        #expect(activity?.progress == .indeterminate)
        #expect(activity?.metric == nil)

        var measured = working
        measured.progress = 0.41
        #expect(IslandActivityAdapters.ai([measured], now: Self.t0)?.metric == "41%")

        let waiting = AIActivitySnapshot(id: "2", source: .claude, state: .waiting, title: "Approve", updatedAt: Self.t0)
        let both = IslandActivityAdapters.ai([measured, waiting], now: Self.t0)
        #expect(both?.priority == .elevated)
        #expect(both?.lifecycle == .waiting)
        #expect(both?.requiresPersistentInteraction == true)
        #expect(both?.id == activity?.id)
    }

    @Test("Finished agents briefly succeed, then expire")
    func agentsFinish() {
        let done = AIActivitySnapshot(id: "1", source: .codex, state: .finished, title: "Done", progress: 1, updatedAt: Self.t0)
        let activity = IslandActivityAdapters.ai([done], now: Self.t0)
        #expect(activity?.lifecycle == .succeeded)
        #expect(activity?.progress == .determinate(1))
        #expect(activity?.expiresAt == Self.t0.addingTimeInterval(IslandActivityAdapters.successLinger))
    }

    @Test("Transfers show only measured progress; AirDrop is indeterminate")
    func transfers() {
        var localSend = TransferActivitySnapshot(
            id: UUID(), service: .localSend, direction: .outgoing, peerName: "Phone",
            fileCount: 2, completedFiles: 0, currentFilename: nil,
            bytesTransferred: 250, totalBytes: 1_000, bytesPerSecond: nil, estimatedCompletion: nil,
            state: .transferring, startedAt: Self.t0, updatedAt: Self.t0, finishedAt: nil,
            errorMessage: nil, canCancel: true
        )
        let activity = IslandActivityAdapters.transfer(localSend)
        #expect(activity.progress == .determinate(0.25))
        #expect(activity.actions == [.cancel])

        localSend.service = .airDrop
        localSend.bytesTransferred = nil
        localSend.totalBytes = nil
        #expect(IslandActivityAdapters.transfer(localSend).progress == .indeterminate)
    }

    @Test("External urgency maps to priority without granting pinned status")
    func external() {
        var registry = ExternalActivityRegistry()
        registry.apply(LiveActivityUpdate(command: .start, id: "x", title: "X", urgency: .important), now: Self.t0)
        let important = IslandActivityAdapters.external(registry.live[0])
        #expect(important.priority == .elevated)
        #expect(important.interruptionPolicy != .pinned)
        #expect(important.kind == .external)
        #expect(important.progress == .indeterminate)
    }

    @Test("A transfer rate needs real samples spanning enough time")
    func rateEstimator() {
        var estimator = TransferRateEstimator()
        estimator.record(bytes: 0, at: 0)
        #expect(estimator.rate == nil)
        estimator.record(bytes: 500, at: 0.2)
        #expect(estimator.rate == nil, "too short a span to trust")
        estimator.record(bytes: 1_000, at: 1)
        #expect(estimator.rate == 1_000)
        #expect(estimator.estimatedSecondsRemaining(total: 3_000) == 2)
        estimator.record(bytes: 10, at: 2)
        #expect(estimator.rate == nil, "a counter reset starts over")
    }
}

@Suite("Island layout and routing")
struct IslandLayoutTests {
    static let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    static let notched = NotchMetrics(screenFrame: screen, hasPhysicalNotch: true, notchSize: CGSize(width: 200, height: 32), menuBarHeight: 32)
    static let external = NotchMetrics(screenFrame: screen, hasPhysicalNotch: false, notchSize: NotchMetrics.syntheticIslandSize, menuBarHeight: 25)

    static let media = IslandActivityID(kind: .media, key: "now-playing")
    static let timer = IslandActivityID(kind: .timer, key: "t")
    static let agents = IslandActivityID(kind: .ai, key: "agents")

    private func layout(_ descriptor: IslandLayoutDescriptor, _ metrics: NotchMetrics = notched) -> NotchLayout {
        NotchLayout.layout(for: .island(descriptor), metrics: metrics, isPeeking: false, resultCount: 0)
    }

    @Test("Compact wings keep content clear of the physical camera cutout")
    func compactRespectsCutout() {
        let compact = layout(IslandLayoutDescriptor(primaryID: Self.media))
        #expect(compact.size.width > Self.notched.notchSize.width)
        #expect(compact.contentTopInset == 0)
        for kind in IslandActivityKind.allCases {
            #expect(NotchLayout.compactIslandWing(for: kind) >= 36, "every wing can hold a glyph")
        }
    }

    @Test("Expanded content is laid out below the camera band")
    func expandedBelowCamera() {
        let expanded = layout(IslandLayoutDescriptor(primaryID: Self.timer, level: .expanded))
        #expect(expanded.contentTopInset == Self.notched.notchSize.height)
        #expect(expanded.size.height <= NotchLayout.maximumSize.height)
    }

    @Test("Satellites extend the hit region but not the hover trigger")
    func satellitesHitRegion() {
        let descriptor = IslandLayoutDescriptor(primaryID: Self.media, leadingID: Self.timer, trailingID: Self.agents)
        let withSatellites = layout(descriptor)
        let alone = layout(IslandLayoutDescriptor(primaryID: Self.media))
        #expect(withSatellites.size == alone.size, "satellites never resize the primary shell")
        #expect(withSatellites.satelliteDiameter > 0)
        #expect(withSatellites.islandRect(in: Self.notched).width > withSatellites.primaryRect(in: Self.notched).width)
        #expect(withSatellites.satelliteExtent >= withSatellites.satelliteDiameter / 2 + NotchShotDesignSystem.minimumControlTarget / 2)
        let trigger = NotchWindowController.triggerZone(
            notchRect: Self.notched.notchRect,
            restingIsland: withSatellites.primaryRect(in: Self.notched),
            isExpanded: false
        )
        let satelliteCenter = CGPoint(
            x: withSatellites.primaryRect(in: Self.notched).maxX + withSatellites.satelliteSpacing + withSatellites.satelliteDiameter / 2,
            y: Self.notched.notchRect.midY
        )
        #expect(!trigger.contains(satelliteCenter))
        #expect(withSatellites.islandRect(in: Self.notched).contains(satelliteCenter))
    }

    @Test("Satellites step aside while expanded or during a burst")
    func satellitesHide() {
        let expanded = layout(IslandLayoutDescriptor(primaryID: Self.media, level: .expanded, leadingID: Self.timer))
        #expect(expanded.satelliteDiameter == 0)
        let burst = layout(IslandLayoutDescriptor(primaryID: Self.media, leadingID: Self.timer, overlay: .systemLevel, overlayKey: "level-volume"))
        #expect(burst.satelliteDiameter == 0)
    }

    @Test("A burst never shrinks a wider compact primary")
    func burstDoesNotShrink() {
        let recording = IslandActivityID(kind: .recording, key: "screen")
        let compact = layout(IslandLayoutDescriptor(primaryID: recording))
        let burst = layout(IslandLayoutDescriptor(primaryID: recording, overlay: .event, overlayKey: "event-focus"))
        #expect(burst.size.width >= compact.size.width)
    }

    @Test("An expanded island appends a band for a level HUD instead of covering content")
    func expandedBand() {
        let plain = layout(IslandLayoutDescriptor(primaryID: Self.timer, level: .expanded))
        let banded = layout(IslandLayoutDescriptor(primaryID: Self.timer, level: .expanded, overlay: .systemLevel, overlayKey: "level-volume"))
        #expect(banded.size.height == plain.size.height + NotchLayout.islandOverlayBandHeight)
    }

    @Test("The synthetic island floats below the edge with symmetric satellites")
    func syntheticIsland() {
        let descriptor = IslandLayoutDescriptor(primaryID: Self.media, leadingID: Self.timer, trailingID: Self.agents)
        let floating = layout(descriptor, Self.external)
        #expect(floating.topInset == NotchIsland.Geometry.floatingTopInset)
        #expect(floating.satelliteDiameter == NotchIsland.Geometry.compactHeight)
        let rect = floating.islandRect(in: Self.external)
        #expect(abs(rect.midX - Self.external.screenFrame.midX) < 0.5)
    }

    @Test("Secondary displays never expand and never show another display's burst")
    func displayRouting() {
        let descriptor = IslandLayoutDescriptor(
            primaryID: Self.media, level: .expanded, leadingID: Self.timer,
            overlay: .systemLevel, overlayKey: "level-brightness", overlayDisplayID: 7
        )
        #expect(IslandDisplayPolicy.activity(for: descriptor, displayID: 1, isActiveDisplay: true, mirrorsPassiveContext: true)
            == .island(descriptor.routed(to: 1)))
        #expect(descriptor.routed(to: 1).overlay == nil)

        let secondary = IslandDisplayPolicy.activity(for: descriptor, displayID: 2, isActiveDisplay: false, mirrorsPassiveContext: true)
        #expect(secondary == .island(descriptor.restingCopy()))
        if case .island(let resting) = secondary {
            #expect(resting.level == .compact)
            #expect(resting.overlay == nil)
        }

        let owner = IslandDisplayPolicy.activity(for: descriptor, displayID: 7, isActiveDisplay: false, mirrorsPassiveContext: true)
        if case .island(let routed) = owner {
            #expect(routed.overlay == .systemLevel)
            #expect(routed.level == .compact)
        } else {
            Issue.record("the display that changed brightness shows its HUD")
        }
    }

    @Test("A recording stays on the active display; passive work mirrors only by preference")
    func mirroringRules() {
        let recording = IslandLayoutDescriptor(primaryID: IslandActivityID(kind: .recording, key: "screen"))
        #expect(IslandDisplayPolicy.activity(for: recording, displayID: 2, isActiveDisplay: false, mirrorsPassiveContext: true) == .idle)
        let timer = IslandLayoutDescriptor(primaryID: Self.timer)
        #expect(IslandDisplayPolicy.activity(for: timer, displayID: 2, isActiveDisplay: false, mirrorsPassiveContext: false) == .idle)
        #expect(IslandDisplayPolicy.activity(for: timer, displayID: 2, isActiveDisplay: false, mirrorsPassiveContext: true) != .idle)
        let media = IslandLayoutDescriptor(primaryID: Self.media)
        #expect(IslandDisplayPolicy.activity(for: media, displayID: 2, isActiveDisplay: false, mirrorsPassiveContext: false) != .idle)
    }
}

@Suite("Island arbiter integration")
struct IslandArbiterTests {
    static let media = IslandActivityID(kind: .media, key: "now-playing")
    static let recording = IslandActivityID(kind: .recording, key: "screen")

    private func arbiter(island: IslandLayoutDescriptor?) -> ActivityArbiter {
        var arbiter = ActivityArbiter()
        arbiter.island = island
        arbiter.islandOwnsAmbientActivities = true
        return arbiter
    }

    @Test("Capture selection and countdown still take over the island")
    func captureWins() {
        var a = arbiter(island: IslandLayoutDescriptor(primaryID: Self.media))
        a.hasMedia = true
        a.selection = .area
        #expect(a.resolve() == .selecting(.area))
        a.selection = nil
        a.countdown = (3, .area)
        #expect(a.resolve() == .countdown(remaining: 3, intent: .area))
    }

    @Test("A volume change overlays the island instead of replacing its primary")
    func volumeOverlays() {
        var a = arbiter(island: IslandLayoutDescriptor(primaryID: Self.media))
        a.systemLevel = SystemLevel(kind: .volume, value: 0.5, isMuted: false)
        guard case .island(let descriptor) = a.resolve() else {
            Issue.record("expected the island")
            return
        }
        #expect(descriptor.primaryID == Self.media)
        #expect(descriptor.overlay == .systemLevel)
    }

    @Test("A level HUD with no island primary keeps its legacy card")
    func levelWithoutPrimary() {
        var a = arbiter(island: IslandLayoutDescriptor(overlay: .event, overlayKey: "event-focus"))
        let level = SystemLevel(kind: .volume, value: 0.5, isMuted: false)
        a.systemLevel = level
        #expect(a.resolve() == .systemLevel(level))
    }

    @Test("A recording inside the island still outranks processing, results and the capture menu")
    func recordingRung() {
        var a = arbiter(island: IslandLayoutDescriptor(primaryID: Self.recording, leadingID: Self.media))
        a.isRecording = true
        a.isProcessing = "OCR"
        a.hasResult = true
        a.userExpanded = true
        guard case .island(let descriptor) = a.resolve() else {
            Issue.record("expected the island at the recording rung")
            return
        }
        #expect(descriptor.containsRecording)
        a.dictation = DictationSnapshot(state: .listening)
        #expect(a.resolve() == .dictation(DictationSnapshot(state: .listening)))
    }

    @Test("Without the island, a recording resolves exactly as before")
    func legacyRecording() {
        var a = ActivityArbiter()
        a.isRecording = true
        a.hasMedia = true
        #expect(a.resolve() == .recording)
    }

    @Test("Interrupting transient contexts overlay; persistent ones stay inside the island")
    func contextOverlay() {
        var a = arbiter(island: IslandLayoutDescriptor(primaryID: Self.media))
        a.context = ContextSnapshot(kind: .network, title: "Offline", mayInterruptMedia: true)
        if case .island(let descriptor) = a.resolve() {
            #expect(descriptor.overlay != nil)
        } else {
            Issue.record("expected the island")
        }
        a.context = ContextSnapshot(kind: .ai, title: "Codex", mayInterruptMedia: true)
        if case .island(let descriptor) = a.resolve() {
            #expect(descriptor.overlay == nil)
        }
        a.allowsContextOverlay = false
        a.context = ContextSnapshot(kind: .network, title: "Offline", mayInterruptMedia: true)
        if case .island(let descriptor) = a.resolve() {
            #expect(descriptor.overlay == nil, "the preference keeps alerts off the island")
        }
    }

    @Test("A card with controls never covers an island the user expanded")
    func noContextOverExpanded() {
        var a = arbiter(island: IslandLayoutDescriptor(primaryID: Self.media, level: .expanded))
        a.context = ContextSnapshot(kind: .network, title: "Offline", mayInterruptMedia: true)
        if case .island(let descriptor) = a.resolve() {
            #expect(descriptor.overlay == nil)
        }
    }

    @Test("With the island owning ambient work, legacy media and persistent contexts stay silent")
    func ambientSuppressed() {
        var a = arbiter(island: nil)
        a.hasMedia = true
        a.context = ContextSnapshot(kind: .timer, title: "Focus")
        #expect(a.resolve() == .idle)
        let power = ContextSnapshot(kind: .power, title: "Charging", mayInterruptMedia: true)
        a.context = power
        #expect(a.resolve() == .context(power))
    }

    @Test("Island presentation identity and interactivity")
    func identity() {
        let compact = NotchActivity.island(IslandLayoutDescriptor(primaryID: Self.recording))
        #expect(compact.isInteractive)
        #expect(!compact.isExpanded)
        let expanded = NotchActivity.island(IslandLayoutDescriptor(primaryID: Self.media, level: .expanded))
        #expect(expanded.isExpanded)
        #expect(compact.presentationIdentity != expanded.presentationIdentity)
    }
}

@Suite("Island interaction policies")
struct IslandInteractionPolicyTests {
    @Test("A dragged file pulls toward the pointer with a still centre")
    func fileDropPull() {
        #expect(FileDropPullPolicy.pull(x: 250, width: 500) == 0)
        #expect(FileDropPullPolicy.pull(x: 270, width: 500) == 0, "inside the dead zone")
        #expect(FileDropPullPolicy.pull(x: 500, width: 500) == 1)
        #expect(FileDropPullPolicy.pull(x: 0, width: 500) == -1)
        #expect(FileDropPullPolicy.pull(x: 9_999, width: 500) == 1, "clamped")
        #expect(FileDropPullPolicy.pull(x: 100, width: 0) == 0)
    }

    @Test("The island's compact satellites keep full-size hit targets")
    func satelliteHitTarget() {
        let metrics = NotchMetrics(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            hasPhysicalNotch: true,
            notchSize: CGSize(width: 185, height: 32),
            menuBarHeight: 32
        )
        let layout = NotchLayout.layout(
            for: .island(IslandLayoutDescriptor(
                primaryID: IslandActivityID(kind: .timer, key: "a"),
                leadingID: IslandActivityID(kind: .media, key: "now-playing")
            )),
            metrics: metrics,
            isPeeking: false,
            resultCount: 0
        )
        let farEdgeOfHitTarget = layout.size.width / 2 + layout.satelliteSpacing
            + layout.satelliteDiameter / 2 + NotchShotDesignSystem.minimumControlTarget / 2
        #expect(layout.islandRect(in: metrics).width / 2 >= farEdgeOfHitTarget - 0.001)
    }

    @Test("A compact island keeps the presence poll armed, like compact media")
    @MainActor
    func triggerClickAcceptance() {
        let compact = NotchActivity.island(IslandLayoutDescriptor(primaryID: IslandActivityID(kind: .media, key: "now-playing")))
        let expanded = NotchActivity.island(IslandLayoutDescriptor(primaryID: IslandActivityID(kind: .media, key: "now-playing"), level: .expanded))
        #expect(NotchWindowController.shouldPollPresence(activity: compact, isPeeking: false, isPointerOverIsland: false, hasHoveredDisplay: false))
        #expect(expanded.isExpanded)
        #expect(!compact.isExpanded)
    }
}

@Suite("Island external display centring")
struct IslandClusterCentringTests {
    static let external = NotchMetrics(
        screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        hasPhysicalNotch: false,
        notchSize: NotchMetrics.syntheticIslandSize,
        menuBarHeight: 25
    )
    static let notched = NotchMetrics(
        screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        hasPhysicalNotch: true,
        notchSize: CGSize(width: 185, height: 32),
        menuBarHeight: 32
    )
    static let media = IslandActivityID(kind: .media, key: "now-playing")
    static let build = IslandActivityID(kind: .external, key: "build")

    private func layout(_ descriptor: IslandLayoutDescriptor, _ metrics: NotchMetrics) -> NotchLayout {
        NotchLayout.layout(for: .island(descriptor), metrics: metrics, isPeeking: false, resultCount: 0)
    }

    @Test("A synthetic island with one satellite centres the pair, not just the pill", arguments: [true, false])
    func pairIsCentred(_ leading: Bool) {
        let descriptor = leading
            ? IslandLayoutDescriptor(primaryID: Self.media, leadingID: Self.build)
            : IslandLayoutDescriptor(primaryID: Self.media, trailingID: Self.build)
        let layout = layout(descriptor, Self.external)
        let primary = layout.primaryRect(in: Self.external)
        let span = layout.satelliteSpacing + layout.satelliteDiameter
        let groupMinX = leading ? primary.minX - span : primary.minX
        let groupMaxX = leading ? primary.maxX : primary.maxX + span
        #expect(abs((groupMinX + groupMaxX) / 2 - Self.external.screenFrame.midX) < 0.5)
    }

    @Test("A physical notch never shifts off the camera")
    func physicalNeverShifts() {
        let layout = layout(IslandLayoutDescriptor(primaryID: Self.media, leadingID: Self.build), Self.notched)
        #expect(layout.clusterOffset == 0)
    }
}
