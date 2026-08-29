import CoreGraphics
import Foundation
import Testing

@testable import NotchShotKit

/// Compact media draws artwork and a playback wave in wings well outside the
/// hardware notch. Those wings are the only thing on screen while music plays,
/// so reaching for them has to open the notch — it used to do nothing, because
/// the hover trigger was pinned to the bare cutout.
@Suite("Notch hover zones")
struct NotchHoverZoneTests {

    /// A 16-inch-ish notch centred on a 1728 pt wide screen.
    private static let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    private static let metrics = NotchMetrics(
        screenFrame: screen,
        hasPhysicalNotch: true,
        notchSize: CGSize(width: 200, height: 32),
        menuBarHeight: 32
    )

    private static func island(for activity: NotchActivity, isPeeking: Bool = false) -> CGRect {
        NotchLayout.layout(
            for: activity,
            metrics: metrics,
            isPeeking: isPeeking,
            resultCount: 0,
            hasStack: false
        ).islandRect(in: metrics)
    }

    private static func trigger(for activity: NotchActivity) -> CGRect {
        NotchWindowController.triggerZone(
            notchRect: metrics.notchRect,
            restingIsland: island(for: activity),
            isExpanded: activity.isExpanded
        )
    }

    @Test("The playback wave beside the notch can start a hover")
    func mediaWingsAreHoverable() {
        let mediaIsland = Self.island(for: .media)
        let zone = Self.trigger(for: .media)
        let notch = Self.metrics.notchRect

        // The wings really do extend past the cutout — otherwise this test
        // would pass without proving anything.
        #expect(mediaIsland.width > notch.width)

        // A point in the right-hand wing: past the notch edge, inside the island.
        let waveX = (notch.maxX + mediaIsland.maxX) / 2
        let wave = CGPoint(x: waveX, y: notch.midY)
        #expect(mediaIsland.contains(wave))
        #expect(!notch.insetBy(dx: -6, dy: -4).contains(wave), "point must be outside the old trigger")
        #expect(zone.contains(wave), "the playback wave must be able to start a hover")

        // And the artwork wing on the other side.
        let artwork = CGPoint(x: (notch.minX + mediaIsland.minX) / 2, y: notch.midY)
        #expect(zone.contains(artwork), "the artwork wing must be able to start a hover")
    }

    @Test("An expanded island never becomes its own trigger")
    func expandedIslandDoesNotSelfTrigger() {
        let zone = Self.trigger(for: .expanded)
        let expandedIsland = Self.island(for: .expanded)

        // Far out in the expanded island, well beyond the closed notch. If this
        // could start a hover the notch would re-open itself forever.
        let deep = CGPoint(x: expandedIsland.maxX - 20, y: expandedIsland.midY)
        #expect(expandedIsland.contains(deep))
        #expect(!zone.contains(deep))
        #expect(zone == Self.metrics.notchRect.insetBy(dx: -6, dy: -4))
    }

    @Test("Peeking does not widen the trigger, only the drawn island")
    func peekDoesNotWidenTrigger() {
        // The resting island is what the trigger follows; a peeked media island
        // is much wider and must not drag the trigger out with it.
        let resting = Self.island(for: .media, isPeeking: false)
        let peeked = Self.island(for: .media, isPeeking: true)
        #expect(peeked.width > resting.width)

        let zone = Self.trigger(for: .media)
        let peekOnly = CGPoint(x: peeked.maxX - 10, y: Self.metrics.notchRect.midY)
        #expect(!zone.contains(peekOnly))
    }

    @Test("An idle notch keeps the bare cutout as its trigger")
    func idleTriggerIsUnchanged() {
        #expect(Self.trigger(for: .idle) == Self.metrics.notchRect.insetBy(dx: -6, dy: -4))
    }
}
