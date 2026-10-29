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
}
