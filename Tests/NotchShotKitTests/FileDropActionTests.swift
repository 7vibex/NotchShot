import Foundation
import Testing

@testable import NotchShotKit

@Suite("File drop action tray")
struct FileDropActionTests {
    @Test("The tray keeps a stable left-to-right action order")
    func actionOrder() {
        #expect(FileDropAction.allCases == [.shelf, .airDrop, .share, .compress])
    }

    @Test("Each quarter of the tray selects its visible destination")
    func horizontalSelection() {
        let width: CGFloat = 400
        #expect(FileDropActionSelection.action(atX: 0, width: width) == .shelf)
        #expect(FileDropActionSelection.action(atX: 99.9, width: width) == .shelf)
        #expect(FileDropActionSelection.action(atX: 100, width: width) == .airDrop)
        #expect(FileDropActionSelection.action(atX: 200, width: width) == .share)
        #expect(FileDropActionSelection.action(atX: 300, width: width) == .compress)
        #expect(FileDropActionSelection.action(atX: 400, width: width) == .compress)
    }

    @Test("Out-of-bounds and malformed geometry fall back safely")
    func selectionFallbacks() {
        #expect(FileDropActionSelection.action(atX: -20, width: 400) == .shelf)
        #expect(FileDropActionSelection.action(atX: 900, width: 400) == .compress)
        #expect(FileDropActionSelection.action(atX: .nan, width: 400) == .shelf)
        #expect(FileDropActionSelection.action(atX: 40, width: 0) == .shelf)
        #expect(FileDropActionSelection.action(atX: 40, width: .infinity) == .shelf)
    }

    @Test("Keyboard and accessibility movement follows the visible order")
    func adjacentSelection() {
        #expect(FileDropActionSelection.adjacent(to: .shelf, delta: -1) == .shelf)
        #expect(FileDropActionSelection.adjacent(to: .shelf, delta: 1) == .airDrop)
        #expect(FileDropActionSelection.adjacent(to: .airDrop, delta: 1) == .share)
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

        #expect(layout.size.width == 500)
        #expect(layout.size.width <= NotchLayout.maximumSize.width)
        #expect(layout.size.height <= NotchLayout.maximumSize.height)
        #expect(layout.contentTopInset == metrics.notchSize.height)
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
