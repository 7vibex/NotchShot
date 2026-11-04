import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import Testing
@testable import NotchShotKit

@Suite("Pin links never reach past this Mac before consent")
struct PinPathLocalityTests {
    private let mounts = [
        PinPathLocality.Mount(path: "/", isLocal: true),
        PinPathLocality.Mount(path: "/System/Volumes/Data", isLocal: true),
        PinPathLocality.Mount(path: "/System/Volumes/Data/home", isLocal: false),
        PinPathLocality.Mount(path: "/Volumes/Share", isLocal: false),
        PinPathLocality.Mount(path: "/Volumes/Backup", isLocal: true),
    ]

    @Test("Automount roots are refused from the text alone, however they are spelled", arguments: [
        "/net/some.host/share/x.png",
        "/NET/some.host/x.png",
        "/Network/Servers/x.png",
        "/home/someone/x.png",
        "/tmp/../net/some.host/x.png",
        "/Users/me/../../net/some.host/x.png",
        "/System/Volumes/Data/home/someone/x.png",
        "/private/var/automount/Network/x.png",
    ])
    func automountRoots(path: String) {
        #expect(!PinPathLocality.isLocal(path: path, mounts: mounts))
    }

    @Test("A network volume is refused by its mount, and the nearest mount decides")
    func networkVolume() {
        #expect(!PinPathLocality.isLocal(path: "/Volumes/Share/x.png", mounts: mounts))
        #expect(PinPathLocality.isLocal(path: "/Volumes/Share2/x.png", mounts: mounts))
        #expect(PinPathLocality.isLocal(path: "/Volumes/Backup/x.png", mounts: mounts))
        #expect(PinPathLocality.isLocal(path: "/Users/me/x.png", mounts: mounts))
    }

    @Test("A path no known mount covers is not assumed to be local")
    func unknownMount() {
        #expect(!PinPathLocality.isLocal(path: "/Users/me/x.png", mounts: []))
    }

    @Test("The live mount table reads and covers the temporary folder")
    func liveMountTable() throws {
        let mounts = try #require(PinPathLocality.currentMounts())
        #expect(PinPathLocality.isLocal(path: NSTemporaryDirectory(), mounts: mounts))
    }

    @Test("The router refuses a remote path in either form", arguments: [
        "notchshot://pin?file=/net/some.host/x.png",
        "notchshot://pin?file=file:///net/some.host/x.png",
        "notchshot://pin?file=/tmp/../net/some.host/x.png",
    ])
    func routerRefusal(link: String) throws {
        let url = try #require(URL(string: link))
        #expect(throws: NotchShotURLRouterError.invalidParameter("file")) {
            _ = try NotchShotURLRouter.parse(url)
        }
    }

    @Test("A sibling of the home folder is not abbreviated to a tilde")
    func siblingOfHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let sibling = NotchShotURLCommand.pinFile(URL(filePath: home + "2/x.png", directoryHint: .notDirectory))
        let inside = NotchShotURLCommand.pinFile(URL(filePath: home + "/x.png", directoryHint: .notDirectory))
        #expect(sibling.externalURLConsentDescription.contains(home + "2/x.png"))
        #expect(inside.externalURLConsentDescription.contains("~/x.png"))
    }
}

@Suite("A removed shortcut stays removed")
struct RemovedShortcutTests {
    private let combination = HotKeyBinding(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | shiftKey | optionKey))

    @Test("A new action gets its default once, and clearing it afterwards sticks")
    func installedOnce() {
        var bindings: [HotKeyAction: HotKeyBinding] = [:]
        var installed = Set(HotKeyAction.allCases).subtracting([.saveInstantReplay])

        #expect(HotKeyAction.installNewDefaults(into: &bindings, installed: &installed))
        #expect(bindings[.saveInstantReplay] == HotKeyAction.saveInstantReplay.defaultBinding)
        #expect(bindings.count == 1)

        bindings[.saveInstantReplay] = nil
        #expect(!HotKeyAction.installNewDefaults(into: &bindings, installed: &installed))
        #expect(bindings[.saveInstantReplay] == nil)
    }

    @Test("A default whose combination is already held is skipped, not doubled")
    func combinationTaken() {
        var bindings: [HotKeyAction: HotKeyBinding] = [.showShelf: combination]
        var installed = Set(HotKeyAction.allCases).subtracting([.saveInstantReplay])

        #expect(!HotKeyAction.installNewDefaults(into: &bindings, installed: &installed))
        #expect(bindings[.saveInstantReplay] == nil)
        #expect(bindings[.showShelf] == combination)
        #expect(installed.contains(.saveInstantReplay))
    }

    @Test("A shortcut the user already chose keeps winning")
    func customKept() {
        let custom = HotKeyBinding(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey | optionKey))
        var bindings: [HotKeyAction: HotKeyBinding] = [.saveInstantReplay: custom]
        var installed: Set<HotKeyAction> = []

        _ = HotKeyAction.installNewDefaults(into: &bindings, installed: &installed)
        #expect(bindings[.saveInstantReplay] == custom)
        #expect(installed == Set(HotKeyAction.allCases))
    }

    @Test("Take-over claims an empty clipboard action until the user clears it")
    func takeoverRespectsClearing() {
        let action = HotKeyAction.captureAreaToClipboard
        #expect(action.canClaimSystemShortcut(current: nil, cleared: []))
        #expect(!action.canClaimSystemShortcut(current: nil, cleared: [action]))
    }

    @Test("Take-over still leaves alone a shortcut the user picked")
    func takeoverLeavesCustom() {
        let custom = HotKeyBinding(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey | optionKey))
        #expect(!HotKeyAction.captureArea.canClaimSystemShortcut(current: custom, cleared: []))
        #expect(HotKeyAction.captureArea.canClaimSystemShortcut(
            current: HotKeyAction.captureArea.defaultBinding,
            cleared: []
        ))
    }
}

@Suite("Comma-separated settings fields")
@MainActor
struct CommaSeparatedFieldTests {
    @Test("Parsing drops the separators and empty entries, and keeps inner spaces")
    func parsing() {
        #expect(CommaSeparatedTextField.parse("foo, bar") == ["foo", "bar"])
        #expect(CommaSeparatedTextField.parse("foo,") == ["foo"])
        #expect(CommaSeparatedTextField.parse("new york , ") == ["new york"])
        #expect(CommaSeparatedTextField.parse("") == [])
    }
}

@Suite("Signed bundle configuration")
struct SignedBundleConfigurationTests {
    private static let resources = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Resources", isDirectory: true)

    @Test("Both signing paths can reach Calendar under the Hardened Runtime", arguments: [
        "NotchShot.entitlements",
        "NotchShot-AdHoc.entitlements",
    ])
    func calendarEntitlement(file: String) throws {
        let data = try Data(contentsOf: Self.resources.appendingPathComponent(file))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        #expect(plist?["com.apple.security.personal-information.calendars"] as? Bool == true)
    }
}

@Suite("Audit Nov 2026: review repairs")
@MainActor
struct AuditNov2026ReviewRepairTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-repair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func lock(_ url: URL) throws {
        try #require(chflags(url.path, UInt32(UF_IMMUTABLE)) == 0)
    }

    private func unlock(_ url: URL) {
        chflags(url.path, 0)
    }

    private func flags(of url: URL) throws -> UInt32 {
        var information = stat()
        try #require(lstat(url.path, &information) == 0)
        return information.st_flags
    }

    // MARK: Files

    @Test("A snapshot of a Finder-locked file is a normal copy")
    func lockedFileSnapshot() throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("locked.png")
        let destination = directory.appendingPathComponent("snapshot.png")
        defer {
            unlock(source)
            unlock(destination)
            try? FileManager.default.removeItem(at: directory)
        }
        try Data("captured".utf8).write(to: source)
        let identity = try #require(SafeAssetFile.identity(at: source, maximumBytes: 1_024))
        try lock(source)

        try SafeAssetFile.copyVerified(
            from: source,
            expectedIdentity: identity,
            maximumBytes: 1_024,
            to: destination,
            mode: 0o600
        )

        #expect(try Data(contentsOf: destination) == Data("captured".utf8))
        #expect(try flags(of: destination) & UInt32(UF_IMMUTABLE) == 0)
        #expect(try FileManager.default.removeItem(at: destination) == ())
    }

    @Test("A move that has to copy never leaves a file under the real name when it fails")
    func failedCopyLeavesNothingBehind() throws {
        let directory = try temporaryDirectory()
        let folder = directory.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("Shot.png")
        defer {
            unlock(source)
            try? FileManager.default.removeItem(at: directory)
        }
        try Data("captured".utf8).write(to: source)
        let asset = CaptureAsset(
            url: source,
            kind: .screenshot,
            pixelSize: .zero,
            ownership: .userDocument
        )
        // A locked file refuses the rename and then the removal, so this takes
        // the copy path and fails at the end of it.
        try lock(source)

        #expect(throws: ShelfFileOperations.OperationError.self) {
            try ShelfFileOperations.move(asset, toFolder: folder)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test("Publishing a join refuses to replace a file that took the name")
    func joinPublishKeepsOtherFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staging = directory.appendingPathComponent("output.mp4")
        let destination = directory.appendingPathComponent("Recording.mp4")
        try Data("joined".utf8).write(to: staging)
        try Data("somebody else's".utf8).write(to: destination)

        let published = try RecordingSegmentJoiner.publish(staging, to: destination)

        #expect(published != destination)
        #expect(published.deletingLastPathComponent() == destination.deletingLastPathComponent())
        #expect(try Data(contentsOf: published) == Data("joined".utf8))
        #expect(try Data(contentsOf: destination) == Data("somebody else's".utf8))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test("Publishing a join to a free name lands there")
    func joinPublishFreeName() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staging = directory.appendingPathComponent("output.mp4")
        let destination = directory.appendingPathComponent("Recording.mp4")
        try Data("joined".utf8).write(to: staging)
        #expect(try RecordingSegmentJoiner.publish(staging, to: destination) == destination)
    }

    // MARK: Quit

    @Test("Waiting for file work covers what is running and what starts meanwhile")
    func fileWorkWait() async {
        let tracker = FileWorkTracker()
        await tracker.waitUntilIdle()
        let gate = AsyncStream.makeStream(of: Void.self)
        var finished: [String] = []
        tracker.run {
            for await _ in gate.stream {}
            finished.append("first")
            tracker.run { finished.append("second") }
        }
        #expect(!tracker.isIdle)
        let waiter = Task { @MainActor in
            await tracker.waitUntilIdle()
            return finished
        }
        await Task.yield()
        #expect(finished.isEmpty)
        gate.continuation.finish()
        #expect(await waiter.value == ["first", "second"])
        #expect(tracker.isIdle)
    }

    // MARK: Saving a project

    @Test("A queued background save doesn't land on top of a newer one")
    func projectSaveOrder() {
        let order = ProjectSaveOrder()
        var writes: [String] = []
        let background = order.claim()
        order.write(ifCurrent: order.claim()) { writes.append("newer") }
        order.write(ifCurrent: background) { writes.append("older") }
        #expect(writes == ["newer"])
        #expect(!order.isCurrent(background))
    }

    // MARK: Annotation

    private func controller() -> AnnotationDocumentController {
        AnnotationDocumentController(
            source: TestImage.solid(width: 100, height: 100),
            document: AnnotationDocument(sourcePixelSize: CGSize(width: 100, height: 100))
        )
    }

    private func textElement(_ text: String) -> AnnotationElement {
        AnnotationElement(kind: .text, points: [CGPoint(x: 10, y: 10)], style: AnnotationStyle(), text: text)
    }

    @Test("A text element never typed in goes away with its undo step")
    func emptyTextIsRemoved() {
        let controller = controller()
        let empty = textElement("")
        controller.add(empty)
        controller.removeIfEmptyText(id: empty.id)
        #expect(controller.document.elements.isEmpty)
        #expect(!controller.canUndo)

        let written = textElement("kept")
        controller.add(written)
        controller.removeIfEmptyText(id: written.id)
        #expect(controller.document.elements.count == 1)
        #expect(controller.canUndo)
    }

    @Test("Preview layers keep the export's stacking order")
    func highlighterRuns() {
        func element(_ kind: AnnotationKind) -> AnnotationElement {
            AnnotationElement(kind: kind, points: [.zero, CGPoint(x: 5, y: 5)], style: AnnotationStyle())
        }
        let elements: [AnnotationElement] = [
            element(.arrow), element(.highlighter), element(.highlighter), element(.rectangle),
        ]
        let runs = AnnotationElement.highlighterRuns(in: elements)
        #expect(runs.map(\.count) == [1, 2, 1])
        #expect(runs.flatMap { $0 }.map(\.id) == elements.map(\.id))
        #expect(AnnotationElement.highlighterRuns(in: []).isEmpty)
    }

    // MARK: Dictation

    @Test("A field that only timed out on its selection doesn't get keystrokes")
    func slowFieldGoesToTheClipboard() {
        typealias State = TextInsertionService.TextFieldState
        let selection = NSRange(location: 0, length: 0)
        #expect(TextInsertionService.outcomeBeforeInserting(with: State(selectionTimedOut: true)) == .unverifiable)
        #expect(TextInsertionService.outcomeBeforeInserting(with: State()) == .rejected)
        #expect(TextInsertionService.outcomeBeforeInserting(with: State(selection: selection)) == nil)
    }

    @Test("Cancel stops an insertion before anything lands")
    func cancelledInsertionDeliversNothing() async {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("notchshot-repair-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let before = pasteboard.changeCount
        let service = TextInsertionService(pasteboard: pasteboard)
        let cancellation = InsertionCancellation()
        cancellation.cancel()
        let target = DictationInsertionTarget(
            processID: getpid(),
            axElement: AXUIElementCreateApplication(getpid()),
            kind: .editable
        )

        let result = await service.insert(
            "transcript",
            into: target,
            mode: .automatic,
            cancellation: cancellation
        )

        guard case .failed = result else {
            Issue.record("A cancelled insertion should not report delivery")
            return
        }
        #expect(pasteboard.changeCount == before)
    }
}

@Suite("Audit Nov 2026: clipboard budget")
@MainActor
struct AuditNov2026ClipboardBudgetTests {
    @Test("A store under budget keeps its text even when the quick bound runs over")
    func underBudgetStoreIsNotTrimmed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-budget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardStore(
            storeURL: directory.appendingPathComponent("clipboard.json"),
            imageDirectory: directory,
            isEnabled: { true }
        )
        let text = String(repeating: "x", count: 11_600)
        for index in 0 ..< ClipboardStore.maximumEntryCount {
            store.record(ClipboardEntry(
                kind: .text,
                text: text,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                contentHash: "row-\(index)"
            ))
        }
        let upperBound = try #require(ClipboardStore.storeByteUpperBound(store.entries))
        #expect(upperBound > ClipboardStore.storeByteBudget)
        #expect(ClipboardStore.encodedStoreBytes(store.entries) <= ClipboardStore.storeByteBudget)
        #expect(store.entries.count == ClipboardStore.maximumEntryCount)
        #expect(store.entries.allSatisfy { $0.text == text })
    }
}
