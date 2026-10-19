import Testing
@testable import NotchShotKit

@Suite("Hide in apps")
struct NotchAppVisibilityPolicyTests {
    private let hidden: Set<String> = ["com.valvesoftware.steam", "org.videolan.vlc"]

    @Test func hidesWhileAListedAppIsFrontmost() {
        #expect(NotchAppVisibilityPolicy.hidesNotch(
            frontmostBundleID: "org.videolan.vlc",
            hiddenBundleIDs: hidden,
            ownBundleID: "com.notchshot.app"
        ))
    }

    @Test func showsForUnlistedOrUnknownApps() {
        #expect(!NotchAppVisibilityPolicy.hidesNotch(
            frontmostBundleID: "com.apple.Safari",
            hiddenBundleIDs: hidden,
            ownBundleID: "com.notchshot.app"
        ))
        #expect(!NotchAppVisibilityPolicy.hidesNotch(
            frontmostBundleID: nil,
            hiddenBundleIDs: hidden,
            ownBundleID: "com.notchshot.app"
        ))
        #expect(!NotchAppVisibilityPolicy.hidesNotch(
            frontmostBundleID: "",
            hiddenBundleIDs: [""],
            ownBundleID: "com.notchshot.app"
        ))
    }

    /// NotchShot comes forward for captures and Settings; hiding then would
    /// take the notch away exactly when it is in use.
    @Test func neverHidesForNotchShotItself() {
        #expect(!NotchAppVisibilityPolicy.hidesNotch(
            frontmostBundleID: "com.notchshot.app",
            hiddenBundleIDs: ["com.notchshot.app"],
            ownBundleID: "com.notchshot.app"
        ))
    }
}
