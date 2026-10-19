import Foundation
import Testing
@testable import NotchShotKit

@Suite("Lyrics")
struct LyricsTests {
    @Test("LRC lines parse in time order, with repeated stamps and metadata")
    func parsesLRC() throws {
        let text = """
        [ar:Someone]
        [ti:Song]
        [00:13.13] Yeah
        [00:16.56]
        [01:02.50][00:40.00] Chorus
        not a timed line
        [00:27:16] Colon hundredths
        """
        let lines = try #require(LRCParser.parse(text))
        #expect(lines.map(\.text) == ["Yeah", "", "Colon hundredths", "Chorus", "Chorus"])
        #expect(lines.map(\.time) == [13.13, 16.56, 27.16, 40, 62.5])
        #expect(lines.map(\.id) == [0, 1, 2, 3, 4])
    }

    @Test("A positive LRC offset shows lines sooner, never before zero")
    func appliesOffset() throws {
        let lines = try #require(LRCParser.parse("[offset:500]\n[00:00.20] a\n[00:02.00] b"))
        #expect(lines.map(\.time) == [0, 1.5])
    }

    @Test("Text with no timestamps is not synced lyrics")
    func rejectsUntimedText() {
        #expect(LRCParser.parse("just words\nmore words") == nil)
        #expect(LRCParser.timestamp("ar:Artist") == nil)
        #expect(LRCParser.timestamp("01:75.00") == nil)
    }

    @Test("The current line is the last one whose time has passed")
    func currentLine() {
        let lyrics = Lyrics(
            lines: [
                LyricLine(id: 0, time: 5, text: "a"),
                LyricLine(id: 1, time: 10, text: "b"),
                LyricLine(id: 2, time: 20, text: "c"),
            ],
            isSynced: true,
            isInstrumental: false
        )
        #expect(lyrics.currentLineIndex(at: 0) == nil)
        #expect(lyrics.currentLineIndex(at: 5) == 0)
        #expect(lyrics.currentLineIndex(at: 19.9) == 1)
        #expect(lyrics.currentLineIndex(at: 400) == 2)

        let plain = Lyrics(lines: lyrics.lines, isSynced: false, isInstrumental: false)
        #expect(plain.currentLineIndex(at: 12) == nil)
    }

    @Test("Search results prefer synced lyrics of a matching length")
    func picksBestMatch() {
        let query = LyricsQuery(title: "Song", artist: "Artist", duration: 200)
        let records = [
            LRCLIBRecord(duration: 260, instrumental: false, plainLyrics: nil, syncedLyrics: "[00:01.00] live take"),
            LRCLIBRecord(duration: 201, instrumental: false, plainLyrics: "plain", syncedLyrics: nil),
            LRCLIBRecord(duration: 199, instrumental: false, plainLyrics: "plain", syncedLyrics: "[00:01.00] studio"),
            LRCLIBRecord(duration: 200, instrumental: false, plainLyrics: nil, syncedLyrics: nil),
        ]
        let best = LyricsService.bestMatch(records, for: query)
        #expect(best?.syncedLyrics == "[00:01.00] studio")
        #expect(LyricsService.bestMatch([records[0]], for: query) == nil)
    }

    @Test("Records become synced, plain or instrumental lyrics")
    func convertsRecords() throws {
        let synced = try #require(LyricsService.lyrics(from: LRCLIBRecord(
            duration: 1, instrumental: false, plainLyrics: "x", syncedLyrics: "[00:01.00] y"
        )))
        #expect(synced.isSynced && synced.lines.map(\.text) == ["y"])

        let plain = try #require(LyricsService.lyrics(from: LRCLIBRecord(
            duration: 1, instrumental: false, plainLyrics: "one\ntwo", syncedLyrics: ""
        )))
        #expect(!plain.isSynced && plain.lines.map(\.text) == ["one", "two"])

        let instrumental = LyricsService.lyrics(from: LRCLIBRecord(
            duration: 1, instrumental: true, plainLyrics: nil, syncedLyrics: nil
        ))
        #expect(instrumental == .instrumental)
        #expect(LyricsService.lyrics(from: LRCLIBRecord(
            duration: 1, instrumental: false, plainLyrics: "  \n ", syncedLyrics: nil
        )) == nil)
    }

    @Test("A lookup key ignores sub-second length jitter and needs title and artist")
    func queryFromSnapshot() {
        var snapshot = MediaSnapshot(title: " Song ", artist: "Artist", album: "", duration: 200.004)
        let first = LyricsQuery(snapshot: snapshot)
        snapshot.duration = 199.8
        #expect(first == LyricsQuery(snapshot: snapshot))
        #expect(first?.title == "Song")
        #expect(first?.album == nil)

        snapshot.artist = nil
        #expect(LyricsQuery(snapshot: snapshot) == nil)
    }

    @Test("Lyrics are opt-in")
    @MainActor
    func lyricsAreOptIn() {
        let defaults = UserDefaults(suiteName: "notchshot.lyrics-tests.\(UUID().uuidString)")!
        #expect(Preferences(defaults: defaults).lyricsEnabled == false)
    }
}
