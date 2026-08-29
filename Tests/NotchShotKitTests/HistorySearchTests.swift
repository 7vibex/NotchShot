import Foundation
import Testing

@testable import NotchShotKit

/// History search answers the common case by scanning UTF-8 bytes with ASCII
/// case folding instead of allocating lowercased copies. That is only equivalent
/// while the text is ASCII, so these tests pin it against the Unicode-correct
/// implementation it replaced — especially on the characters whose case folding
/// is not ASCII.
@Suite("History search")
struct HistorySearchTests {

    /// The pre-optimisation implementation, kept verbatim as the oracle.
    private static func referenceMatches(_ entry: HistoryEntry, _ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let needle = query.lowercased()
        if entry.fileURL.lastPathComponent.lowercased().contains(needle) { return true }
        if entry.sourceApplicationName?.lowercased().contains(needle) == true { return true }
        if entry.kind.displayName.lowercased().contains(needle) { return true }
        if let text = entry.indexedText, text.lowercased().contains(needle) { return true }
        return false
    }

    private static func entry(
        filename: String,
        application: String? = nil,
        text: String? = nil
    ) -> HistoryEntry {
        HistoryEntry(
            asset: CaptureAsset(
                url: URL(fileURLWithPath: "/Users/test/Pictures/\(filename)"),
                kind: .screenshot,
                pixelSize: CGSize(width: 100, height: 100),
                sourceApplicationName: application
            ),
            thumbnailFilename: nil,
            indexedText: text
        )
    }

    /// Filenames, app names and recognised text spanning ASCII, accented Latin,
    /// non-Latin scripts, and the characters whose lowercase form is not the
    /// ASCII one: the Kelvin sign, the dotted capital I, and the sharp s.
    private static let corpus: [HistoryEntry] = [
        entry(filename: "Screenshot 2026.png", application: "Safari", text: "Dashboard revenue"),
        entry(filename: "CAPTURE.PNG", application: "Xcode", text: "THRESHOLD BASELINE"),
        entry(filename: "Café Menu.png", application: "Café App", text: "Crème brûlée"),
        entry(filename: "CAFÉ MENU.png", application: "CAFÉ APP", text: "CRÈME BRÛLÉE"),
        entry(filename: "Кириллица.png", application: "Телеграм", text: "ПРИВЕТ МИР"),
        entry(filename: "スクリーンショット.png", application: "メモ", text: "こんにちは"),
        entry(filename: "Kelvin \u{212A}.png", application: nil, text: "temperature \u{212A}"),
        entry(filename: "\u{130}stanbul.png", application: nil, text: "\u{130}ZM\u{130}R"),
        entry(filename: "Straße.png", application: nil, text: "STRASSE"),
        entry(filename: "mixed Ünicode ascii.png", application: "Ünicode", text: "ascii tail"),
        entry(filename: "decomposed.png", application: nil, text: "cafe\u{301}"),
        entry(filename: "lines.png", application: nil, text: "first\r\nsecond"),
        entry(filename: "overlap.png", application: nil, text: "aaaab ABABABAC"),
        entry(filename: "empty.png", application: nil, text: nil),
    ]

    private static let queries: [String] = [
        "", "png", "PNG", "Png",
        "safari", "SAFARI", "xcode",
        "threshold", "THRESHOLD", "ThReShOlD",
        "café", "CAFÉ", "Café", "cafe",
        "crème", "CRÈME", "brûlée",
        "кириллица", "КИРИЛЛИЦА", "привет",
        "スクリーン", "こんにちは",
        "\u{212A}", "k", "K", "kelvin",
        "\u{130}", "i", "istanbul", "\u{130}stanbul",
        "straße", "STRASSE", "strasse",
        "ünicode", "ÜNICODE", "unicode",
        "screenshot 2026", "no-such-term", "  ", "é", "\n",
        "aaab", "ababac",
    ]

    @Test("Prepared matcher agrees with Unicode matching across scripts and case")
    func matchesAgreeWithReference() {
        for entry in Self.corpus {
            for query in Self.queries {
                #expect(
                    entry.matches(query) == Self.referenceMatches(entry, query),
                    "disagreement for query '\(query)' on \(entry.fileURL.lastPathComponent)"
                )
            }
        }
    }

    @Test("Matcher handles overlaps and late grapheme hazards")
    func matcherEdgeCases() {
        let cases = [
            ("aaaab", "aaab"),
            ("abababac", "ababac"),
            ("AAaaB", "aab"),
            ("cafe\u{301}", "cafe"),
            ("first\r\nsecond", "\n"),
            ("shortÜ", "longer-query"),
        ]
        for (haystack, query) in cases {
            #expect(
                HistoryQuery(query).appears(in: haystack)
                    == haystack.lowercased().contains(query.lowercased()),
                "disagreement for '\(query)' in '\(haystack)'"
            )
        }
    }

    @Test("Repeated query cache invalidates after searchable content changes")
    @MainActor
    func repeatedQueryCacheInvalidation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-search-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("history.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([
            Self.entry(filename: "capture.png", text: "private dashboard phrase"),
        ]).write(to: store)

        let repository = HistoryRepository(storeURL: store)
        #expect(repository.search("dashboard").count == 1)
        #expect(repository.search("dashboard").count == 1)

        repository.purgeIndexedText()
        #expect(repository.search("dashboard").isEmpty)
        try repository.save()
    }

    @Test("A prepared query matches the string form")
    func preparedQueryAgrees() {
        for entry in Self.corpus {
            for query in Self.queries {
                #expect(entry.matches(HistoryQuery(query)) == entry.matches(query))
            }
        }
    }

    @Test("Repository search returns the same rows as row-by-row matching")
    @MainActor
    func repositorySearchAgrees() throws {
        let store = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("notchshot-search-\(UUID().uuidString).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Self.corpus).write(to: store)
        defer { try? FileManager.default.removeItem(at: store) }

        let repository = HistoryRepository(storeURL: store)
        #expect(repository.entries.count == Self.corpus.count)

        for query in Self.queries {
            let expected = repository.entries.filter { Self.referenceMatches($0, query) }
            #expect(
                repository.search(query).map(\.id) == expected.map(\.id),
                "disagreement for query '\(query)'"
            )
        }
    }
}
