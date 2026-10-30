import Foundation
import Testing

@testable import NotchShotKit

@Suite("File drop action tray")
struct FileDropActionTests {
    @Test("The tray keeps a stable left-to-right action order")
    func actionOrder() {
        #expect(FileDropContext.files.actions == [.shelf, .airDrop, .share, .localSend, .compress])
        #expect(FileDropContext.archives.actions == [.shelf, .airDrop, .share, .localSend, .extract])
        #expect(FileDropContext.apps.actions == [.uninstall, .resetApp])
    }

    @Test("What is dragged decides the destinations")
    func contextClassification() {
        let app = URL(fileURLWithPath: "/Applications/Example.app")
        let zip = URL(fileURLWithPath: "/tmp/Photos.zip")
        let tarball = URL(fileURLWithPath: "/tmp/src.tar.gz")
        let text = URL(fileURLWithPath: "/tmp/Notes.txt")
        #expect(FileDropContext.classify([app]) == .apps)
        #expect(FileDropContext.classify([zip, tarball]) == .archives)
        #expect(FileDropContext.classify([zip, text]) == .files)
        #expect(FileDropContext.classify([app, text]) == .files)
        #expect(FileDropContext.classify([]) == .files)
        #expect(FileDropContext.apps.defaultAction == .uninstall)
    }

    @Test("App drags split the tray in two")
    func appSelection() {
        let actions = FileDropContext.apps.actions
        #expect(FileDropActionSelection.action(atX: 249, width: 500, actions: actions) == .uninstall)
        #expect(FileDropActionSelection.action(atX: 250, width: 500, actions: actions) == .resetApp)
        #expect(FileDropActionSelection.adjacent(to: .uninstall, delta: 1, actions: actions) == .resetApp)
        #expect(FileDropActionSelection.adjacent(to: .resetApp, delta: 1, actions: actions) == .resetApp)
        // An action from another context snaps to this context's first.
        #expect(FileDropActionSelection.adjacent(to: .shelf, delta: 1, actions: actions) == .uninstall)
    }

    @Test("Each fifth of the tray selects its visible destination")
    func horizontalSelection() {
        let width: CGFloat = 500
        #expect(FileDropActionSelection.action(atX: 0, width: width) == .shelf)
        #expect(FileDropActionSelection.action(atX: 99.9, width: width) == .shelf)
        #expect(FileDropActionSelection.action(atX: 100, width: width) == .airDrop)
        #expect(FileDropActionSelection.action(atX: 200, width: width) == .share)
        #expect(FileDropActionSelection.action(atX: 300, width: width) == .localSend)
        #expect(FileDropActionSelection.action(atX: 400, width: width) == .compress)
        #expect(FileDropActionSelection.action(atX: 500, width: width) == .compress)
    }

    @Test("Out-of-bounds and malformed geometry fall back safely")
    func selectionFallbacks() {
        #expect(FileDropActionSelection.action(atX: -20, width: 400) == .shelf)
        #expect(FileDropActionSelection.action(atX: 900, width: 500) == .compress)
        #expect(FileDropActionSelection.action(atX: .nan, width: 400) == .shelf)
        #expect(FileDropActionSelection.action(atX: 40, width: 0) == .shelf)
        #expect(FileDropActionSelection.action(atX: 40, width: .infinity) == .shelf)
    }

    @Test("Keyboard and accessibility movement follows the visible order")
    func adjacentSelection() {
        #expect(FileDropActionSelection.adjacent(to: .shelf, delta: -1) == .shelf)
        #expect(FileDropActionSelection.adjacent(to: .shelf, delta: 1) == .airDrop)
        #expect(FileDropActionSelection.adjacent(to: .airDrop, delta: 1) == .share)
        #expect(FileDropActionSelection.adjacent(to: .share, delta: 1) == .localSend)
        #expect(FileDropActionSelection.adjacent(to: .compress, delta: 1) == .compress)
    }

    @Test("The dedicated drop layout fits the panel budget")
    func layoutFits() {
        let metrics = NotchMetrics(
            screenFrame: CGRect(x: 0, y: 0, width: 1_512, height: 982),
            hasPhysicalNotch: true,
            notchSize: CGSize(width: 250, height: 37),
            menuBarHeight: 37
        )
        let layout = NotchLayout.layout(
            for: .fileDrop,
            metrics: metrics,
            isPeeking: false,
            resultCount: 5
        )

        #expect(layout.size.width >= 500)
        #expect(layout.size.width <= NotchLayout.maximumSize.width)
        #expect(layout.size.height <= NotchLayout.maximumSize.height)
        // The count and the instruction sit beside the camera, the targets
        // below it, with no empty strip above them.
        #expect(layout.wrapsCamera)
        #expect(layout.contentTopInset == 0)
        let wing = (layout.size.width - metrics.notchSize.width - IslandCameraBand.cameraClearance) / 2
        #expect(wing >= NotchLayout.fileDropWing)
    }

    @Test("The Shelf target parks a supported document instead of summarizing it")
    @MainActor
    func shelfTargetParksDocument() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = directory.appendingPathComponent("Notes.txt")
        try Data("A document that could otherwise be summarized.".utf8).write(to: document)

        let previousDuration = Preferences.shared.shelfDuration
        Preferences.shared.shelfDuration = .never
        defer { Preferences.shared.shelfDuration = previousDuration }

        let coordinator = AppCoordinator()
        coordinator.performFileDropAction(.shelf, urls: [document], expectedItemCount: 1)

        let item = try #require(coordinator.shelfItems.first)
        #expect(coordinator.shelfItems.count == 1)
        #expect(item.asset.url == document.standardizedFileURL)
        #expect(item.asset.kind == .document)
        #expect(item.asset.ownership == .externalReference)
        #expect(coordinator.activity == .result)
    }

    @Test("An incompletely loaded drag is rejected before any file is parked")
    @MainActor
    func partialProviderLoadIsAllOrNothing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Only one.txt")
        try Data("one".utf8).write(to: file)

        let coordinator = AppCoordinator()
        coordinator.performFileDropAction(.shelf, urls: [file], expectedItemCount: 2)

        #expect(coordinator.shelfItems.isEmpty)
        if case .error = coordinator.activity {
            // Expected: the error is visible rather than silently parking a
            // partial selection.
        } else {
            Issue.record("An incomplete drag should produce a visible error")
        }
        coordinator.dismissError()
    }
}
