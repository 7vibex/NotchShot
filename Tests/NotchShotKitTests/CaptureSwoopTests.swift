import CoreGraphics
import Foundation
import Testing
@testable import NotchShotKit

@Suite("Capture swoop into the notch")
struct CaptureSwoopTests {
    /// A 1470×956 notched laptop screen, as on the built-in display here.
    private let metrics = NotchMetrics(
        screenFrame: CGRect(x: 0, y: 0, width: 1470, height: 956),
        hasPhysicalNotch: true,
        notchSize: CGSize(width: 185, height: 32),
        menuBarHeight: 32
    )

    @Test("Ends centred in the notch and entirely inside it")
    func endsInsideTheNotch() throws {
        let source = CGRect(x: 200, y: 300, width: 600, height: 400)
        let plan = try #require(CaptureSwoopPlan.make(source: source, metrics: metrics, style: .iPhone))
        let notch = CGRect(
            x: metrics.notchCenterX - metrics.notchSize.width / 2,
            y: metrics.screenFrame.maxY - metrics.notchSize.height,
            width: metrics.notchSize.width,
            height: metrics.notchSize.height
        )
        #expect(notch.contains(plan.end))
        #expect(abs(plan.end.midX - notch.midX) < 0.001)
        #expect(abs(plan.end.midY - notch.midY) < 0.001)
        #expect(plan.start == source)
    }

    @Test("Keeps the capture's aspect ratio while shrinking")
    func keepsAspectRatio() throws {
        for source in [
            CGRect(x: 10, y: 10, width: 1200, height: 300),
            CGRect(x: 10, y: 10, width: 200, height: 800),
            metrics.screenFrame,
        ] {
            let plan = try #require(CaptureSwoopPlan.make(source: source, metrics: metrics, style: .iPhone))
            let ratio = source.width / source.height
            #expect(abs(plan.end.width / plan.end.height - ratio) < 0.01)
            #expect(plan.endCornerRadius == min(plan.end.width, plan.end.height) / 2)
        }
    }

    @Test("Never grows a capture smaller than the notch")
    func neverGrows() throws {
        let tiny = CGRect(x: 700, y: 500, width: 20, height: 10)
        let plan = try #require(CaptureSwoopPlan.make(source: tiny, metrics: metrics, style: .iPhone))
        #expect(plan.end.size == tiny.size)
    }

    @Test("Lines up horizontally first, then rises, and lands before it finishes fading")
    func timing() throws {
        for style in IslandAnimationStyle.allCases {
            let plan = try #require(
                CaptureSwoopPlan.make(source: CGRect(x: 0, y: 0, width: 400, height: 300), metrics: metrics, style: style)
            )
            #expect(plan.horizontalDuration < plan.verticalDuration)
            #expect(plan.fadeStart < plan.fadeEnd)
            #expect(plan.landing < plan.fadeEnd)
            // Apple keeps Live Activity animations under two seconds; a
            // capture's acknowledgement should be far quicker than that.
            #expect(plan.fadeEnd <= 0.6)
        }
    }

    @Test("Skips captures it can't place")
    func rejectsUnplaceable() {
        let offScreen = CGRect(x: 5000, y: 5000, width: 100, height: 100)
        #expect(CaptureSwoopPlan.make(source: offScreen, metrics: metrics, style: .iPhone) == nil)
        #expect(CaptureSwoopPlan.make(source: .zero, metrics: metrics, style: .iPhone) == nil)
        var noNotch = metrics
        noNotch.notchSize = .zero
        #expect(
            CaptureSwoopPlan.make(source: CGRect(x: 0, y: 0, width: 10, height: 10), metrics: noNotch, style: .iPhone) == nil
        )
    }
}
