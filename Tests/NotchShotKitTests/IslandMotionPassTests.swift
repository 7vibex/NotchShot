import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import NotchShotKit

@Suite("Island motion pass")
struct IslandMotionPassTests {
    @Test("A page switch travels toward the tab that was picked, and only between pages")
    func pageStep() {
        let tabs = NotchTab.visible(lastSlot: .agents)
        #expect(NotchTab.step(from: .capture, to: .shelf, in: tabs) == 1)
        #expect(NotchTab.step(from: .agents, to: .capture, in: tabs) == -1)
        #expect(NotchTab.step(from: .shelf, to: .shelf, in: tabs) == 0)
        #expect(NotchTab.step(from: nil, to: .shelf, in: tabs) == 0)
        #expect(NotchTab.step(from: .capture, to: nil, in: tabs) == 0)
        // A page the pill leaves out has no position to travel from.
        #expect(NotchTab.step(from: .capture, to: .agents, in: NotchTab.visible(lastSlot: .none)) == 0)
    }

    @Test("Only a clear pull downward stretches the closed notch, and it opens past the threshold")
    func pullOpen() {
        var down = OpenPullDecision()
        down.add(deltaX: 1, downward: 8)
        #expect(down.isVertical == true)
        #expect(!down.opens)
        #expect(down.stretch > 0 && down.stretch < 1)
        down.add(deltaX: 0, downward: OpenPullDecision.threshold)
        #expect(down.opens)
        down.add(deltaX: 0, downward: 10_000)
        #expect(down.stretch <= 1)

        var sideways = OpenPullDecision()
        sideways.add(deltaX: 8, downward: 3)
        sideways.add(deltaX: 0, downward: 100)
        #expect(sideways.isVertical == false)
        #expect(sideways.stretch == 0)
        #expect(!sideways.opens)

        var upward = OpenPullDecision()
        upward.add(deltaX: 0, downward: -8)
        #expect(upward.isVertical == false)
        #expect(!upward.opens)

        var undecided = OpenPullDecision()
        undecided.add(deltaX: 1, downward: 2)
        #expect(undecided.isVertical == nil)
        #expect(undecided.stretch == 0)
    }

    @Test("A skip slides the next cover in from the side it asked for, for a few seconds only")
    func coverEdge() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        #expect(MediaCoverMotion.edge(after: MediaSkip(isForward: true, date: now), now: now) == .trailing)
        #expect(MediaCoverMotion.edge(after: MediaSkip(isForward: false, date: now), now: now) == .leading)
        let stale = MediaSkip(isForward: true, date: now.addingTimeInterval(-MediaCoverMotion.skipWindow - 1))
        #expect(MediaCoverMotion.edge(after: stale, now: now) == nil)
        #expect(MediaCoverMotion.edge(after: nil, now: now) == nil)
    }

    @Test("Live meters keep a whisper visible and never draw past their track")
    func meterGeometry() {
        #expect(LayerLevelFillView.fillWidth(fraction: 0, trackWidth: 100, minimumWidth: 6) == 0)
        #expect(LayerLevelFillView.fillWidth(fraction: 0.02, trackWidth: 100, minimumWidth: 6) == 6)
        #expect(LayerLevelFillView.fillWidth(fraction: 0.5, trackWidth: 100, minimumWidth: 6) == 50)
        #expect(LayerLevelFillView.fillWidth(fraction: 3, trackWidth: 100, minimumWidth: 6) == 100)
        #expect(LayerBarMeterView.barHeight(sample: 0, maxHeight: 14) == 2)
        #expect(LayerBarMeterView.barHeight(sample: 0.5, maxHeight: 14) == 7)
        #expect(LayerBarMeterView.barHeight(sample: 2, maxHeight: 14) == 14)
    }

    @Test("The lyric fill restarts for a new line or a pause, not for every position tick")
    func sweepRestarts() {
        typealias Sweep = LayerSweepRevealView<EmptyView>.Sweep
        let playing = Sweep(progress: 0.2, remaining: 3, key: "line")
        #expect(playing.restarts(from: nil))
        #expect(!Sweep(progress: 0.4, remaining: 2, key: "line").restarts(from: playing))
        #expect(Sweep(progress: 0.4, remaining: nil, key: "line").restarts(from: playing))
        #expect(Sweep(progress: 0, remaining: 4, key: "next").restarts(from: playing))
    }

    @Test("An agent's progress takes the closed edge only when nothing outranks it")
    func agentRim() {
        #expect(NotchRimPolicy.kind(
            isOpen: false, isCapsLockOn: false, showsCapsLockGlow: true,
            isShowingCompactPlayer: false, showsSongProgress: true,
            isShowingAgentProgress: true, showsAgentProgress: true
        ) == .agentProgress)
        #expect(NotchRimPolicy.kind(
            isOpen: false, isCapsLockOn: true, showsCapsLockGlow: true,
            isShowingCompactPlayer: false, showsSongProgress: true,
            isShowingAgentProgress: true, showsAgentProgress: true
        ) == .capsLock)
        #expect(NotchRimPolicy.kind(
            isOpen: false, isCapsLockOn: false, showsCapsLockGlow: true,
            isShowingCompactPlayer: false, showsSongProgress: true,
            isShowingAgentProgress: true, showsAgentProgress: false
        ) == nil)
        #expect(NotchRimPolicy.kind(
            isOpen: true, isCapsLockOn: false, showsCapsLockGlow: true,
            isShowingCompactPlayer: false, showsSongProgress: true,
            isShowingAgentProgress: true, showsAgentProgress: true
        ) == nil)
    }

    @Test("Lyrics crossfade only when the panel changes what it shows")
    func lyricsPhase() {
        #expect(LyricsPanel.phase(of: .idle) == .finding)
        #expect(LyricsPanel.phase(of: .unavailable("No lyrics")) == .message)
    }

    @Test("Pull and page springs settle within Apple's two-second limit")
    func pullSprings() {
        #expect(IslandMotion.pullSettleSpring.settlingDuration <= 2)
        #expect(IslandMotion.skipReleaseSpring.settlingDuration <= 2)
        #expect(IslandMotion.pullOpenStretch > 0 && IslandMotion.pullOpenStretch < 0.5)
    }
}
