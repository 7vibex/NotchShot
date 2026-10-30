import AppKit
import Foundation
import ImageIO
import Observation
import Testing
@testable import NotchShotKit

private actor FixImageWriteGate {
    private var pending: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func hold(_ id: UUID) async {
        await withCheckedContinuation { continuation in
            pending[id] = continuation
            let ready = waiters.filter { pending.count >= $0.0 }
            waiters.removeAll { pending.count >= $0.0 }
            for (_, waiter) in ready { waiter.resume() }
        }
    }

    func waitForCount(_ count: Int) async {
        if pending.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func release(_ id: UUID) { pending.removeValue(forKey: id)?.resume() }
}

private final class FixObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var receivedChange = false
    func markChanged() { lock.withLock { receivedChange = true } }
    var hasChanged: Bool { lock.withLock { receivedChange } }
}

@Suite("Notch consolidated fixes", .serialized)
@MainActor
struct NotchConsolidatedFixTests {
    private func directory(_ name: String) throws -> URL {
        let base = ProcessInfo.processInfo.environment["NOTCH_FIXTURE_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let result = base.appendingPathComponent("notch-fix-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }

    private func remove(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test("Notes reject an over-budget edit without changing durable or displayed content")
    func notesBudget() throws {
        let root = try directory("notes-budget")
        defer { remove(root) }
        let url = root.appendingPathComponent("notes.json")
        let seed = (0..<41).map { ProductivityNote(title: "Synthetic \($0)", body: String(repeating: "x", count: 200_000)) }
        try JSONEncoder().encode(seed).write(to: url)
        let store = ProductivityNoteStore(storeURL: url)
        #expect(store.notes.count == 41)
        var added = store.create()
        let before = try Data(contentsOf: url)
        let displayed = store.notes
        added.body = String(repeating: "y", count: 200_000)
        store.update(added)
        #expect(store.lastError != nil)
        #expect(store.notes == displayed)
        #expect(try Data(contentsOf: url) == before)
        #expect(before.count <= AuthoredContentFile.maximumStoreBytes)
        #expect(ProductivityNoteStore(storeURL: url).notes == displayed)
    }

    @Test("Lyrics budget failures preserve memory and disk; missing parents are initialized")
    func lyricsBudget() throws {
        let root = try directory("lyrics-budget")
        defer { remove(root) }
        let url = root.appendingPathComponent("lyrics.json")
        let seed = Dictionary(uniqueKeysWithValues: (0..<27).map { ("synthetic-\($0)", String(repeating: "x", count: 300_000)) })
        let before = try JSONEncoder().encode(seed)
        try before.write(to: url)
        let store = LyricsStore(storeURL: url)
        var rejected = false
        do { try store.setLyrics(String(repeating: "y", count: 300_000), for: "new-track") }
        catch { rejected = true }
        #expect(rejected)
        #expect(store.lyricsByTrack == seed)
        #expect(try Data(contentsOf: url) == before)
        #expect(LyricsStore(storeURL: url).lyricsByTrack == seed)
        let freshRoot = try directory("lyrics-new")
        defer { remove(freshRoot) }
        let fresh = LyricsStore(storeURL: freshRoot.appendingPathComponent("nested/lyrics.json"))
        #expect(fresh.lastError == nil)
        try fresh.setLyrics("Synthetic lyrics", for: "track")
        #expect(fresh.lyrics(for: "track") == "Synthetic lyrics")
    }

    @Test("Encoded bytes at and above the limit round trip, including escaping and multibyte text")
    func encodedByteBoundary() throws {
        let root = try directory("byte-boundary")
        defer { remove(root) }
        let url = root.appendingPathComponent("store.json")
        var file = AuthoredContentFile(url: url)
        _ = try file.load([String: String].self)
        let overhead = try JSONEncoder().encode(["k": ""]).count
        let content = ["k": String(repeating: "x", count: AuthoredContentFile.maximumStoreBytes - overhead)]
        try file.save(content)
        let saved = try Data(contentsOf: url)
        #expect(saved.count == AuthoredContentFile.maximumStoreBytes)
        var reader = AuthoredContentFile(url: url)
        #expect(try reader.load([String: String].self) == content)
        var rejected = false
        do { try file.save(["k": content["k"]! + "x"]) } catch { rejected = true }
        #expect(rejected)
        #expect(try Data(contentsOf: url) == saved)
        let escaped = ["k": String(repeating: "\"\\\n😀", count: 40_000)]
        try file.save(escaped)
        var escapedReader = AuthoredContentFile(url: url)
        #expect(try escapedReader.load([String: String].self) == escaped)
    }

    @Test("Legacy oversized Notes and Lyrics are recovered without a write, then backed up exactly")
    func oversizedRecovery() throws {
        let root = try directory("recovery")
        defer { remove(root) }
        let notesURL = root.appendingPathComponent("notes.json")
        let notes = (0..<42).map { ProductivityNote(title: "Synthetic \($0)", body: String(repeating: "x", count: 200_000)) }
        let originalNotes = try JSONEncoder().encode(notes)
        try originalNotes.write(to: notesURL)
        let store = ProductivityNoteStore(storeURL: notesURL)
        #expect(store.notes.count == 42)
        #expect(try Data(contentsOf: notesURL) == originalNotes)
        _ = store.create()
        #expect(store.notes.count == 42)
        #expect(try Data(contentsOf: notesURL) == originalNotes)
        store.delete(id: notes[0].id)
        let notesBackup = try #require(store.recoveryBackupURL)
        #expect(try Data(contentsOf: notesBackup) == originalNotes)
        #expect(ProductivityNoteStore(storeURL: notesURL).notes.count == 41)

        let lyricsURL = root.appendingPathComponent("lyrics.json")
        let lyrics = Dictionary(uniqueKeysWithValues: (0..<28).map { ("track-\($0)", String(repeating: "x", count: 300_000)) })
        let originalLyrics = try JSONEncoder().encode(lyrics)
        try originalLyrics.write(to: lyricsURL)
        let lyricsStore = LyricsStore(storeURL: lyricsURL)
        #expect(lyricsStore.lyricsByTrack == lyrics)
        #expect(try Data(contentsOf: lyricsURL) == originalLyrics)
        try lyricsStore.setLyrics("", for: "track-0")
        let lyricsBackup = try #require(lyricsStore.recoveryBackupURL)
        #expect(try Data(contentsOf: lyricsBackup) == originalLyrics)
        #expect(LyricsStore(storeURL: lyricsURL).lyricsByTrack.count == 27)
    }

    @Test("Failed reads lock writes; I/O failures and outside changes never commit memory")
    func readAndWriteProtection() throws {
        let root = try directory("read-lock")
        defer { remove(root) }
        let corrupt = Data("{synthetic invalid JSON".utf8)
        let url = root.appendingPathComponent("corrupt.json")
        try corrupt.write(to: url)
        let notes = ProductivityNoteStore(storeURL: url)
        #expect(notes.isWriteLocked)
        _ = notes.create()
        notes.delete(id: UUID())
        #expect(notes.notes.isEmpty)
        #expect(try Data(contentsOf: url) == corrupt)
        let lyrics = LyricsStore(storeURL: url)
        #expect(lyrics.isWriteLocked)
        var rejected = false
        do { try lyrics.setLyrics("synthetic", for: "track") } catch { rejected = true }
        #expect(rejected)
        #expect(lyrics.lyricsByTrack.isEmpty)
        #expect(try Data(contentsOf: url) == corrupt)

        let destination = root.appendingPathComponent("occupied", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let occupied = ProductivityNoteStore(storeURL: destination)
        _ = occupied.create()
        #expect(occupied.isWriteLocked && occupied.notes.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)

        let changedURL = root.appendingPathComponent("outside.json")
        let changed = ProductivityNoteStore(storeURL: changedURL)
        var note = changed.create()
        let displayed = changed.notes
        try corrupt.write(to: changedURL, options: .atomic)
        note.body = "new content"
        changed.update(note)
        #expect(changed.notes == displayed)
        #expect(try Data(contentsOf: changedURL) == corrupt)
    }

    @Test("Clipboard file and text identities remain distinct in both directions")
    func clipboardTypeDirections() throws {
        let root = try directory("clipboard-kind")
        defer { remove(root) }
        let path = root.appendingPathComponent("synthetic.txt").path
        let hash = ClipboardEntry.hash(forText: path)
        let files = ClipboardEntry(kind: .files, filePaths: [path], contentHash: hash)
        let text = ClipboardEntry(kind: .text, text: path, contentHash: hash)
        for reverse in [false, true] {
            let store = ClipboardStore(storeURL: root.appendingPathComponent("store-\(reverse).json"), imageDirectory: root, isEnabled: { true })
            store.record(reverse ? text : files)
            let recorded = store.record(reverse ? files : text)
            #expect(recorded?.kind == (reverse ? .files : .text))
            #expect(store.entries.count == 2)
            let id = try #require(recorded?.id)
            store.setPinned(true, id: id)
            store.setLabel("Synthetic label", id: id)
            let promoted = store.record(reverse ? files : text)
            #expect(promoted?.id == id && promoted?.label == "Synthetic label" && promoted?.isPinned == true)
            #expect(store.entries.count == 2)
            try store.save()
        }
    }

    @Test("Reverse image completions deduplicate while preserving latest metadata and authored fields")
    func clipboardImageRace() async throws {
        for newerFirst in [false, true] {
            let root = try directory("image-race")
            defer { remove(root) }
            let gate = FixImageWriteGate()
            let store = ClipboardStore(storeURL: root.appendingPathComponent("store.json"), imageDirectory: root, isEnabled: { true }, imageWriter: { _, id, directory in
                try? Data("synthetic image writer".utf8).write(to: directory.appendingPathComponent("\(id.uuidString).png"))
                await gate.hold(id)
                return "\(id.uuidString).png"
            })
            let older = ClipboardEntry(kind: .image, sourceApplicationName: "Older", createdAt: Date(timeIntervalSince1970: 1), contentHash: "same-image")
            let newer = ClipboardEntry(kind: .image, sourceApplicationName: "Newer", createdAt: Date(timeIntervalSince1970: 2), contentHash: "same-image")
            let image = TestImage.solid(width: 8, height: 8)
            let first = Task { await store.recordImage(older, image: image) }
            let second = Task { await store.recordImage(newer, image: image) }
            await gate.waitForCount(2)
            let keptID = newerFirst ? newer.id : older.id
            let discardedID = newerFirst ? older.id : newer.id
            await gate.release(keptID)
            if newerFirst { _ = await second.value } else { _ = await first.value }
            store.setPinned(true, id: keptID)
            store.setLabel("Keep", id: keptID)
            store.setRecognizedText("Synthetic OCR", id: keptID)
            await gate.release(discardedID)
            let promoted = newerFirst ? await first.value : await second.value
            #expect(store.entries.count == 1)
            #expect(promoted?.id == keptID && promoted?.createdAt == newer.createdAt)
            #expect(promoted?.sourceApplicationName == "Newer" && promoted?.label == "Keep")
            #expect(promoted?.isPinned == true && promoted?.text == "Synthetic OCR")
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("\(discardedID.uuidString).png").path))
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(keptID.uuidString).png").path))
            let sequential = await store.recordImage(newer, image: image)
            #expect(sequential?.id == keptID && store.entries.count == 1)
            try store.save()
        }
    }

    @Test("An image suspension does not conflate a text hash or escape Clear")
    func clipboardTypeRaceAndClear() async throws {
        let root = try directory("image-kind-race")
        defer { remove(root) }
        let gate = FixImageWriteGate()
        let store = ClipboardStore(storeURL: root.appendingPathComponent("store.json"), imageDirectory: root, isEnabled: { true }, imageWriter: { _, id, directory in
            try? Data("synthetic image writer".utf8).write(to: directory.appendingPathComponent("\(id.uuidString).png"))
            await gate.hold(id)
            return "\(id.uuidString).png"
        })
        let image = TestImage.solid(width: 8, height: 8)
        let entry = ClipboardEntry(kind: .image, contentHash: "shared-hash")
        let pending = Task { await store.recordImage(entry, image: image) }
        await gate.waitForCount(1)
        store.record(ClipboardEntry(kind: .text, text: "synthetic", contentHash: "shared-hash"))
        await gate.release(entry.id)
        let recorded = await pending.value
        #expect(recorded?.kind == .image && store.entries.count == 2)
        let stale = ClipboardEntry(kind: .image, contentHash: "clear-race")
        let canceled = Task { await store.recordImage(stale, image: image) }
        await gate.waitForCount(1)
        store.clear()
        await gate.release(stale.id)
        let canceledResult = await canceled.value
        #expect(canceledResult == nil && store.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("\(stale.id.uuidString).png").path))
        try store.save()
    }

    @Test("64-file clippings replay wholly; 65-file clippings are rejected and persisted lists stay complete")
    func clipboardFileLimit() throws {
        let root = try directory("file-limit")
        defer { remove(root) }
        var paths: [String] = []
        var identities: [ExternalFileIdentity] = []
        for i in 0..<65 {
            let url = root.appendingPathComponent("synthetic-\(i).txt")
            try Data("synthetic".utf8).write(to: url)
            paths.append(url.path)
            identities.append(try #require(SafeAssetFile.identity(at: url, maximumBytes: 1_024)))
        }
        let over = ClipboardEntry(kind: .files, filePaths: paths, fileIdentities: identities, contentHash: "65")
        let bounded = ClipboardEntry(kind: .files, filePaths: Array(paths.prefix(64)), fileIdentities: Array(identities.prefix(64)), contentHash: "64")
        let store = ClipboardStore(storeURL: root.appendingPathComponent("fresh.json"), imageDirectory: root, isEnabled: { true })
        #expect(store.record(over) == nil && store.recordingRejectionMessage != nil)
        #expect(store.entries.isEmpty)
        #expect(store.record(bounded)?.filePaths.count == 64)
        #expect(try ClipboardMonitor.validatedFileURLs(for: bounded).count == 64)
        var rejected = false
        do { _ = try ClipboardMonitor.validatedFileURLs(for: over) } catch { rejected = true }
        #expect(rejected)
        let url = root.appendingPathComponent("legacy.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode([over])
        try data.write(to: url)
        let loaded = ClipboardStore(storeURL: url, imageDirectory: root, isEnabled: { true })
        #expect(loaded.entries.first?.filePaths == paths)
        #expect(loaded.loadRecoveryMessage != nil)
        #expect(try Data(contentsOf: url) == data)
        try store.save()
    }

    @Test("Nonrepresentable media times are omitted; normal fractional times keep their value")
    func mediaTimeBounds() throws {
        for invalid in [1e100, Double.infinity, -Double.infinity, Double.nan, -1, Double(Int.max)] {
            let snapshot = MediaSnapshot(source: .mediaRemote, title: "Synthetic", artist: "Artist", duration: invalid, position: invalid)
            #expect(snapshot.duration == nil && snapshot.position == nil)
            #expect(MediaTimePolicy.formatted(invalid) == "--:--")
            #expect(LyricsQuery(title: "Synthetic", artist: "Artist", duration: invalid).duration == nil)
        }
        let payload = Data(#"{"title":"Synthetic","artist":"Artist","duration":1e100,"elapsedTime":1e100}"#.utf8)
        let decoded = try #require(AdapterPayload.snapshot(from: payload))
        #expect(decoded.duration == nil && decoded.position == nil)
        let ordinary = MediaSnapshot(duration: 181.25, position: 60.5)
        #expect(ordinary.duration == 181.25 && ordinary.position == 60.5)
        #expect(MediaTimePolicy.formatted(60.5) == "1:01")
        #expect(MediaTimePolicy.formatted(3_661) == "1:01:01")
        #expect(MediaTimePolicy.wholeSeconds(181.25, rounding: .towardZero) == 181)
        var mutated = MediaSnapshot(title: "Synthetic", artist: "Artist")
        mutated.duration = 1e100
        mutated.position = 1e100
        #expect(LyricsQuery(snapshot: mutated)?.duration == nil)
        #expect(mutated.interpolatedPosition() == nil)
    }

    @Test("Worker output matches the synchronous renderer and immutable snapshot after later edits")
    func workerSnapshotAndOutput() async throws {
        let source = TestImage.solid(width: 160, height: 100, red: 255, green: 255, blue: 255)
        let document = AnnotationDocument(sourcePixelSize: CGSize(width: 160, height: 100), sourceScale: 2, elements: [AnnotationElement.rect(kind: .blackout, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 30, y: 30), style: AnnotationStyle(colorHex: "#000000"))])
        let controller = AnnotationDocumentController(source: source, document: document)
        let snapshot = controller.makeRenderSnapshot()
        let expected = try controller.renderFlattened()
        controller.rotateRight()
        let actual = try await AnnotationRenderWorker.shared.render(snapshot)
        #expect(actual.pixelSize == CGSize(width: 160, height: 100) && actual.scale == 2)
        #expect(actual.cgImage.dataProvider?.data as Data? == expected.dataProvider?.data as Data?)
        let redacted = TestImage.pixel(actual.cgImage, x: 20, y: 20)
        let original = TestImage.pixel(source, x: 20, y: 20)
        #expect(redacted.r == 0 && redacted.g == 0 && redacted.b == 0)
        #expect(original.r == 255 && original.g == 255 && original.b == 255)
        let canceled = Task { try await AnnotationRenderWorker.shared.render(snapshot) }
        canceled.cancel()
        var stopped = false
        do { _ = try await canceled.value } catch is CancellationError { stopped = true }
        #expect(stopped)
    }

    @Test("Preview preparation rejects stale geometry and cancellation and reuses matching annotations")
    func previewStaleAndCancellation() async throws {
        let source = TestImage.solid(width: 100, height: 80)
        let controller = AnnotationDocumentController(source: source, document: AnnotationDocument(sourcePixelSize: CGSize(width: 100, height: 80)))
        let gate = FixImageWriteGate()
        let id = UUID()
        controller.previewRenderer = { snapshot in
            await gate.hold(id)
            return try snapshot.render(isPreview: true)
        }
        #expect(controller.basePreviewImage() == nil)
        let stale = Task { await controller.prepareBasePreview() }
        await gate.waitForCount(1)
        controller.rotateRight()
        await gate.release(id)
        await stale.value
        #expect(controller.basePreviewImage() == nil)
        let canceled = Task { await controller.prepareBasePreview() }
        await gate.waitForCount(1)
        canceled.cancel()
        await gate.release(id)
        await canceled.value
        #expect(controller.basePreviewImage() == nil)
        controller.previewRenderer = { try await AnnotationRenderWorker.shared.render($0, isPreview: true) }
        await controller.prepareBasePreview()
        let current = try #require(controller.basePreviewImage())
        #expect(current.size == CGSize(width: 80, height: 100))
        controller.add(AnnotationElement(kind: .rectangle, points: [.zero, CGPoint(x: 30, y: 30)], style: AnnotationStyle()))
        await controller.prepareBasePreview()
        #expect(controller.basePreviewImage() === current)
        controller.undo()
        controller.undo()
        #expect(controller.basePreviewImage() == nil)
        await controller.prepareBasePreview()
        #expect(controller.basePreviewImage()?.size == CGSize(width: 100, height: 80))
    }

    @Test("An initial preview cache miss subscribes to the completed image")
    func previewObservationPublication() async {
        let controller = AnnotationDocumentController(
            source: TestImage.solid(width: 100, height: 80),
            document: AnnotationDocument(sourcePixelSize: CGSize(width: 100, height: 80))
        )
        let flag = FixObservationFlag()
        withObservationTracking {
            _ = controller.basePreviewImage()
        } onChange: {
            flag.markChanged()
        }
        await controller.prepareBasePreview()
        #expect(flag.hasChanged)
        #expect(controller.basePreviewImage() != nil)
    }
}
