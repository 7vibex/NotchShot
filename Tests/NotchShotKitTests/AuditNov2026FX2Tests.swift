import AppKit
import Foundation
import Testing

@testable import NotchShotKit

@Suite("History cleanup hold")
@MainActor
struct HistoryCleanupHoldTests {
    @MainActor
    private struct Fixture {
        let root: URL
        let managed: URL
        let store: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("notchshot-history-hold-\(UUID().uuidString)", isDirectory: true)
            managed = root.appendingPathComponent("Captures", isDirectory: true)
            store = root.appendingPathComponent("history.json")
            try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        }

        func open(historyEnabled: Bool = true) -> HistoryRepository {
            HistoryRepository(
                storeURL: store,
                managedArtifactDirectories: [managed],
                historyEnabled: historyEnabled,
                indexesCaptureText: false
            )
        }

        @discardableResult
        func capture(_ name: String) throws -> URL {
            let url = managed.appendingPathComponent(name)
            try Data("capture".utf8).write(to: url)
            return url
        }

        func corruptStore() throws {
            try Data("{not-json".utf8).write(to: store)
        }

        func record(_ url: URL, in repository: HistoryRepository) throws {
            repository.record(
                asset: CaptureAsset(
                    url: url,
                    kind: .screenshot,
                    pixelSize: .zero,
                    ownership: .managedTemporary,
                    captureMissingFileIdentities: false
                ),
                image: nil
            )
            try repository.save()
        }

        func exists(_ url: URL) -> Bool {
            FileManager.default.fileExists(atPath: url.path)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test("Captures survive the launch after a quarantine, once a new store has been written")
    func quarantineOutlivesTheNextSave() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let orphan = try fixture.capture("must-survive.png")
        try fixture.corruptStore()

        let first = fixture.open()
        guard case .failed = first.loadOutcome else {
            Issue.record("Malformed History should enter recovery mode")
            return
        }
        try fixture.record(try fixture.capture("new.png"), in: first)

        let second = fixture.open()
        #expect(second.loadOutcome == .loaded)
        #expect(second.holdsUntrackedCleanup)
        #expect(second.removeUntrackedManagedFiles() == 0)
        #expect(fixture.exists(orphan))

        // And on every launch after that, not only the next one.
        let third = fixture.open()
        #expect(third.removeUntrackedManagedFiles() == 0)
        #expect(fixture.exists(orphan))
    }

    @Test("Quarantine holds when the next launch finds no store at all")
    func quarantineThenMissingStore() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let orphan = try fixture.capture("must-survive.png")
        try fixture.corruptStore()
        _ = fixture.open()

        let second = fixture.open()
        #expect(second.loadOutcome == .missing)
        #expect(second.holdsUntrackedCleanup)
        #expect(second.removeUntrackedManagedFiles() == 0)
        #expect(fixture.exists(orphan))
    }

    @Test("A store lost beside existing captures holds past the first new store")
    func missingStoreBesideCaptures() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let orphan = try fixture.capture("must-survive.png")

        let first = fixture.open()
        #expect(first.loadOutcome == .missing)
        #expect(first.holdsUntrackedCleanup)
        #expect(fixture.exists(HistoryRepository.cleanupHoldURL(for: fixture.store)))
        try fixture.record(try fixture.capture("new.png"), in: first)

        let second = fixture.open()
        #expect(second.loadOutcome == .loaded)
        #expect(second.removeUntrackedManagedFiles() == 0)
        #expect(fixture.exists(orphan))
    }

    @Test("With History off, a missing store is normal and the sweep still runs")
    func historyOffStillSweeps() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let orphan = try fixture.capture("temporary.png")

        let repository = fixture.open(historyEnabled: false)
        #expect(!repository.holdsUntrackedCleanup)
        #expect(repository.removeUntrackedManagedFiles() == 1)
        #expect(!fixture.exists(orphan))
    }

    @Test("A healthy store still sweeps a true orphan and keeps its own rows")
    func healthyStoreSweeps() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = fixture.open()
        #expect(!first.holdsUntrackedCleanup)
        let tracked = try fixture.capture("tracked.png")
        try fixture.record(tracked, in: first)
        let orphan = try fixture.capture("orphan.png")

        let second = fixture.open()
        #expect(second.loadOutcome == .loaded)
        #expect(!second.holdsUntrackedCleanup)
        #expect(second.removeUntrackedManagedFiles() == 1)
        #expect(!fixture.exists(orphan))
        #expect(fixture.exists(tracked))
    }

    @Test("Clearing rows alone does not release the hold")
    func clearingRowsKeepsTheHold() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let orphan = try fixture.capture("must-survive.png")
        try fixture.corruptStore()

        let repository = fixture.open()
        #expect(repository.clearAll(includingFiles: false).isEmpty)
        #expect(repository.holdsUntrackedCleanup)
        #expect(fixture.open().holdsUntrackedCleanup)
        #expect(fixture.exists(orphan))
    }

    @Test("Releasing moves the held files on, and the next launch sweeps again")
    func releaseEndsTheHold() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let orphan = try fixture.capture("held.png")
        try fixture.corruptStore()

        let first = fixture.open()
        let tracked = try fixture.capture("tracked.png")
        try fixture.record(tracked, in: first)

        var trashed: [String] = []
        let released = first.releaseCleanupHold { url in
            trashed.append(url.lastPathComponent)
            try FileManager.default.removeItem(at: url)
        }
        #expect(released)
        #expect(!first.holdsUntrackedCleanup)
        #expect(trashed.first == orphan.lastPathComponent)
        #expect(!fixture.exists(orphan))
        #expect(fixture.exists(tracked))

        let later = try fixture.capture("later.png")
        let second = fixture.open()
        #expect(!second.holdsUntrackedCleanup)
        #expect(second.removeUntrackedManagedFiles() == 1)
        #expect(!fixture.exists(later))
    }

    @Test("A quarantined store from an older build doesn't hold an upgraded install")
    func oldQuarantineDoesNotHold() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let healthy = fixture.open()
        let tracked = try fixture.capture("tracked.png")
        try fixture.record(tracked, in: healthy)
        let old = fixture.root.appendingPathComponent("history.json.corrupt-\(UUID().uuidString)")
        try Data("{not-json".utf8).write(to: old)
        let orphan = try fixture.capture("orphan.png")

        let upgraded = fixture.open()
        #expect(!upgraded.holdsUntrackedCleanup)
        #expect(upgraded.removeUntrackedManagedFiles() == 1)
        #expect(!fixture.exists(orphan))
        #expect(fixture.exists(tracked))
        #expect(fixture.exists(old))
    }

    @Test("Detecting corruption writes the note that holds later launches")
    func corruptionWritesTheNote() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.capture("must-survive.png")
        try fixture.corruptStore()
        let repository = fixture.open()
        #expect(repository.holdsUntrackedCleanup)
        #expect(fixture.exists(HistoryRepository.cleanupHoldURL(for: fixture.store)))
    }

    @Test("Releasing leaves files from this launch where they are")
    func releaseLeavesFilesInUse() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let held = try fixture.capture("held.png")
        try fixture.corruptStore()
        let repository = fixture.open()
        try await Task.sleep(for: .milliseconds(50))
        let onTheShelf = try fixture.capture("on-the-shelf.png")

        #expect(repository.releaseCleanupHold { try FileManager.default.removeItem(at: $0) })
        #expect(!fixture.exists(held))
        #expect(fixture.exists(onTheShelf))
    }

    @Test("Releasing keeps the recordings the sweep preserves")
    func releaseKeepsPreservedRecordings() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let recording = try fixture.capture("take.mp4")
        let screenshot = try fixture.capture("held.png")
        try fixture.corruptStore()
        let repository = fixture.open(historyEnabled: false)

        #expect(repository.releaseCleanupHold { try FileManager.default.removeItem(at: $0) })
        #expect(fixture.exists(recording))
        #expect(!fixture.exists(screenshot))
    }

    @Test("A failed move to Trash leaves the hold standing")
    func failedReleaseKeepsTheHold() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let orphan = try fixture.capture("held.png")
        try fixture.corruptStore()

        struct TrashRefused: Error {}
        let repository = fixture.open()
        let released = repository.releaseCleanupHold { _ in throw TrashRefused() }
        #expect(!released)
        #expect(repository.holdsUntrackedCleanup)
        #expect(fixture.open().holdsUntrackedCleanup)
        #expect(fixture.exists(orphan))
    }
}

@Suite("Dictation text")
struct DictationTextRegressionTests {
    private func spoken(_ text: String) -> String {
        DictationTextProcessor.process(
            text,
            mode: .verbatim,
            removeFillerWords: false,
            deterministicReplacements: [:],
            customDictionary: [:],
            appendMode: .nothing,
            enableSpokenFormatting: true
        )
    }

    private func withoutFillers(_ text: String) -> String {
        DictationTextProcessor.process(
            text,
            mode: .verbatim,
            removeFillerWords: true,
            deterministicReplacements: [:],
            customDictionary: [:],
            appendMode: .nothing,
            enableSpokenFormatting: false
        )
    }

    @Test("A custom word entered twice does not trap")
    func duplicateCustomWords() {
        let dictionary = DictationTextProcessor.customDictionary(from: ["NotchShot", "Swift", "NotchShot"])
        #expect(dictionary == ["NotchShot": "NotchShot", "Swift": "Swift"])
    }

    @Test(
        "Spoken punctuation leaves longer words alone",
        arguments: ["check periodically", "the commander spoke", "the colonel spoke", "three commas", "the colons"]
    )
    func spokenFormattingKeepsWords(text: String) {
        #expect(spoken(text) == text)
    }

    @Test("Spoken punctuation still converts whole words")
    func spokenFormattingConverts() {
        #expect(spoken("hello comma world") == "hello, world")
        #expect(spoken("is it done question mark") == "is it done?")
        #expect(spoken("first new line second") == "first\nsecond")
    }

    @Test(
        "Ordinary words are not fillers",
        arguments: [
            "I like this design",
            "it looks like rain",
            "do you know him",
            "umbrella and errand",
            "first line\nsecond line",
        ]
    )
    func fillerRemovalKeepsWords(text: String) {
        #expect(withoutFillers(text) == text)
    }

    @Test("Fillers go where they are clearly fillers")
    func fillerRemovalRemoves() {
        #expect(withoutFillers("um hello uh world") == "hello world")
        #expect(withoutFillers("Uh, okay") == "okay")
        #expect(withoutFillers("Um, uh, I think we should go") == "I think we should go")
        #expect(withoutFillers("first line\num second") == "first line\nsecond")
        #expect(withoutFillers("it was, like, great") == "it was, great")
        #expect(withoutFillers("Like, we should go") == "we should go")
        #expect(withoutFillers("it works, you know.") == "it works.")
    }

    @Test("A typing chunk never splits a surrogate pair")
    func chunksKeepSurrogatePairs() {
        let text = String(repeating: "a", count: 63) + "🙂" + String(repeating: "b", count: 100) + "🙂"
        let chunks = TextInsertionService.unicodeEventChunks(Array(text.utf16))

        #expect(chunks.first?.count == 63)
        #expect(chunks.allSatisfy { $0.count <= 64 })
        #expect(chunks.flatMap { $0 } == Array(text.utf16))
        for chunk in chunks {
            #expect(!String(decoding: chunk, as: UTF16.self).contains("\u{FFFD}"))
        }
    }
}

@Suite("Clipboard store budget")
@MainActor
struct ClipboardBudgetRegressionTests {
    private static let rowLength = 210_000
    private static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func withStore(_ body: (ClipboardStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-clipboard-budget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(ClipboardStore(
            storeURL: directory.appendingPathComponent("clipboard.json"),
            imageDirectory: directory.appendingPathComponent("images", isDirectory: true),
            isEnabled: { true }
        ))
    }

    private func text(_ index: Int) -> String {
        "row \(index) " + String(repeating: "a", count: Self.rowLength)
    }

    private func entry(_ index: Int, at offset: Int? = nil) -> ClipboardEntry {
        ClipboardEntry(
            kind: .text,
            text: text(index),
            createdAt: Self.start.addingTimeInterval(TimeInterval(offset ?? index)),
            contentHash: ClipboardEntry.hash(forText: text(index))
        )
    }

    private func isFull(_ entry: ClipboardEntry) -> Bool {
        (entry.text?.utf8.count ?? 0) > Self.rowLength
    }

    @Test("A small overrun shortens only the oldest row")
    func smallOverrun() throws {
        try withStore { store in
            let rows = (0 ..< 30).map { entry($0) }
            // One budget pass for the rows that fit: a pass per row holds the
            // main actor for seconds in a debug build, and other suites wait on it.
            store.record(contentsOf: Array(rows.dropLast()))
            store.record(rows[29])

            #expect(store.entries.count == rows.count)
            #expect(store.entries.filter { !isFull($0) }.map(\.id) == [rows[0].id])
            #expect(ClipboardStore.isStoreGuaranteedWithinByteBudget(store.entries))
        }
    }

    @Test("A pinned row is shortened after the others")
    func pinnedLast() throws {
        try withStore { store in
            let rows = (0 ..< 30).map { entry($0) }
            store.record(contentsOf: Array(rows.dropLast()))
            store.setPinned(true, id: rows[0].id)
            store.record(rows[29])

            #expect(store.entries.filter { !isFull($0) }.map(\.id) == [rows[1].id])
        }
    }

    @Test("Copying a shortened clipping again brings its full text back")
    func recopyRestores() throws {
        try withStore { store in
            let rows = (0 ..< 30).map { entry($0) }
            store.record(contentsOf: Array(rows.dropLast()))
            store.record(rows[29])
            #expect(store.entry(id: rows[0].id).map(isFull) == false)

            store.record(entry(0, at: 100))

            #expect(store.entries.first?.id == rows[0].id)
            #expect(store.entry(id: rows[0].id)?.text == text(0))
        }
    }

    @Test("A batch keeps the order and dedupes against itself and the store")
    func batchRecord() throws {
        try withStore { store in
            store.record(entry(1))
            store.record(contentsOf: [entry(2), entry(1, at: 3), entry(4), entry(4, at: 5)])

            #expect(store.entries.count == 3)
            #expect(store.entries.map(\.text) == [text(4), text(1), text(2)])
        }
    }

    @Test(
        "The string bound is never below what the encoder writes",
        arguments: [
            "plain ascii",
            "a/b\"c\\d",
            "\u{0}\u{1}\u{1F}\n\t\r",
            "é 🙂 中文",
            "\u{7F}\u{2028}\u{2029}",
            "",
        ]
    )
    func stringBound(value: String) throws {
        let encoded = try JSONEncoder().encode(value)
        #expect(encoded.count - 2 <= ClipboardStore.encodedStringBound(value))
    }

    @Test("The store bound holds for a full row and is tight enough for ordinary text")
    func storeBound() throws {
        let rich = ClipboardEntry(
            kind: .files,
            label: "a \"label\"",
            tags: ["one", "two/three"],
            text: "/\u{1}\\",
            filePaths: ["/tmp/one", "/tmp/two"],
            sourceApplicationName: "App",
            sourceApplicationBundleID: "com.example.app",
            contentHash: ClipboardEntry.hash(forText: "rich")
        )
        let bound = try #require(ClipboardStore.storeByteUpperBound([rich]))
        #expect(ClipboardStore.encodedStoreBytes([rich]) <= bound)

        let ordinary = (0 ..< 20).map { index in
            let text = "line \(index) " + String(repeating: "b", count: 100_000)
            return ClipboardEntry(kind: .text, text: text, contentHash: ClipboardEntry.hash(forText: text))
        }
        #expect(ClipboardStore.isStoreGuaranteedWithinByteBudget(ordinary))

        let control = String(repeating: "\u{1}", count: 1_200_000)
        let escaped = ClipboardEntry(kind: .text, text: control, contentHash: ClipboardEntry.hash(forText: "control"))
        #expect(!ClipboardStore.isStoreGuaranteedWithinByteBudget([escaped]))
    }

    @Test("The preview fast path says what the full path says")
    func previewFastPath() {
        let long = String(repeating: "word\n", count: 2_000)
        let collapsed = long
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let row = ClipboardEntry(kind: .text, text: long, contentHash: "long")
        #expect(row.preview == String(collapsed.prefix(180)) + "…")

        let blankHead = String(repeating: " ", count: 5_000) + "hello"
        let blank = ClipboardEntry(kind: .text, text: blankHead, contentHash: "blank")
        #expect(blank.preview == "hello")
    }
}

@Suite("Clipboard read off main")
@MainActor
struct ClipboardOffMainReadTests {
    @Test("A read only records the contents poll vetted")
    func changeCountIsVerified() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)
        let request = ClipboardMonitor.ReadRequest(
            changeCount: pasteboard.changeCount,
            sourceName: nil,
            sourceBundleID: nil,
            now: Date()
        )

        guard case let .immediate(entry)? = ClipboardMonitor.readEntry(
            from: pasteboard.name.rawValue,
            request: request
        ) else {
            Issue.record("The vetted text should be read")
            return
        }
        #expect(entry.text == "hello")

        // Something else was copied after poll judged the contents.
        pasteboard.clearContents()
        pasteboard.setString("not vetted", forType: .string)
        #expect(ClipboardMonitor.readEntry(from: pasteboard.name.rawValue, request: request) == nil)
    }
}

@Suite("Media observation")
struct MediaObservationStateTests {
    private func state(
        title: String = "Song",
        position: TimeInterval = 1,
        isPlaying: Bool = true
    ) -> MediaObservationState {
        MediaObservationState(
            snapshot: MediaSnapshot(
                title: title,
                position: position,
                positionTimestamp: Date(timeIntervalSinceReferenceDate: position),
                isPlaying: isPlaying
            ),
            isSessionActive: true,
            isScreenLocked: false
        )
    }

    @Test("A position tick is not a change, and a real change still is")
    func positionIsIgnored() {
        #expect(state(position: 1) == state(position: 3))
        #expect(state(title: "Song") != state(title: "Other"))
        #expect(state(isPlaying: true) != state(isPlaying: false))
    }
}

@Suite("Jiggle file check")
@MainActor
struct JiggleFileCheckTests {
    @Test("Only a write since this press counts as holding files")
    func dragCarriesFiles() throws {
        #expect(JiggleDetector.dragCarriesFiles(types: [.fileURL], changeCount: 5, changeCountAtMouseDown: 4))
        // The drag pasteboard keeps the last drag's contents.
        #expect(!JiggleDetector.dragCarriesFiles(types: [.fileURL], changeCount: 4, changeCountAtMouseDown: 4))
        #expect(!JiggleDetector.dragCarriesFiles(types: [.fileURL], changeCount: 5, changeCountAtMouseDown: nil))
        #expect(!JiggleDetector.dragCarriesFiles(types: [.string], changeCount: 5, changeCountAtMouseDown: 4))

        let promised = try #require(NSFilePromiseReceiver.readableDraggedTypes.first)
        #expect(JiggleDetector.dragCarriesFiles(
            types: [NSPasteboard.PasteboardType(rawValue: promised)],
            changeCount: 5,
            changeCountAtMouseDown: 4
        ))
    }
}
