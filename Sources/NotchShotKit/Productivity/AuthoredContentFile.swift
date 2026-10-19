import Darwin
import Foundation

/// Notes and manual lyrics share a byte contract. Legacy oversized content is
/// recoverable without trimming; a failed read never grants write authority.
struct AuthoredContentFile {
    static let maximumStoreBytes = 8 * 1_024 * 1_024
    static let maximumRecoverableBytes = 32 * 1_024 * 1_024

    enum PersistenceError: LocalizedError {
        case readLocked, tooLarge, changed

        var errorDescription: String? {
            switch self {
            case .readLocked:
                "The saved content could not be read. Its file was left untouched; repair or restore it before saving."
            case .tooLarge:
                "Saved content must fit within 8 MiB. This change was not saved; reduce the content and try again."
            case .changed:
                "The saved content changed outside this window. Reopen it before saving; the other file was left untouched."
            }
        }
    }

    let url: URL
    private(set) var canWrite = false
    private(set) var recoveryBackupURL: URL?
    private var loadedIdentity: ExternalFileIdentity?
    private var recoveryData: Data?
    var recoveredOversizedContent: Bool { recoveryData != nil }

    init(url: URL) { self.url = url }

    mutating func load<Value: Decodable>(_ type: Value.Type) throws -> Value? {
        guard url.isFileURL else { throw PersistenceError.readLocked }
        var information = stat()
        if lstat(url.path, &information) != 0 {
            guard errno == ENOENT else { throw PersistenceError.readLocked }
            canWrite = true
            return nil
        }
        guard let identity = SafeAssetFile.identity(
            at: url, maximumBytes: Int64(Self.maximumRecoverableBytes)
        ) else { throw PersistenceError.readLocked }
        let data = try SafeAssetFile.readData(
            at: url,
            maximumBytes: Int64(Self.maximumRecoverableBytes),
            expectedIdentity: identity
        )
        let value = try JSONDecoder().decode(type, from: data)
        loadedIdentity = identity
        if data.count > Self.maximumStoreBytes { recoveryData = data }
        canWrite = true
        return value
    }

    mutating func save<Value: Encodable>(_ value: Value) throws {
        guard canWrite else { throw PersistenceError.readLocked }
        let data = try JSONEncoder().encode(value)
        guard data.count <= Self.maximumStoreBytes else { throw PersistenceError.tooLarge }
        try requireUnchangedFile()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Before the first smaller save of recovered content, retain the exact
        // legacy bytes. Never rewrite the oversized original during loading.
        if let recoveryData, recoveryBackupURL == nil {
            let backup = url.appendingPathExtension("recovered-\(UUID().uuidString)")
            try recoveryData.write(to: backup, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            recoveryBackupURL = backup
        }
        try requireUnchangedFile()
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        loadedIdentity = SafeAssetFile.identity(at: url, maximumBytes: Int64(Self.maximumStoreBytes))
        canWrite = loadedIdentity != nil
        recoveryData = nil
    }

    private func requireUnchangedFile() throws {
        if let loadedIdentity {
            guard SafeAssetFile.identity(at: url, maximumBytes: Int64(Self.maximumRecoverableBytes)) == loadedIdentity
            else { throw PersistenceError.changed }
        } else {
            var information = stat()
            guard lstat(url.path, &information) != 0, errno == ENOENT else { throw PersistenceError.changed }
        }
    }
}
