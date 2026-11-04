import AppKit
import Foundation
import Testing
@testable import NotchShotKit

@Suite("Island layout inputs")
struct NotchLayoutInputsTests {
    private static let notched = NotchMetrics(
        screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        hasPhysicalNotch: true,
        notchSize: CGSize(width: 185, height: 32),
        menuBarHeight: 32
    )

    private func inputs(
        activity: NotchActivity,
        isActiveDisplay: Bool = true,
        isPeeking: Bool = false,
        resultCount: Int = 0,
        shelfStyle: ShelfPresentationStyle = .detail,
        isScrollingCapture: Bool = false,
        tabPageHeightHold: CGFloat = 0
    ) -> NotchLayoutInputs {
        NotchLayoutInputs(
            activity: activity,
            isActiveDisplay: isActiveDisplay,
            isPeeking: isPeeking,
            resultCount: resultCount,
            hasStack: false,
            mediaPanelRows: 0,
            shelfStyle: shelfStyle,
            indicatorWings: false,
            isScrollingCapture: isScrollingCapture,
            tabPageHeightHold: tabPageHeightHold,
            tabs: NotchTab.allCases
        )
    }

    private func height(_ activity: NotchActivity, _ inputs: NotchLayoutInputs) -> CGFloat {
        NotchLayout.layout(for: activity, metrics: Self.notched, inputs: inputs).size.height
    }

    @Test("A scrolling capture's button row is inside the layout the click region comes from")
    func scrollingCaptureRow() {
        let activity = NotchActivity.processing("Scroll")
        let band = Self.notched.notchSize.height
        #expect(height(activity, inputs(activity: activity)) == band + NotchLayout.statusLip)
        #expect(height(activity, inputs(activity: activity, isScrollingCapture: true)) == band + 50)
    }

    @Test("The shelf's click region follows its grid or detail style")
    func shelfStyle() {
        let band = Self.notched.notchSize.height
        for count in [1, 2, 5] {
            let grid = height(.result, inputs(activity: .result, resultCount: count, shelfStyle: .grid))
            #expect(grid == band + NotchLayout.shelfContentHeight(style: .grid, itemCount: count, hasStack: false))
            let detail = height(.result, inputs(activity: .result, resultCount: count, shelfStyle: .detail))
            #expect(detail == band + NotchLayout.shelfContentHeight(style: .detail, itemCount: count, hasStack: false))
        }
        #expect(
            height(.result, inputs(activity: .result, resultCount: 2, shelfStyle: .grid))
                != height(.result, inputs(activity: .result, resultCount: 2, shelfStyle: .detail))
        )
    }

    @Test("Only the display the user is on peeks or holds a page's height")
    func passiveDisplay() {
        let held = inputs(activity: .result, tabPageHeightHold: 300)
        #expect(held.heldHeight == 300)
        let passive = inputs(activity: .result, isActiveDisplay: false, isPeeking: true, tabPageHeightHold: 300)
        #expect(passive.heldHeight == 0)
        #expect(!passive.isPeeking)
        #expect(inputs(activity: .idle, isPeeking: true).isPeeking)
    }

    @Test("A held height applies only to the pill's own pages")
    func holdOnlyOnPages() {
        #expect(inputs(activity: .idle, tabPageHeightHold: 300).heldHeight == 0)
        #expect(inputs(activity: .media, tabPageHeightHold: 300).heldHeight == 0)
    }
}

@Suite("Extras preferences loading")
@MainActor
struct ExtrasPreferencesLoadingTests {
    private static let shareLinkKey = "notchshot.extras.shareLink"

    private func suite() -> UserDefaults {
        TestDefaults.suite("notchshot.tests.\(UUID().uuidString)")
    }

    private func storedExtrasKeys(_ defaults: UserDefaults) -> [String] {
        defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("notchshot.extras.") }
    }

    @Test("Loading writes nothing back")
    func loadingIsReadOnly() {
        let defaults = suite()
        _ = ExtrasPreferences(defaults: defaults)
        #expect(storedExtrasKeys(defaults).isEmpty)
    }

    @Test("A change after loading is still saved")
    func changesAreSaved() {
        let defaults = suite()
        let extras = ExtrasPreferences(defaults: defaults)
        extras.copiesShareLinkAfterUpload = false
        #expect(defaults.object(forKey: "notchshot.extras.shareLinkCopies") as? Bool == false)
    }

    @Test("A share-link value that can't be decoded survives a launch")
    func undecodableShareLinkIsKept() {
        let defaults = suite()
        let garbage = Data("{not json".utf8)
        defaults.set(garbage, forKey: Self.shareLinkKey)
        let extras = ExtrasPreferences(defaults: defaults)
        #expect(extras.shareLink == ShareLinkConfiguration())
        #expect(defaults.data(forKey: Self.shareLinkKey) == garbage)
    }

    @Test("A stored share link missing a newer field keeps what it has")
    func missingFieldKeepsConfiguration() throws {
        let defaults = suite()
        let stored = try JSONSerialization.data(withJSONObject: [
            "endpoint": "https://example.r2.cloudflarestorage.com",
            "bucket": "shots",
            "accessKeyID": "KEY",
        ])
        defaults.set(stored, forKey: Self.shareLinkKey)
        let link = ExtrasPreferences(defaults: defaults).shareLink
        #expect(link.endpoint == "https://example.r2.cloudflarestorage.com")
        #expect(link.bucket == "shots")
        #expect(link.accessKeyID == "KEY")
        #expect(link.region == ShareLinkConfiguration().region)
        #expect(link.randomizesNames == ShareLinkConfiguration().randomizesNames)
        #expect(defaults.data(forKey: Self.shareLinkKey) == stored)
    }

    @Test("A complete stored share link round-trips")
    func completeShareLinkRoundTrips() throws {
        let defaults = suite()
        var link = ShareLinkConfiguration()
        link.endpoint = "https://s3.example.com"
        link.usesPathStyle = false
        defaults.set(try JSONEncoder().encode(link), forKey: Self.shareLinkKey)
        #expect(ExtrasPreferences(defaults: defaults).shareLink == link)
    }
}

@Suite("Output folder fallback")
@MainActor
struct OutputFolderFallbackTests {
    @Test("A bookmark that won't resolve falls back to the Desktop, on every read")
    func unresolvableBookmark() {
        let preferences = Preferences(defaults: TestDefaults.suite("notchshot.tests.\(UUID().uuidString)"))
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        preferences.outputFolderBookmark = Data([1, 2, 3])
        #expect(preferences.outputFolder == desktop)
        #expect(preferences.outputFolder == desktop)
    }
}

@Suite("Fixes with a small pure core")
struct AuditNov2026FX5PureTests {
    @Test("A dragged file's pull moves in eighths and keeps its dead zone and sign")
    func steppedPull() {
        for x in stride(from: CGFloat(0), through: 400, by: 7) {
            let pull = FileDropPullPolicy.steppedPull(x: x, width: 400)
            #expect((pull * 8).rounded() == pull * 8)
            #expect(abs(pull - FileDropPullPolicy.pull(x: x, width: 400)) <= 1.0 / 16)
        }
        #expect(FileDropPullPolicy.steppedPull(x: 200, width: 400) == 0)
        #expect(FileDropPullPolicy.steppedPull(x: 0, width: 400) == -1)
        #expect(FileDropPullPolicy.steppedPull(x: 400, width: 400) == 1)
    }

    @Test("The notification line limit is not stale when the message changes")
    func bodyLineLimitFollowsTheMessage() {
        let short = SystemNotificationSnapshot(sourceName: "Mail", title: "A", body: "Short")
        let long = SystemNotificationSnapshot(
            sourceName: "Mail",
            title: "A",
            body: String(repeating: "A long message that needs a second line. ", count: 6)
        )
        for _ in 0 ..< 2 {
            #expect(SystemNotificationCardLayout.bodyLineLimit(for: short) == 1)
            #expect(SystemNotificationCardLayout.bodyLineLimit(for: long) == 2)
        }
    }

    @Test("An external file reports the size recorded when it came in, without a stat")
    func externalFileSize() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchShotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("note.txt")
        try Data("12345".utf8).write(to: file)

        let external = CaptureAsset(url: file, kind: .text, pixelSize: .zero, ownership: .externalReference)
        let owned = CaptureAsset(url: file, kind: .text, pixelSize: .zero, ownership: .userDocument)
        try Data("1234567890".utf8).write(to: file)

        #expect(external.fileSize == 5)
        #expect(owned.fileSize == 10)
    }

    @Test("A process wait returns once the child has exited, however long it ran")
    func processWait() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0.3"]
        try process.run()
        await process.waitForExit()
        #expect(!process.isRunning)
        #expect(process.terminationStatus == 0)
    }

    @MainActor
    @Test("The month grid has one today and a full six weeks")
    func monthOverview() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        calendar.firstWeekday = 2
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 12)))
        let month = MonthOverview(now: now, calendar: calendar)
        #expect(month.cells.count == 42)
        #expect(month.cells.compactMap { $0 }.count == 30)
        #expect(month.cells.compactMap { $0 }.filter(\.isToday).count == 1)
        #expect(month.weekdaySymbols.count == 7)
        // Nov 1 2026 is a Sunday: six blanks before it in a Monday-first week.
        #expect(month.cells.prefix(6).allSatisfy { $0 == nil })
        #expect(month.cells[6] != nil)
    }
}
