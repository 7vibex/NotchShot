import Darwin
import Foundation

/// Notes and manual lyrics share a byte contract. Legacy oversized content is
/// recoverable without trimming; a failed read never grants write authority.
struct AuthoredContentFile: Sendable {
    static let maximumStoreBytes = 8 * 1_024 * 1_024
    static let maximumRecoverableBytes = 32 * 1_024 * 1_024

    enum PersistenceError: LocalizedError {
        case readLocked, tooLarge, changed
        case textTooLong(Int)

        var errorDescription: String? {
            switch self {
            case .readLocked:
                "The saved content could not be read. Its file was left untouched; repair or restore it before saving."
            case .tooLarge:
                "Saved content must fit within 8 MiB. This change was not saved; reduce the content and try again."
            case .changed:
                "The saved content changed outside this window. Reopen it before saving; the other file was left untouched."
            case .textTooLong(let limit):
                "Text must fit within \(limit.formatted()) characters. This change was not saved; shorten it and try again."
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

/// Owns an `AuthoredContentFile` on one serial queue, so a whole-store encode
/// and write can leave the main thread and still happen in order. The owner
/// keeps a copy of the returned file for reading `canWrite` and the backup URL.
final class AuthoredContentWriter: @unchecked Sendable {
    struct Outcome: Sendable {
        var file: AuthoredContentFile
        var errorDescription: String?
        /// Counts saves in the order they ran, so a late report of an earlier
        /// one can be told from a newer one.
        var sequence: Int
    }

    private let queue = DispatchQueue(label: "NotchShot.AuthoredContent", qos: .userInitiated)
    /// Only touched on `queue`.
    private var file: AuthoredContentFile
    private var sequence = 0

    init(file: AuthoredContentFile) {
        self.file = file
    }

    /// Returns once this save, and any queued ahead of it, are on disk. For
    /// discrete actions that report their result, and for quitting.
    func saveNow<Value: Encodable & Sendable>(_ value: Value) -> Outcome {
        queue.sync { write(value) }
    }

    func save<Value: Encodable & Sendable>(
        _ value: Value,
        completion: @escaping @MainActor @Sendable (Outcome) -> Void
    ) {
        queue.async { [self] in
            let outcome = write(value)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(outcome) }
            }
        }
    }

    private func write<Value: Encodable>(_ value: Value) -> Outcome {
        sequence += 1
        do {
            try file.save(value)
            return Outcome(file: file, errorDescription: nil, sequence: sequence)
        } catch {
            return Outcome(file: file, errorDescription: error.localizedDescription, sequence: sequence)
        }
    }
}
