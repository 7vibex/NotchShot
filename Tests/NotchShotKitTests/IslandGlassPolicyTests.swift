import Testing
@testable import NotchShotKit

@Suite("Glass notch")
struct IslandGlassPolicyTests {
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
        for level in stride(from: 0.0, through: 1.0, by: 0.25) {
            #expect(IslandGlassPolicy.fade(level: level, solidBandFraction: 0.2).start >= 0.2)
        }
        #expect(IslandGlassPolicy.fade(level: 1, solidBandFraction: 0.2).start == 0.2)
    }

    @Test func higherLevelsShowMoreGlass() {
        let low = IslandGlassPolicy.fade(level: 0, solidBandFraction: 0.1)
        let high = IslandGlassPolicy.fade(level: 1, solidBandFraction: 0.1)
        #expect(high.start < low.start)
        #expect(high.bottomOpacity < low.bottomOpacity)
        // White notch ink stays readable even at the clearest setting.
        #expect(high.bottomOpacity >= IslandGlassPolicy.bottomOpacityRange.lowerBound)
    }

    @Test func outOfRangeInputIsClamped() {
        #expect(IslandGlassPolicy.fade(level: 7, solidBandFraction: 0) == IslandGlassPolicy.fade(level: 1, solidBandFraction: 0))
        #expect(IslandGlassPolicy.fade(level: -2, solidBandFraction: -1) == IslandGlassPolicy.fade(level: 0, solidBandFraction: 0))
    }
}
