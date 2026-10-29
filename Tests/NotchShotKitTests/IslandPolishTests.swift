import CoreGraphics
import SwiftUI
import Testing
@testable import NotchShotKit

@Suite("Island polish")
struct IslandPolishTests {
    private let metrics = NotchMetrics(
        screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        hasPhysicalNotch: true,
        notchSize: CGSize(width: 185, height: 32),
        menuBarHeight: 37
    )

    @Test("A page switch holds the taller shell and never shrinks or overgrows it")
    func heldPageHeight() {
        let capture = NotchLayout.layout(for: .expanded, metrics: metrics, isPeeking: false, resultCount: 0)
        let held = NotchLayout.layout(
            for: .expanded,
            metrics: metrics,
            isPeeking: false,
            resultCount: 0,
            heldHeight: capture.size.height + 120
        )
        #expect(held.size.height == capture.size.height + 120)
        #expect(held.size.width == capture.size.width)

        let lower = NotchLayout.layout(
            for: .expanded,
            metrics: metrics,
            isPeeking: false,
            resultCount: 0,
            heldHeight: capture.size.height - 40
        )
        #expect(lower.size == capture.size)

        let ceiling = NotchLayout.layout(
            for: .expanded,
            metrics: metrics,
            isPeeking: false,
            resultCount: 0,
            heldHeight: 10_000
        )
        #expect(ceiling.size.height == NotchLayout.maximumSize.height)
    }

    @Test("Only the pill's pages hold their height")
    func heldHeightAppliesToPagesOnly() {
        let tabs = NotchTab.visible(lastSlot: .agents)
        #expect(NotchTab.holdsHeight(of: .expanded, in: tabs))
        #expect(NotchTab.holdsHeight(of: .result, in: tabs))
        #expect(!NotchTab.holdsHeight(of: .idle, in: tabs))
        #expect(!NotchTab.holdsHeight(of: .recording, in: tabs))
        let agents = IslandLayoutDescriptor(primaryID: IslandActivityID(kind: .ai, key: "agents"), level: .expanded)
        #expect(NotchTab.holdsHeight(of: .island(agents), in: tabs))
        #expect(!NotchTab.holdsHeight(of: .island(agents), in: NotchTab.visible(lastSlot: .none)))
    }

    @Test("A satellite stretches toward the shell, then rounds out at rest")
    func satelliteStretch() {
        #expect(IslandSatelliteBud.stretch(0) < 1)
        #expect(IslandSatelliteBud.stretch(IslandSatelliteBud.pinchPoint) > 1)
        #expect(abs(IslandSatelliteBud.stretch(1) - 1) < 0.0001)
        // An overshooting spring past rest must not stretch it again.
        #expect(abs(IslandSatelliteBud.stretch(1.15) - 1) < 0.0001)
        var last = IslandSatelliteBud.stretch(0)
        for step in 1...20 {
            let value = IslandSatelliteBud.stretch(IslandSatelliteBud.pinchPoint * CGFloat(step) / 20)
            #expect(value >= last)
            last = value
        }
    }

    @Test("Every island spring settles within Apple's two-second limit")
    func springsSettleWithinTwoSeconds() {
        for style in IslandAnimationStyle.allCases {
            let tuning = NotchMotion.tuning(for: style)
            let springs = [
                (tuning.expandResponse, tuning.expandDamping),
                (tuning.collapseResponse, tuning.collapseDamping),
                (tuning.contentResponse, tuning.contentDamping),
                (0.46, tuning.arrivalDamping),
            ]
            for (response, damping) in springs {
                #expect(Spring(response: response, dampingRatio: damping).settlingDuration <= 2, "\(style)")
            }
        }
    }

    @Test("The level HUD has one segment per volume-key press, and a fine press fills a quarter of one")
    func levelSegments() {
        #expect(LevelSegments.count == SystemMediaKeyAction.coarseSteps)
        let rect = CGRect(x: 0, y: 0, width: 160, height: 8)
        func filledWidth(_ fraction: Double) -> CGFloat {
            LevelSegments(fraction: fraction, spacing: 0).path(in: rect).boundingRect.width
        }
        #expect(filledWidth(0) == 0)
        #expect(abs(filledWidth(0.5) - 80) < 0.01)
        #expect(abs(filledWidth(1) - 160) < 0.01)
        // CoreAudio's rounding never leaves a sliver in the next segment.
        #expect(abs(filledWidth(0.49999997) - 80) < 0.01)
        let afterFineStep = SystemMediaKeyAction.adjustedLevel(current: 0.5, increasing: true, fine: true)
        #expect(abs(filledWidth(afterFineStep) - 82.5) < 0.01)
        let afterStep = SystemMediaKeyAction.adjustedLevel(current: 0.5, increasing: true, fine: false)
        #expect(abs(filledWidth(afterStep) - 90) < 0.01)
    }

    @Test("Caps Lock outranks the song on the closed notch's edge, and an open notch shows neither")
    func rimPriority() {
        #expect(NotchRimPolicy.kind(
            isOpen: false, isCapsLockOn: true, showsCapsLockGlow: true,
            isShowingCompactPlayer: true, showsSongProgress: true
        ) == .capsLock)
        #expect(NotchRimPolicy.kind(
            isOpen: false, isCapsLockOn: true, showsCapsLockGlow: false,
            isShowingCompactPlayer: true, showsSongProgress: true
        ) == .songProgress)
        #expect(NotchRimPolicy.kind(
            isOpen: false, isCapsLockOn: false, showsCapsLockGlow: true,
            isShowingCompactPlayer: false, showsSongProgress: true
        ) == nil)
        #expect(NotchRimPolicy.kind(
            isOpen: true, isCapsLockOn: true, showsCapsLockGlow: true,
            isShowingCompactPlayer: true, showsSongProgress: true
        ) == nil)
    }

    @Test("The progress rim glides to the end of the song while playing and holds while paused")
    func progressRimGlide() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let glide = { (seconds: TimeInterval, remaining: TimeInterval?) in
            LayerProgressRimView.value(
                at: start.addingTimeInterval(seconds),
                from: 0.25,
                remaining: remaining,
                since: start
            )
        }
        #expect(glide(0, 90) == 0.25)
        #expect(abs(glide(45, 90) - 0.625) < 0.0001)
        #expect(glide(90, 90) == 1)
        #expect(glide(500, 90) == 1)
        #expect(glide(45, nil) == 0.25)
    }

    @Test("A skip swipe pulls the player toward the fingers, easing off, and lets go within Apple's limit")
    func skipPull() {
        var next = TrackSwipeDecision()
        next.add(deltaX: -TrackSwipeDecision.threshold, deltaY: 0)
        #expect(next.command == .nextTrack)
        #expect(next.pull < -0.4 && next.pull > -0.5)
        next.add(deltaX: -1_000, deltaY: 0)
        #expect(next.pull >= -1)

        var previous = TrackSwipeDecision()
        previous.add(deltaX: 20, deltaY: 0)
        #expect(previous.pull > 0)

        var vertical = TrackSwipeDecision()
        vertical.add(deltaX: 30, deltaY: 60)
        #expect(vertical.pull == 0)

        #expect(IslandMotion.skipReleaseSpring.settlingDuration <= 2)
        #expect(IslandMotion.pullSettleSpring.settlingDuration <= 2)
    }

    @Test("Lyric lines blur by distance from the sung line, capped, and unsynced lyrics stay sharp")
    func lyricBlur() {
        #expect(LyricsPanel.blurRadius(linesAway: nil) == 0)
        #expect(LyricsPanel.blurRadius(linesAway: 0) == 0)
        #expect(LyricsPanel.blurRadius(linesAway: 1) > 0)
        #expect(LyricsPanel.blurRadius(linesAway: 2) > LyricsPanel.blurRadius(linesAway: 1))
        #expect(LyricsPanel.blurRadius(linesAway: 9) == LyricsPanel.blurRadius(linesAway: 3))
    }
}
