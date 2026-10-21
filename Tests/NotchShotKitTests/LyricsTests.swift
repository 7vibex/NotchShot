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

    @Test("A small answer is read and decoded")
    func smallAnswerIsDecoded() async throws {
        let body = Data(#"{"syncedLyrics":"[00:01.00]Hello","duration":200}"#.utf8)
        let service = LyricsService(session: LyricsResponseStub.session(body: body, finishes: true))
        let query = try #require(LyricsQuery(snapshot: MediaSnapshot(
            title: "Song", artist: "Artist", album: nil, duration: 200
        )))
        let result = await service.lyrics(for: query)
        #expect(result.map(\.lines.count) == .success(1))
    }

    /// The old read buffered the whole body first, so a server that kept
    /// sending held the lookup until the 12-second resource timeout.
    @Test("An oversized answer is refused as it arrives")
    func oversizedAnswerIsRefusedWhileStreaming() async throws {
        let body = Data(repeating: UInt8(ascii: " "), count: LyricsService.maximumResponseBytes + 1)
        let service = LyricsService(session: LyricsResponseStub.session(body: body, finishes: false))
        let query = try #require(LyricsQuery(snapshot: MediaSnapshot(
            title: "Song", artist: "Artist", album: nil, duration: 200
        )))
        let started = Date()
        #expect(await service.lyrics(for: query) == .failure(.unavailable))
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test("Lyrics are opt-in")
    @MainActor
    func lyricsAreOptIn() {
        let defaults = UserDefaults(suiteName: "notchshot.lyrics-tests.\(UUID().uuidString)")!
        #expect(Preferences(defaults: defaults).lyricsEnabled == false)
    }
}

/// Serves one canned body to every request. With `finishes` false the load
/// never completes, like a server that keeps the connection open.
private final class LyricsResponseStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bodies: [String: (Data, Bool)] = [:]

    static func session(body: Data, finishes: Bool) -> URLSession {
        let key = UUID().uuidString
        lock.withLock { bodies[key] = (body, finishes) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LyricsResponseStub.self]
        configuration.httpAdditionalHeaders = ["X-Stub": key]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = request.value(forHTTPHeaderField: "X-Stub") ?? ""
        guard let (body, finishes) = Self.lock.withLock({ Self.bodies[key] }),
              let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        if finishes { client?.urlProtocolDidFinishLoading(self) }
    }

    override func stopLoading() {}
}
