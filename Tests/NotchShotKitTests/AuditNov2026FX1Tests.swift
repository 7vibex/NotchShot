import Foundation
import Testing
@testable import NotchShotKit

@Suite("Volume keys off the main thread")
struct AuditFX1VolumeKeyTests {
    @Test("Presses that piled up while Core Audio was busy all count")
    func coalescedPressesAllCount() {
        let once = SystemMediaKeyAction.adjustedLevel(current: 0.5, increasing: true, fine: false)
        let twice = SystemMediaKeyAction.adjustedLevel(current: once, increasing: true, fine: false)
        let result = SystemVolumeEngine.stepped(from: 0.5, through: [.volumeUp(fine: false), .volumeUp(fine: false)])
        #expect(result.level == twice)
        #expect(result.bump == nil)
    }

    @Test("Only the last press of a batch decides the bump")
    func lastPressDecidesBump() {
        let atTop = SystemVolumeEngine.stepped(from: 1, through: [.volumeUp(fine: false)])
        #expect(atTop.level == 1)
        #expect(atTop.bump?.edge == .top)

        let backDown = SystemVolumeEngine.stepped(from: 1, through: [.volumeUp(fine: false), .volumeDown(fine: false)])
        #expect(backDown.level < 1)
        #expect(backDown.bump == nil)
    }

    @Test("Actions that aren't volume steps leave the level alone")
    func otherActionsIgnored() {
        let result = SystemVolumeEngine.stepped(from: 0.4, through: [.mute, .brightnessUp(fine: false)])
        #expect(result.level == 0.4)
        #expect(result.bump == nil)
    }

    @Test("Every bump gets its own sequence, or the bar wouldn't replay it")
    func bumpSequencesDiffer() throws {
        let first = try #require(SystemLevelBump.next(current: 1, increasing: true))
        let second = try #require(SystemLevelBump.next(current: 1, increasing: true))
        #expect(first.sequence != second.sequence)
        #expect(SystemLevelBump.next(current: 0.5, increasing: true) == nil)
    }
}

@Suite("Media key answers from off the tap thread")
struct AuditFX1PendingKeyAnswerTests {
    @Test("An answer in time is the answer")
    func answeredInTime() {
        let applied = PendingKeyAnswer()
        #expect(applied.claim())
        applied.finish(true)
        #expect(applied.wait())

        let failed = PendingKeyAnswer()
        #expect(failed.claim())
        failed.finish(false)
        #expect(!failed.wait())
    }

    @Test("A key nobody picked up goes to macOS and can't be applied later")
    func unclaimedKeyIsHandedOver() {
        let answer = PendingKeyAnswer()
        #expect(!answer.wait(first: .milliseconds(1), claimed: .milliseconds(1)))
        #expect(!answer.claim())
    }

    @Test("A key being applied is swallowed even when the write runs late")
    func claimedKeyIsNotAppliedTwice() {
        let answer = PendingKeyAnswer()
        #expect(answer.claim())
        #expect(answer.wait(first: .milliseconds(1), claimed: .milliseconds(1)))
    }
}

@Suite("Audio taps and routes")
struct AuditFX1AudioPolicyTests {
    @Test("One tap target per helper bundle, however many renderers it has")
    func tapTargetsAreDistinct() {
        let running = ["com.app", "com.app.helper", "com.app.helper", "com.other"]
        #expect(AudioTapProcessPolicy.tapTargets(for: "com.app", among: running) == ["com.app", "com.app.helper"])
    }

    @Test("A meter that heard nothing from the old player doesn't refuse the new one")
    func silenceRefusalOnlyForThePlayerThatWasHeard() {
        #expect(!LiveAudioMeter.refusesAfterSilence(player: "com.a", heardSignalFrom: "com.a"))
        #expect(LiveAudioMeter.refusesAfterSilence(player: "com.b", heardSignalFrom: "com.a"))
        #expect(LiveAudioMeter.refusesAfterSilence(player: "com.a", heardSignalFrom: nil))
    }

    @Test("A battery amendment holds for its route until it expires")
    func batteryAmendment() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        #expect(AudioRouteContextPolicy.batteryAmendmentApplies(routeID: 1, currentRouteID: 1, expiresAt: nil, now: now))
        #expect(AudioRouteContextPolicy.batteryAmendmentApplies(
            routeID: 1, currentRouteID: 1, expiresAt: now.addingTimeInterval(1), now: now
        ))
        #expect(!AudioRouteContextPolicy.batteryAmendmentApplies(
            routeID: 1, currentRouteID: 1, expiresAt: now.addingTimeInterval(-1), now: now
        ))
        #expect(!AudioRouteContextPolicy.batteryAmendmentApplies(routeID: 1, currentRouteID: 2, expiresAt: nil, now: now))
    }

    @Test("The locked charging reading is reused briefly, and uptime going back drops it")
    func chargingReadingFreshness() {
        #expect(LockedChargingPolicy.isFresh(readAt: 100, now: 100))
        #expect(LockedChargingPolicy.isFresh(readAt: 100, now: 104.9))
        #expect(!LockedChargingPolicy.isFresh(readAt: 100, now: 105))
        #expect(!LockedChargingPolicy.isFresh(readAt: 100, now: 99))
    }
}

@Suite("Media sources")
struct AuditFX1MediaSourceTests {
    @Test("The Music queue script's variables don't collide with AppleScript or Music terms")
    func queueScriptAvoidsReservedWords() {
        // `osacompile` refuses `repeat with offset from …`, so the queue was always empty.
        #expect(!MediaQueueService.musicQueueScript.contains("offset"))
        // `position` is a property in Music's dictionary, so inside its `tell` it isn't a variable.
        #expect(!MediaQueueService.musicQueueScript.contains("position"))
    }

    @Test("A running player's silence is held for two polls, then believed")
    func silenceIsBounded() {
        #expect(!AppleEventsMediaSource.holdsLastSnapshot(unansweredPolls: 0))
        #expect(AppleEventsMediaSource.holdsLastSnapshot(unansweredPolls: 1))
        #expect(AppleEventsMediaSource.holdsLastSnapshot(unansweredPolls: 2))
        #expect(!AppleEventsMediaSource.holdsLastSnapshot(unansweredPolls: 3))
        #expect(!AppleEventsMediaSource.holdsLastSnapshot(unansweredPolls: 40))
    }

    @Test("A track with no cover is asked about once a minute, a new track at once")
    func artworkRetry() {
        let missed = Date(timeIntervalSinceReferenceDate: 1_000)
        #expect(AppleEventsMediaSource.isWithinArtworkRetryInterval(
            missedKey: "a", at: missed, key: "a", now: missed.addingTimeInterval(59)
        ))
        #expect(!AppleEventsMediaSource.isWithinArtworkRetryInterval(
            missedKey: "a", at: missed, key: "a", now: missed.addingTimeInterval(60)
        ))
        #expect(!AppleEventsMediaSource.isWithinArtworkRetryInterval(
            missedKey: "a", at: missed, key: "b", now: missed.addingTimeInterval(1)
        ))
    }

    private func merge(_ json: String, into payload: inout [String: Any]) -> MediaSnapshot? {
        AdapterPayload.snapshot(mergingLine: Data(json.utf8), into: &payload)
    }

    @Test("A diff line keeps the track it doesn't mention")
    func diffKeepsTrack() throws {
        var payload: [String: Any] = [:]
        let firstLine = merge(#"{"payload":{"title":"Song","artist":"Band","playing":true}}"#, into: &payload)
        let first = try #require(firstLine)
        #expect(first.title == "Song")
        #expect(first.isPlaying)

        let pausedLine = merge(#"{"diff":true,"payload":{"playing":false}}"#, into: &payload)
        let paused = try #require(pausedLine)
        #expect(paused.title == "Song")
        #expect(paused.artist == "Band")
        #expect(!paused.isPlaying)
    }

    @Test("A null in a diff line removes the key")
    func diffNullRemoves() throws {
        var payload: [String: Any] = [:]
        _ = merge(#"{"payload":{"title":"Song","artist":"Band"}}"#, into: &payload)
        let changedLine = merge(#"{"diff":true,"payload":{"artist":null}}"#, into: &payload)
        let changed = try #require(changedLine)
        #expect(changed.title == "Song")
        #expect(changed.artist == nil)
    }

    @Test("A line with no diff flag replaces everything before it")
    func fullLineReplaces() throws {
        var payload: [String: Any] = [:]
        _ = merge(#"{"payload":{"title":"Song","artist":"Band"}}"#, into: &payload)
        let nextLine = merge(#"{"title":"Other"}"#, into: &payload)
        let next = try #require(nextLine)
        #expect(next.title == "Other")
        #expect(next.artist == nil)
    }

    @Test("A bad line changes nothing")
    func badLineIsIgnored() {
        var payload: [String: Any] = ["title": "Song"]
        let line = merge("not json", into: &payload)
        #expect(line == nil)
        #expect(payload["title"] as? String == "Song")
    }

    @Test("An absurd LRC timestamp is not a timestamp, and can't reach a seek")
    func lyricTimeIsBounded() {
        #expect(LRCParser.timestamp("03:30.50") == 210.5)
        #expect(LRCParser.timestamp("6000:00") == 360_000)
        #expect(LRCParser.timestamp("6001:00") == nil)
        #expect(LRCParser.timestamp("99999999999999:00") == nil)
        #expect(MediaTimePolicy.wholeSeconds(1e300, rounding: .towardZero) == nil)
        #expect(MediaTimePolicy.wholeSeconds(61.9, rounding: .towardZero) == 61)
    }
}

/// Records what the worker registers and removes, without Core Audio.
private final class AuditFX1PrivacyBackend: PrivacyIndicatorBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [UInt32]
    private var addedProperties: [PrivacyIndicatorProperty] = []
    private var cancelledProperties: [PrivacyIndicatorProperty] = []
    private var listChanged: (@Sendable () -> Void)?

    init(processes: [UInt32]) {
        self.processes = processes
    }

    var added: [PrivacyIndicatorProperty] { lock.withLock { addedProperties } }
    var cancelled: [PrivacyIndicatorProperty] { lock.withLock { cancelledProperties } }

    func changeProcesses(to new: [UInt32], on queue: DispatchQueue) {
        let handler = lock.withLock {
            processes = new
            return listChanged
        }
        if let handler {
            queue.async { handler() }
        }
    }

    func addListener(
        _ property: PrivacyIndicatorProperty,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> PrivacyIndicatorListener? {
        lock.withLock {
            addedProperties.append(property)
            if property == .audioProcesses { listChanged = handler }
        }
        return PrivacyIndicatorListener { [self] in
            lock.withLock { cancelledProperties.append(property) }
        }
    }

    func otherAudioProcesses() -> [UInt32] { lock.withLock { processes } }
    func cameraDeviceIDs() -> [UInt32] { [] }
    func isRecording(_ process: UInt32) -> Bool { false }
    func isCameraRunning(_ device: UInt32) -> Bool { false }
    func client(for process: UInt32) -> MicrophoneClient? { nil }
}

@Suite("Privacy indicator listeners")
struct AuditFX1PrivacyDiffTests {
    private func finishQueuedWork(on queue: DispatchQueue) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }

    @Test("A list change registers only the difference, and leaves a process that exited alone")
    func onlyTheDifferenceIsRegistered() async {
        let queue = DispatchQueue(label: "com.notchshot.tests.privacy-diff")
        let backend = AuditFX1PrivacyBackend(processes: [1, 2])
        let worker = PrivacyIndicatorWorker(backend: backend, queue: queue)
        worker.start(generation: 1) { _ in }
        await finishQueuedWork(on: queue)

        backend.changeProcesses(to: [2, 3], on: queue)
        await finishQueuedWork(on: queue)

        #expect(backend.added.filter { $0 == .audioRunning(2) }.count == 1)
        #expect(backend.added.filter { $0 == .audioRunning(3) }.count == 1)
        // Its object went with the process; asking Core Audio to remove from it only logs an error.
        #expect(!backend.cancelled.contains(.audioRunning(1)))
        #expect(!backend.cancelled.contains(.audioRunning(2)))

        worker.stop()
        await finishQueuedWork(on: queue)
        #expect(backend.cancelled.contains(.audioRunning(2)))
        #expect(backend.cancelled.contains(.audioRunning(3)))
    }
}
