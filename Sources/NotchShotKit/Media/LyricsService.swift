import Foundation

/// One line of lyrics. `time` is nil for plain (unsynced) lyrics.
public struct LyricLine: Sendable, Equatable, Identifiable {
    public var id: Int
    public var time: TimeInterval?
    public var text: String
}

public struct Lyrics: Sendable, Equatable {
    public var lines: [LyricLine]
    /// True when every line carries a timestamp, so the current line can be
    /// followed as the track plays.
    public var isSynced: Bool
    /// The source marked the track as an instrumental.
    public var isInstrumental: Bool

    public static let instrumental = Lyrics(lines: [], isSynced: false, isInstrumental: true)

    /// The line being sung at `position`: the last line whose timestamp has
    /// passed. Nil before the first line starts, and for unsynced lyrics.
    public func currentLineIndex(at position: TimeInterval) -> Int? {
        guard isSynced, !lines.isEmpty else { return nil }
        // Binary search: called several times a second while the panel is open.
        var low = 0
        var high = lines.count - 1
        var found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if let time = lines[mid].time, time <= position {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }
}

/// The track a lyrics lookup is for. Equality decides when a lookup is reused.
public struct LyricsQuery: Sendable, Hashable {
    public var title: String
    public var artist: String
    public var album: String?
    public var duration: TimeInterval?

    public init?(snapshot: MediaSnapshot) {
        guard let title = snapshot.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
              let artist = snapshot.artist?.trimmingCharacters(in: .whitespacesAndNewlines), !artist.isEmpty
        else { return nil }
        self.title = title
        self.artist = artist
        let album = snapshot.album?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.album = album?.isEmpty == false ? album : nil
        // Whole seconds: players report fractional lengths that differ by a
        // few milliseconds between polls, which must not count as a new track.
        self.duration = MediaTimePolicy.normalized(snapshot.duration).flatMap { $0 > 0 ? $0.rounded() : nil }
    }

    public init(title: String, artist: String, album: String? = nil, duration: TimeInterval? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = MediaTimePolicy.normalized(duration).flatMap { $0 > 0 ? $0 : nil }
    }
}

/// Looks lyrics up on LRCLIB (lrclib.net), a free, open lyrics database that
/// needs no account or key.
///
/// Only runs when the user has opted in, because it sends the track's title,
/// artist, album and length to a third party. Nothing else is sent; results
/// are kept in memory only, for the session.
public actor LyricsService {
    public static let shared = LyricsService()

    public enum LookupError: Error, Equatable {
        case notFound
        case unavailable
    }

    private static let host = URL(string: "https://lrclib.net/api/")!
    /// Tracks this far off the player's length are a different recording
    /// (a live take, a radio edit) whose timestamps would drift.
    static let durationTolerance: TimeInterval = 3
    private static let cacheLimit = 40
    /// Lyrics answers are a few kilobytes; anything near this is not one.
    static let maximumResponseBytes = 2_000_000

    private let session: URLSession
    private var cache: [LyricsQuery: Result<Lyrics, LookupError>] = [:]
    private var cacheOrder: [LyricsQuery] = []
    private var inFlight: [LyricsQuery: Task<Result<Lyrics, LookupError>, Never>] = [:]

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 8
            configuration.timeoutIntervalForResource = 12
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpAdditionalHeaders = [
                // LRCLIB asks clients to identify themselves.
                "User-Agent": "NotchShot/\(Bundle.main.shortVersion) (macOS)",
            ]
            self.session = URLSession(configuration: configuration)
        }
    }

    public func lyrics(for query: LyricsQuery) async -> Result<Lyrics, LookupError> {
        if let cached = cache[query] { return cached }
        if let running = inFlight[query] { return await running.value }
        let task = Task { await self.fetch(query) }
        inFlight[query] = task
        let result = await task.value
        inFlight[query] = nil
        // A network failure is not remembered, so reopening the panel retries;
        // "no lyrics for this track" is.
        if result != .failure(.unavailable) { remember(result, for: query) }
        return result
    }

    private func remember(_ result: Result<Lyrics, LookupError>, for query: LyricsQuery) {
        cache[query] = result
        cacheOrder.removeAll { $0 == query }
        cacheOrder.append(query)
        while cacheOrder.count > Self.cacheLimit {
            cache[cacheOrder.removeFirst()] = nil
        }
    }

    private func fetch(_ query: LyricsQuery) async -> Result<Lyrics, LookupError> {
        // The exact-match endpoint first; it needs the length to disambiguate.
        if query.duration != nil {
            switch await get(query) {
            case .success(let record):
                if let lyrics = Self.lyrics(from: record) { return .success(lyrics) }
            case .failure(.unavailable):
                return .failure(.unavailable)
            case .failure(.notFound):
                break
            }
        }
        // Then a search, which tolerates a slightly different album name.
        switch await search(query) {
        case .success(let records):
            guard let record = Self.bestMatch(records, for: query),
                  let lyrics = Self.lyrics(from: record)
            else { return .failure(.notFound) }
            return .success(lyrics)
        case .failure(let error):
            return .failure(error)
        }
    }

    private func get(_ query: LyricsQuery) async -> Result<LRCLIBRecord, LookupError> {
        var items = [
            URLQueryItem(name: "track_name", value: query.title),
            URLQueryItem(name: "artist_name", value: query.artist),
        ]
        if let album = query.album { items.append(URLQueryItem(name: "album_name", value: album)) }
        if let duration = MediaTimePolicy.wholeSeconds(query.duration, rounding: .towardZero) {
            items.append(URLQueryItem(name: "duration", value: String(duration)))
        }
        return await request("get", items: items)
    }

    private func search(_ query: LyricsQuery) async -> Result<[LRCLIBRecord], LookupError> {
        await request("search", items: [
            URLQueryItem(name: "track_name", value: query.title),
            URLQueryItem(name: "artist_name", value: query.artist),
        ])
    }

    private func request<T: Decodable>(_ path: String, items: [URLQueryItem]) async -> Result<T, LookupError> {
        guard var components = URLComponents(
            url: Self.host.appending(path: path),
            resolvingAgainstBaseURL: false
        ) else { return .failure(.unavailable) }
        components.queryItems = items
        guard let url = components.url else { return .failure(.unavailable) }
        do {
            // Streamed so the bound holds while the body arrives, rather than
            // after a large answer has been buffered whole.
            let (bytes, response) = try await session.bytes(from: url)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { return .failure(.unavailable) }
            if http.statusCode == 404 { return .failure(.notFound) }
            guard (200..<300).contains(http.statusCode),
                  http.expectedContentLength < Int64(Self.maximumResponseBytes) else {
                return .failure(.unavailable)
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < Self.maximumResponseBytes - 1 else { return .failure(.unavailable) }
                data.append(byte)
            }
            return .success(try JSONDecoder().decode(T.self, from: data))
        } catch is DecodingError {
            return .failure(.notFound)
        } catch {
            return .failure(.unavailable)
        }
    }

    static func bestMatch(_ records: [LRCLIBRecord], for query: LyricsQuery) -> LRCLIBRecord? {
        let usable = records.filter { record in
            guard record.instrumental == true || record.syncedLyrics?.isEmpty == false
                || record.plainLyrics?.isEmpty == false
            else { return false }
            guard let wanted = query.duration, let length = record.duration else { return true }
            return abs(length - wanted) <= durationTolerance
        }
        // Prefer synced lyrics, then the closest length.
        return usable.min { lhs, rhs in
            let lhsSynced = lhs.syncedLyrics?.isEmpty == false
            let rhsSynced = rhs.syncedLyrics?.isEmpty == false
            if lhsSynced != rhsSynced { return lhsSynced }
            guard let wanted = query.duration else { return false }
            return abs((lhs.duration ?? .infinity) - wanted) < abs((rhs.duration ?? .infinity) - wanted)
        }
    }

    static func lyrics(from record: LRCLIBRecord) -> Lyrics? {
        if record.instrumental == true { return .instrumental }
        if let synced = record.syncedLyrics, let parsed = LRCParser.parse(synced), !parsed.isEmpty {
            return Lyrics(lines: parsed, isSynced: true, isInstrumental: false)
        }
        if let plain = record.plainLyrics {
            let lines = plain
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .enumerated()
                .map { LyricLine(id: $0.offset, time: nil, text: $0.element) }
            if lines.contains(where: { !$0.text.isEmpty }) {
                return Lyrics(lines: lines, isSynced: false, isInstrumental: false)
            }
        }
        return nil
    }
}

struct LRCLIBRecord: Decodable, Sendable, Equatable {
    var duration: TimeInterval?
    var instrumental: Bool?
    var plainLyrics: String?
    var syncedLyrics: String?
}

/// Parses LRC text: `[mm:ss.xx] words`, with any number of leading
/// timestamps per line and metadata tags (`[ar:…]`, `[offset:…]`) ignored
/// except for the offset.
enum LRCParser {
    static func parse(_ text: String) -> [LyricLine]? {
        var offset: TimeInterval = 0
        var timed: [(time: TimeInterval, text: String)] = []

        for rawLine in text.components(separatedBy: .newlines) {
            var rest = Substring(rawLine.trimmingCharacters(in: .whitespaces))
            var stamps: [TimeInterval] = []
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if let time = timestamp(tag) {
                    stamps.append(time)
                } else if tag.lowercased().hasPrefix("offset:"),
                          let milliseconds = Double(tag.dropFirst("offset:".count).trimmingCharacters(in: .whitespaces)) {
                    // A positive offset means the lyrics should appear sooner.
                    offset = -milliseconds / 1000
                }
                rest = rest[rest.index(after: close)...]
            }
            let words = rest.trimmingCharacters(in: .whitespaces)
            for stamp in stamps { timed.append((stamp, words)) }
        }

        guard !timed.isEmpty else { return nil }
        return timed
            .enumerated()
            .sorted { $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time }
            .enumerated()
            .map { index, entry in
                LyricLine(id: index, time: max(0, entry.element.time + offset), text: entry.element.text)
            }
    }

    /// `mm:ss`, `mm:ss.xx` or `mm:ss:xx`.
    static func timestamp(_ tag: Substring) -> TimeInterval? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              let minutes = Int(parts[0]), minutes >= 0
        else { return nil }
        let secondsText = parts.count == 3 ? "\(parts[1]).\(parts[2])" : String(parts[1])
        guard let seconds = Double(secondsText), seconds >= 0, seconds < 60 else { return nil }
        return TimeInterval(minutes) * 60 + seconds
    }
}
