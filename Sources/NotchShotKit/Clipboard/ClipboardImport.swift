import Foundation
import SQLite3

/// Brings text history across from another clipboard manager, so switching
/// to NotchShot doesn't start from an empty list.
///
/// Only text is imported. Both apps' databases are read from a private copy
/// (the file plus its write-ahead log), so the other app is never locked or
/// modified, even while it's running. Raycast encrypts its history and can't
/// be read this way.
public enum ClipboardImportSource: String, CaseIterable, Identifiable, Sendable {
    case maccy
    case alfred

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .maccy: "Maccy"
        case .alfred: "Alfred"
        }
    }

    /// Where the app keeps its database by default.
    public var defaultURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .maccy:
            return home.appendingPathComponent(
                "Library/Containers/org.p0deje.Maccy/Data/Library/Application Support/Maccy/Storage.sqlite"
            )
        case .alfred:
            return home.appendingPathComponent("Library/Application Support/Alfred/Databases/clipboard.alfdb")
        }
    }
}

/// One clipping read from another app.
public struct ImportedClipping: Equatable, Sendable {
    public var text: String
    public var copiedAt: Date
    public var applicationName: String?
    public var isPinned: Bool
}

public enum ClipboardImporter {
    public static let maximumItems = 2_000

    public enum ImportError: LocalizedError {
        case unreadable(String)
        case unrecognized(ClipboardImportSource)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let message): "The database couldn't be opened: \(message)"
            case .unrecognized(let source): "That doesn't look like a \(source.title) clipboard database."
            }
        }
    }

    /// Reads up to `maximumItems` text clippings, newest first.
    public static func read(_ source: ClipboardImportSource, from url: URL) throws -> [ImportedClipping] {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let copy = workspace.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: copy)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try? FileManager.default.copyItem(at: sidecar, to: URL(fileURLWithPath: copy.path + suffix))
            }
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(database)
            throw ImportError.unreadable(message)
        }
        defer { sqlite3_close(database) }

        switch source {
        case .maccy: return try readMaccy(database)
        case .alfred: return try readAlfred(database)
        }
    }

    /// Records clippings oldest first, so the store's own newest-first order
    /// matches the other app's. Returns how many were new.
    @MainActor
    @discardableResult
    public static func importClippings(_ clippings: [ImportedClipping], into store: ClipboardStore, sourceName: String) -> Int {
        let existing = Set(store.ordered.map { $0.kind.rawValue + ":" + $0.contentHash })
        for clipping in clippings.reversed() {
            var text = clipping.text
            if text.utf8.count > ClipboardStore.maximumTextBytes {
                text = String(text.prefix(ClipboardStore.maximumTextBytes / 4))
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            store.record(ClipboardEntry(
                kind: ClipboardMonitor.classify(trimmed),
                text: text,
                sourceApplicationName: clipping.applicationName ?? sourceName,
                createdAt: clipping.copiedAt,
                isPinned: clipping.isPinned,
                contentHash: ClipboardEntry.hash(forText: text)
            ))
        }
        // Retention can replace rows without growing the store. Report new
        // content that was actually retained, rather than net row growth.
        return store.ordered.count { !existing.contains($0.kind.rawValue + ":" + $0.contentHash) }
    }

    // MARK: Schemas

    /// Maccy 2 (SwiftData) and Maccy 0.x (Core Data) share these tables: an
    /// item row per clipping and a content row per pasteboard type.
    static func readMaccy(_ database: OpaquePointer) throws -> [ImportedClipping] {
        guard tableExists("ZHISTORYITEM", in: database), tableExists("ZHISTORYITEMCONTENT", in: database) else {
            throw ImportError.unrecognized(.maccy)
        }
        let itemColumns = columns(of: "ZHISTORYITEM", in: database)
        let dateColumn = itemColumns.contains("ZLASTCOPIEDAT") ? "i.ZLASTCOPIEDAT" : "i.ZFIRSTCOPIEDAT"
        let appColumn = itemColumns.contains("ZAPPLICATION") ? "i.ZAPPLICATION" : "NULL"
        let pinColumn = itemColumns.contains("ZPIN") ? "i.ZPIN" : "NULL"
        let sql = """
            SELECT c.ZVALUE, \(dateColumn), \(appColumn), \(pinColumn)
            FROM ZHISTORYITEM i JOIN ZHISTORYITEMCONTENT c ON c.ZITEM = i.Z_PK
            WHERE c.ZTYPE = 'public.utf8-plain-text'
            ORDER BY \(dateColumn) DESC
            LIMIT \(maximumItems)
            """
        return try rows(sql, in: database) { statement in
            guard let text = blobOrText(statement, 0) else { return nil }
            return ImportedClipping(
                text: text,
                copiedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 1)),
                applicationName: applicationName(fromBundleIdentifier: columnText(statement, 2)),
                isPinned: sqlite3_column_type(statement, 3) != SQLITE_NULL
            )
        }
    }

    /// Alfred keeps one `clipboard` table; `dataType` 0 is text and `ts` is
    /// seconds since 2001.
    static func readAlfred(_ database: OpaquePointer) throws -> [ImportedClipping] {
        guard tableExists("clipboard", in: database) else { throw ImportError.unrecognized(.alfred) }
        let sql = """
            SELECT item, ts, app FROM clipboard
            WHERE dataType = 0
            ORDER BY ts DESC
            LIMIT \(maximumItems)
            """
        return try rows(sql, in: database) { statement in
            guard let text = columnText(statement, 0) else { return nil }
            return ImportedClipping(
                text: text,
                copiedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 1)),
                applicationName: columnText(statement, 2),
                isPinned: false
            )
        }
    }

    // MARK: SQLite helpers

    private static func rows(
        _ sql: String,
        in database: OpaquePointer,
        map: (OpaquePointer) -> ImportedClipping?
    ) throws -> [ImportedClipping] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ImportError.unreadable(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        var result: [ImportedClipping] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let clipping = map(statement) { result.append(clipping) }
        }
        return result
    }

    private static func tableExists(_ name: String, in database: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        sqlite3_bind_text(statement, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func columns(of table: String, in database: OpaquePointer) -> Set<String> {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else { return [] }
        var names = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = columnText(statement!, 1) { names.insert(name) }
        }
        return names
    }

    private static func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    /// Maccy stores the text as a UTF-8 blob.
    private static func blobOrText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_BLOB:
            guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
            return String(data: data, encoding: .utf8)
        case SQLITE_TEXT:
            return columnText(statement, index)
        default:
            return nil
        }
    }

    private static func applicationName(fromBundleIdentifier value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        // Maccy records a bundle identifier; show the last component rather
        // than "com.apple.Safari".
        return value.split(separator: ".").last.map(String.init) ?? value
    }
}
