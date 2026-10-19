import CoreGraphics
import Testing
@testable import NotchShotKit

@Suite("Notch tab pill")
struct NotchTabTests {
    private let metrics = NotchMetrics(
        screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        hasPhysicalNotch: true,
        notchSize: CGSize(width: 185, height: 32),
        menuBarHeight: 37
    )

    @Test("Only an open page owns a tab")
    func pagesMapToTabs() {
        #expect(NotchTab.current(for: .expanded) == .capture)
        #expect(NotchTab.current(for: .result) == .shelf)
        let player = IslandLayoutDescriptor(
            primaryID: IslandActivityID(kind: .media, key: "now-playing"),
            level: .expanded
        )
        #expect(NotchTab.current(for: .island(player)) == .nowPlaying)

        var compact = player
        compact.level = .compact
        #expect(NotchTab.current(for: .island(compact)) == nil)
        let timer = IslandLayoutDescriptor(primaryID: IslandActivityID(kind: .timer, key: "focus"), level: .expanded)
        #expect(NotchTab.current(for: .island(timer)) == nil)
        #expect(NotchTab.current(for: .idle) == nil)
        #expect(NotchTab.current(for: .media) == nil)
        #expect(NotchTab.current(for: .recording) == nil)
    }

    @Test("The pill hangs centred just under the island, inside the panel")
    func geometry() throws {
        let layout = NotchLayout.layout(for: .expanded, metrics: metrics, isPeeking: false, resultCount: 0)
        let island = layout.primaryRect(in: metrics)
        let pill = try #require(NotchTabBarGeometry.rect(below: layout, in: metrics, tabCount: 4))
        #expect(pill.midX == metrics.notchCenterX)
        #expect(abs(island.minY - pill.maxY - NotchTabBarGeometry.gap) < 0.001)
        #expect(pill.size == CGSize(width: 184, height: 34))
    }

    @Test("Dropping the fourth tab narrows the pill instead of stretching three")
    func threeTabWidth() throws {
        let layout = NotchLayout.layout(for: .expanded, metrics: metrics, isPeeking: false, resultCount: 0)
        let pill = try #require(NotchTabBarGeometry.rect(below: layout, in: metrics, tabCount: 3))
        #expect(pill.width == 139)
        #expect(pill.midX == metrics.notchCenterX)
    }

    @Test("The last slot is the user's: agents by default, clipboard, or nothing")
    func lastSlot() {
        #expect(NotchTab.visible(lastSlot: .agents) == [.capture, .shelf, .nowPlaying, .agents])
        #expect(NotchTab.visible(lastSlot: .clipboard) == [.capture, .shelf, .nowPlaying, .clipboard])
        #expect(NotchTab.visible(lastSlot: .none) == [.capture, .shelf, .nowPlaying])
    }

    @Test("The expanded agents page owns the Agents tab only while it is in the pill")
    func agentsPage() {
        let agents = IslandLayoutDescriptor(primaryID: IslandActivityID(kind: .ai, key: "agents"), level: .expanded)
        #expect(NotchTab.current(for: .island(agents)) == .agents)
        #expect(NotchTab.current(for: .island(agents), in: NotchTab.visible(lastSlot: .agents)) == .agents)
        #expect(NotchTab.current(for: .island(agents), in: NotchTab.visible(lastSlot: .none)) == nil)
        #expect(NotchTab.current(for: .island(agents), in: NotchTab.visible(lastSlot: .clipboard)) == nil)
        // The fixed pages never depend on the last slot.
        #expect(NotchTab.current(for: .expanded, in: NotchTab.visible(lastSlot: .none)) == .capture)

        var compact = agents
        compact.level = .compact
        #expect(NotchTab.current(for: .island(compact)) == nil)
    }

    @Test("A full-height island leaves no room, so no pill")
    func noRoom() {
        var layout = NotchLayout.layout(for: .expanded, metrics: metrics, isPeeking: false, resultCount: 0)
        layout.size.height = NotchLayout.maximumSize.height
        #expect(NotchTabBarGeometry.topOffset(below: layout) == nil)
    }
}
