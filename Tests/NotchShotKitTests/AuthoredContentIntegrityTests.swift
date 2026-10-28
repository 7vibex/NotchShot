import Foundation
import Testing
@testable import NotchShotKit

@Suite("Authored content integrity")
@MainActor
struct AuthoredContentIntegrityTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("Renaming a saved large note preserves every body character")
    func renameLargeNote() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("notes.json")
        let body = String(repeating: "x", count: 250_000) + "END"
        let original = ProductivityNote(title: "Original", body: body)
        try JSONEncoder().encode([original]).write(to: url)
        let store = ProductivityNoteStore(storeURL: url)
        var edited = try #require(store.notes.first)
        edited.title = "Renamed"
        store.update(edited)
        #expect(store.lastError == nil)
        #expect(store.notes.first?.body == body)
        let reopened = ProductivityNoteStore(storeURL: url)
        #expect(reopened.notes.first?.title == "Renamed")
        #expect(reopened.notes.first?.body == body)
    }

    @Test("A large note edit either saves the complete text or rejects it")
    func saveLargeNote() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("notes.json")
        let store = ProductivityNoteStore(storeURL: url)
        var note = store.create()
        let originalBody = note.body
        note.body = String(repeating: "a", count: 200_001) + "END"
        store.update(note)
        #expect(store.lastError != nil)
        #expect(store.notes.first?.body == originalBody)
        #expect(ProductivityNoteStore(storeURL: url).notes.first?.body == originalBody)
    }

    @Test("Manual lyrics reject overlong edits without silently saving a prefix")
    func saveLargeLyrics() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("lyrics.json")
        let store = LyricsStore(storeURL: url)
        let text = String(repeating: "x", count: 300_001) + "END"
        try store.setLyrics("Original", for: "artist-song")
        #expect(throws: (any Error).self) { try store.setLyrics(text, for: "artist-song") }
        #expect(store.lastError != nil)
        #expect(store.lyrics(for: "artist-song") == "Original")
        #expect(LyricsStore(storeURL: url).lyrics(for: "artist-song") == "Original")
    }

    @Test("Legacy long lyrics remain complete when saved or shortened")
    func legacyLyrics() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("lyrics.json")
        let text = String(repeating: "x", count: 350_000) + "END"
        try JSONEncoder().encode(["track": text]).write(to: url)
        let store = LyricsStore(storeURL: url)
        try store.setLyrics(text, for: "track")
        #expect(LyricsStore(storeURL: url).lyrics(for: "track") == text)
        let shorter = String(text.dropFirst())
        try store.setLyrics(shorter, for: "track")
        #expect(LyricsStore(storeURL: url).lyrics(for: "track") == shorter)
    }

    @Test("An overlong Terminal command is rejected before any process runs")
    func terminalCommandLimit() async {
        await #expect(throws: (any Error).self) {
            try await TerminalRunner.run("exit 0; #" + String(repeating: "x", count: 8_000))
        }
    }

    @Test("An overlong changed title is rejected without replacing the saved note")
    func longTitleRejected() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("notes.json")
        let store = ProductivityNoteStore(storeURL: url)
        var note = store.create()
        let original = note
        note.title = String(repeating: "x", count: 161)
        store.update(note)
        #expect(store.lastError != nil)
        #expect(store.notes.first?.title == original.title)
        #expect(ProductivityNoteStore(storeURL: url).notes.first?.title == original.title)
    }

    @Test("A body-only edit preserves a complete legacy title, which can also be shortened")
    func legacyTitle() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("notes.json")
        let title = "  " + String(repeating: "x", count: 200) + "END  "
        let original = ProductivityNote(title: title, body: "Original")
        try JSONEncoder().encode([original]).write(to: url)
        let store = ProductivityNoteStore(storeURL: url)
        var note = try #require(store.notes.first)
        note.body = "Changed body"
        store.update(note)
        #expect(store.lastError == nil)
        #expect(ProductivityNoteStore(storeURL: url).notes.first?.title == title)
        note.title = String(repeating: "y", count: 180)
        store.update(note)
        #expect(store.lastError == nil)
        #expect(ProductivityNoteStore(storeURL: url).notes.first?.title == note.title)
    }
}
