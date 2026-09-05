import Foundation
import Testing
@testable import NotchShotKit

/// Only injected functions run here; these tests never enter a real secure
/// Space or change the user's session or display state.
@MainActor
struct LockScreenRecoveryTests {
    @Test("A second lock shows the reused Space again")
    func repeatedLock() {
        var creates = 0
        var visible = false
        var shows = 0
        let bridge = LockScreenSpaceBridge(
            mainConnection: { 1 },
            createSpace: { _, _, _ in creates += 1; return 2 },
            setAbsoluteLevel: { _, _, _ in 0 },
            showSpaces: { _, _ in visible = true; shows += 1; return 0 },
            moveWindows: { _, _, _, _ in 0 },
            now: { 0 }
        )
        #expect(bridge.attach(windowNumber: 11) == .attached(spaceID: 2))
        visible = false // WindowServer hides the Space when the user unlocks.
        bridge.resetAttachedWindows()
        #expect(bridge.attach(windowNumber: 12) == .attached(spaceID: 2))
        #expect(visible)
        #expect(shows == 2)
        #expect(creates == 1)
    }

    @Test("Presence refresh restores a hidden Space without moving windows twice")
    func presenceRefresh() {
        var clock: TimeInterval = 0
        var visible = false
        var moves = 0
        var shows = 0
        let bridge = LockScreenSpaceBridge(
            mainConnection: { 1 }, createSpace: { _, _, _ in 2 },
            setAbsoluteLevel: { _, _, _ in 0 },
            showSpaces: { _, _ in visible = true; shows += 1; return 0 },
            moveWindows: { _, _, _, _ in moves += 1; return 0 },
            now: { clock }
        )
        #expect(bridge.attach(windowNumber: 11) == .attached(spaceID: 2))
        visible = false
        clock = 0.5
        #expect(bridge.attach(windowNumber: 11) == .alreadyAttached(spaceID: 2))
        #expect(shows == 1)
        clock = 1
        #expect(bridge.attach(windowNumber: 11) == .alreadyAttached(spaceID: 2))
        #expect(visible)
        #expect(shows == 2)
        #expect(moves == 1)
    }

    @Test("A transient move failure recovers after backoff")
    func transientMoveFailure() {
        var clock: TimeInterval = 0
        var moves = 0
        let bridge = LockScreenSpaceBridge(
            mainConnection: { 1 }, createSpace: { _, _, _ in 2 },
            setAbsoluteLevel: { _, _, _ in 0 }, showSpaces: { _, _ in 0 },
            moveWindows: { _, _, _, _ in moves += 1; return moves == 1 ? -50 : 0 },
            now: { clock }
        )
        let failure = LockScreenSpaceBridge.AttachmentResult.failed(
            operation: "SLSSpaceAddWindowsAndRemoveFromSpaces", code: -50
        )
        #expect(bridge.attach(windowNumber: 11) == failure)
        clock = 0.9
        #expect(bridge.attach(windowNumber: 11) == failure)
        #expect(moves == 1)
        clock = 1
        #expect(bridge.attach(windowNumber: 11) == .attached(spaceID: 2))
        #expect(moves == 2)
    }

    @Test("Persistent failures stop retrying until a new lock or wake", arguments: [false, true])
    func boundedRetries(newLock: Bool) {
        var clock: TimeInterval = 0
        var moves = 0
        var succeeds = false
        let bridge = LockScreenSpaceBridge(
            mainConnection: { 1 }, createSpace: { _, _, _ in 2 },
            setAbsoluteLevel: { _, _, _ in 0 }, showSpaces: { _, _ in 0 },
            moveWindows: { _, _, _, _ in moves += 1; return succeeds ? 0 : -50 },
            now: { clock }
        )
        for instant in [0.0, 0.5, 1, 2, 3, 4, 30] {
            clock = instant
            _ = bridge.attach(windowNumber: 11)
        }
        #expect(moves == 3)
        #expect(!bridge.hasAttachedWindows)
        succeeds = true
        if newLock {
            bridge.resetAttachedWindows()
        } else {
            bridge.refreshPresentation()
        }
        #expect(bridge.attach(windowNumber: 11) == .attached(spaceID: 2))
        #expect(moves == 4)
    }

    @Test("Setup retries retain the allocated Space and never attach before it is shown")
    func setupFailureRecovery() {
        var clock: TimeInterval = 0
        var creates = 0
        var shows = 0
        var moves = 0
        let bridge = LockScreenSpaceBridge(
            mainConnection: { 1 },
            createSpace: { _, _, _ in creates += 1; return 2 },
            setAbsoluteLevel: { _, _, _ in 0 },
            showSpaces: { _, _ in shows += 1; return shows == 1 ? -50 : 0 },
            moveWindows: { _, _, _, _ in moves += 1; return 0 },
            now: { clock }
        )
        #expect(bridge.attach(windowNumber: 11) == .failed(operation: "SLSShowSpaces", code: -50))
        _ = bridge.attach(windowNumber: 12)
        #expect(shows == 1)
        #expect(moves == 0)
        clock = 1
        #expect(bridge.attach(windowNumber: 11) == .attached(spaceID: 2))
        #expect(creates == 1)
        #expect(shows == 2)
        #expect(moves == 1)
    }
}
