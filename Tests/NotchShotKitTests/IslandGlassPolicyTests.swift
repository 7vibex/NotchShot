import CoreGraphics
import Testing
@testable import NotchShotKit

@Suite("Glass notch")
struct IslandGlassPolicyTests {
    private let band: CGFloat = 33
    private let height: CGFloat = 260

    @Test func offOrAccessibilityKeepsTheShellBlack() {
        #expect(!IslandGlassPolicy.usesGlass(enabled: false, reduceTransparency: false, increaseContrast: false))
        #expect(!IslandGlassPolicy.usesGlass(enabled: true, reduceTransparency: true, increaseContrast: false))
        #expect(!IslandGlassPolicy.usesGlass(enabled: true, reduceTransparency: false, increaseContrast: true))
        #expect(IslandGlassPolicy.usesGlass(enabled: true, reduceTransparency: false, increaseContrast: false))
    }

    /// The closed notch has to read as hardware whatever the setting.
    @Test func onlyTheOpenNotchIsSeeThrough() {
        #expect(!IslandGlassPolicy.isSeeThrough(
            enabled: true, isExpanded: false, reduceTransparency: false, increaseContrast: false
        ))
        #expect(IslandGlassPolicy.isSeeThrough(
            enabled: true, isExpanded: true, reduceTransparency: false, increaseContrast: false
        ))
    }

    @Test func theCameraBandNeverFades() {
        for shellHeight: CGFloat in [64, 160, 260, 440] {
            #expect(IslandGlassPolicy.fade(bandHeight: band, shellHeight: shellHeight).start >= band)
        }
    }

    /// The glass is the lower part of the shell; what is above it stays black.
    @Test func theGlassStaysAtTheBottom() {
        let fade = IslandGlassPolicy.fade(bandHeight: band, shellHeight: height)
        #expect(fade.end < height)
        #expect(abs(fade.start - height * IslandGlassPolicy.blackShare) < 0.001)
    }

    /// The ramp is a fixed distance, so it looks the same on every panel.
    @Test func theFadeKeepsItsLength() {
        for shellHeight: CGFloat in [64, 160, 260, 440] {
            let fade = IslandGlassPolicy.fade(bandHeight: band, shellHeight: shellHeight)
            #expect(abs(fade.end - fade.start - IslandGlassPolicy.fadeLength) < 0.001)
        }
    }

    @Test func theFadeEasesFromBlackToClear() {
        let curve = IslandGlassPolicy.fadeCurve
        #expect(curve.first == 1)
        #expect(curve.last == 0)
        #expect(zip(curve, curve.dropFirst()).allSatisfy { $0 > $1 })

        let locations = IslandGlassPolicy.rampStops.map(\.location)
        #expect(locations.first == 0)
        #expect(abs((locations.last ?? 0) - 1) < 0.000_001)
        #expect(zip(locations, locations.dropFirst()).allSatisfy { $0 <= $1 })
    }

    /// The ramp has one size and only moves with the shell, so where its
    /// stops land must still follow the fade at every shell height: black down
    /// to `fade.start`, then the curve spread evenly over `fadeLength`.
    @Test func theRampFollowsTheFadeAtEveryHeight() {
        let overlap = IslandGlassPolicy.rampOverlap
        let length = overlap + IslandGlassPolicy.fadeLength
        let stops = IslandGlassPolicy.rampStops
        let curve = IslandGlassPolicy.fadeCurve
        #expect(stops.count == curve.count + 1)
        for shellHeight: CGFloat in [64, 160, 260, 440] {
            let fade = IslandGlassPolicy.fade(bandHeight: band, shellHeight: shellHeight)
            let rampTop = fade.start - overlap
            for index in curve.indices {
                let expected = fade.start + IslandGlassPolicy.fadeLength * CGFloat(index) / CGFloat(curve.count - 1)
                #expect(abs(rampTop + stops[index + 1].location * length - expected) < 0.001)
            }
        }
        // The solid black above stops inside the ramp's solid top, so no
        // seam shows between them.
        #expect(overlap > 0)
        #expect(stops[1].location * length >= overlap / 2)
    }

    @Test func higherLevelsShowMoreOfTheDesktop() {
        let low = IslandGlassPolicy.floorOpacity(level: 0)
        let middle = IslandGlassPolicy.floorOpacity(level: 0.5)
        let high = IslandGlassPolicy.floorOpacity(level: 1)
        #expect(high < middle)
        #expect(middle < low)
        #expect(abs(high - IslandGlassPolicy.floorOpacityRange.lowerBound) < 0.000_001)
        #expect(abs(low - IslandGlassPolicy.floorOpacityRange.upperBound) < 0.000_001)
    }

    @Test func outOfRangeInputIsClamped() {
        #expect(IslandGlassPolicy.floorOpacity(level: 7) == IslandGlassPolicy.floorOpacity(level: 1))
        #expect(IslandGlassPolicy.floorOpacity(level: -2) == IslandGlassPolicy.floorOpacity(level: 0))
        #expect(IslandGlassPolicy.fade(bandHeight: -1, shellHeight: height)
            == IslandGlassPolicy.fade(bandHeight: 0, shellHeight: height))
        #expect(IslandGlassPolicy.fade(bandHeight: band, shellHeight: -5).start >= 0)
    }
}
