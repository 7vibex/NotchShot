import AppKit
import Foundation
import Testing
@testable import NotchShotKit

private actor ClipboardImageWriteBarrier {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func write(_ image: CGImage, id: UUID, directory: URL) async -> String? {
        let filename = "\(id.uuidString).png"
        do {
            _ = try ImageExport.write(image, to: directory.appendingPathComponent(filename),
                                      format: .png, quality: 1, dpiScale: 1)
        } catch { return nil }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
            startWaiters.forEach { $0.resume() }
            startWaiters = []
        }
        return filename
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@Suite("Clipboard clear cancellation")
@MainActor
struct ClipboardClearRegressionTests {
    @Test("Images decoded after Clear are discarded while later copies remain recordable")
    func delayedDecodeAndLaterCopy() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-clear-decode-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardStore(storeURL: directory.appendingPathComponent("store.json"),
                                   imageDirectory: directory, isEnabled: { true },
                                   now: { Date(timeIntervalSince1970: 200) })
        store.clear()
        let stale = ClipboardEntry(kind: .image, createdAt: Date(timeIntervalSince1970: 100),
                                   contentHash: "stale-decode")
        let fresh = ClipboardEntry(kind: .image, createdAt: Date(timeIntervalSince1970: 201),
                                   contentHash: "fresh-copy")
        let image = TestImage.solid(width: 8, height: 8)
        let staleResult = await store.recordImage(stale, image: image)
        let freshResult = await store.recordImage(fresh, image: image)
        #expect(staleResult == nil)
        #expect(freshResult?.id == fresh.id)
        #expect(store.entries.map(\.id) == [fresh.id])
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("\(stale.id.uuidString).png").path
        ))
        let imageURL = directory.appendingPathComponent("\(fresh.id.uuidString).png")
        #expect(SafeImageFile.cgImage(at: imageURL, limits: .generated) != nil)
        try store.save()
    }

    @Test("Clear invalidates an image already being written", arguments: [false, true])
    func clearDuringWrite(keepingPinned: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-clear-test-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let barrier = ClipboardImageWriteBarrier()
        let store = ClipboardStore(
            storeURL: directory.appendingPathComponent("store.json"),
            imageDirectory: directory,
            isEnabled: { true },
            now: { Date(timeIntervalSince1970: 200) },
            imageWriter: { image, id, directory in
                await barrier.write(image, id: id, directory: directory)
            }
        )
        let pinned = ClipboardEntry(kind: .text, text: "keep", isPinned: true, contentHash: "keep")
        store.record(pinned)
        let entry = ClipboardEntry(kind: .image, createdAt: Date(timeIntervalSince1970: 100),
                                   contentHash: "pending-image")
        let image = TestImage.solid(width: 8, height: 8)
        let pending = Task { await store.recordImage(entry, image: image) }
        await barrier.waitUntilStarted()
        store.clear(keepingPinned: keepingPinned)
        await barrier.release()
        let recorded = await pending.value
        #expect(recorded == nil)
        #expect(store.entries.map(\.id) == (keepingPinned ? [pinned.id] : []))
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("\(entry.id.uuidString).png").path
        ))
        try store.save()
    }
}
