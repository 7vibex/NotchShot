import Darwin
import Foundation

/// Stable identity captured when a Finder file enters the shelf. Requiring the
/// same inode/size/mtime later prevents a path swap from turning Save As or
/// Bug Report into a copier for unrelated local content.
public struct ExternalFileIdentity: Codable, Sendable, Equatable {
    public var device: UInt64
    public var inode: UInt64
    public var size: Int64
    public var modifiedSeconds: Int64
    public var modifiedNanoseconds: Int64
    /// The volume's persistent UUID, when the file system has one. Nil in
    /// identities recorded before it was kept.
    public var volume: UUID? = nil

    /// Whether two identities name the same item. The device number is kept
    /// for the record but not compared: APFS assigns `st_dev` when a volume
    /// mounts, so every identity stored before a restart or a remount carried
    /// a stale one, and the same untouched file read as "changed" forever.
    /// The volume UUID survives remounts, so when both sides have one it
    /// stands in for the device: a file on another volume with a matching
    /// inode, size and time is still a different file. Inode, size and the
    /// nanosecond modification time pin the item, and every check reaches it
    /// without following a final symbolic link.
    public static func == (lhs: ExternalFileIdentity, rhs: ExternalFileIdentity) -> Bool {
        if let left = lhs.volume, let right = rhs.volume, left != right { return false }
        return lhs.inode == rhs.inode
            && lhs.size == rhs.size
            && lhs.modifiedSeconds == rhs.modifiedSeconds
            && lhs.modifiedNanoseconds == rhs.modifiedNanoseconds
    }
}

enum SafeAssetFile {
    static let maximumExternalBytes: Int64 = 500_000_000
    static let maximumOwnedBytes: Int64 = 20_000_000_000

    static func identity(at url: URL, maximumBytes: Int64) -> ExternalFileIdentity? {
        fileSystemIdentity(
            at: url,
            maximumBytes: maximumBytes,
            allowsDirectory: false
        )
    }

    /// Identity for a regular file or, when explicitly requested, a directory
    /// such as a `.notchshot` package. `lstat` deliberately refuses symbolic
    /// links; a path alias must never become authority to read or remove its
    /// target.
    static func fileSystemIdentity(
        at url: URL,
        maximumBytes: Int64,
        allowsDirectory: Bool
    ) -> ExternalFileIdentity? {
        guard url.isFileURL else { return nil }
        var information = stat()
        let path = url.standardizedFileURL.path
        guard lstat(path, &information) == 0 else { return nil }
        let type = information.st_mode & S_IFMT
        guard type == S_IFREG || (allowsDirectory && type == S_IFDIR),
              information.st_size >= 0,
              type == S_IFDIR || information.st_size <= maximumBytes else { return nil }
        var volume = statfs()
        let hasVolume = statfs(path, &volume) == 0
        return identity(from: information, volume: hasVolume ? volume : nil)
    }

    static func requireCurrentItem(
        at url: URL,
        expectedIdentity: ExternalFileIdentity?,
        maximumBytes: Int64,
        allowsDirectory: Bool = false
    ) throws {
        guard let expectedIdentity else {
            throw NotchShotError.exportFailed(
                "NotchShot cannot verify this older file safely. Remove only its History entry, or add the current file again."
            )
        }
        guard let current = fileSystemIdentity(
            at: url,
            maximumBytes: maximumBytes,
            allowsDirectory: allowsDirectory
        ), current == expectedIdentity else {
            throw NotchShotError.exportFailed(
                "That file changed after NotchShot recorded it. The replacement was left untouched."
            )
        }
    }

    static func isCurrentAndSafe(_ asset: CaptureAsset) -> Bool {
        let maximum = asset.ownership == .externalReference
            ? maximumExternalBytes : maximumOwnedBytes
        guard let current = identity(at: asset.url, maximumBytes: maximum) else { return false }
        if let expected = asset.externalFileIdentity {
            return expected == current
        }
        // Legacy owned captures did not persist an identity. They remain
        // readable, but destructive History operations separately fail closed.
        return asset.ownership != .externalReference
    }

    /// The identity a read after a wait (a dialog, a network round trip)
    /// must still find: the recorded one, or for a legacy owned capture that
    /// never stored one, the file's identity now. Nil when the file is no
    /// longer current and safe.
    static func selectionIdentity(of asset: CaptureAsset) -> ExternalFileIdentity? {
        guard isCurrentAndSafe(asset) else { return nil }
        return asset.externalFileIdentity
            ?? identity(at: asset.url, maximumBytes: maximumOwnedBytes)
    }

    /// Permissions for a copy the user will see and hand to someone else.
    ///
    /// `open` masks this with the process umask, so it lands at the same
    /// permissions any other app's Save As would produce — usually 0644.
    /// The default below is deliberately tighter and is what a diagnostic
    /// package or an app-managed working file should keep.
    static let userVisibleMode = mode_t(0o666)

    /// Copies from an `O_NOFOLLOW` descriptor into a new destination. The
    /// descriptor pins the validated inode even if its path is replaced during
    /// the operation; the caller supplies a unique staging destination.
    static func copy(
        _ asset: CaptureAsset,
        to destination: URL,
        mode: mode_t = mode_t(S_IRUSR | S_IWUSR)
    ) throws {
        let maximum = asset.ownership == .externalReference
            ? maximumExternalBytes : maximumOwnedBytes
        let expectedIdentity: ExternalFileIdentity?
        if asset.ownership == .externalReference {
            guard let identity = asset.externalFileIdentity else {
                throw NotchShotError.exportFailed(
                    "That Finder file changed after it was added. Remove it and add the current file again."
                )
            }
            expectedIdentity = identity
        } else {
            expectedIdentity = nil
        }
        try copyValidatedSource(
            at: asset.url,
            maximumBytes: maximum,
            expectedIdentity: expectedIdentity,
            changedMessage: "That Finder file changed after it was added. Remove it and add the current file again.",
            to: destination,
            mode: mode
        )
    }

    /// Copies the exact inode the caller validated, refusing a pathname
    /// replacement that happened in between. Used where a file is authorized
    /// first and read after an asynchronous wait (a transfer snapshot).
    static func copyVerified(
        from url: URL,
        expectedIdentity: ExternalFileIdentity,
        maximumBytes: Int64,
        to destination: URL,
        mode: mode_t = mode_t(S_IRUSR | S_IWUSR)
    ) throws {
        try copyValidatedSource(
            at: url,
            maximumBytes: maximumBytes,
            expectedIdentity: expectedIdentity,
            changedMessage: "The source file changed after it was selected. Nothing was copied.",
            to: destination,
            mode: mode
        )
    }

    private static func copyValidatedSource(
        at url: URL,
        maximumBytes: Int64,
        expectedIdentity: ExternalFileIdentity?,
        changedMessage: String,
        to destination: URL,
        mode: mode_t
    ) throws {
        guard destination.isFileURL,
              !FileManager.default.fileExists(atPath: destination.path) else {
            throw NotchShotError.destinationUnwritable(destination.path)
        }
        let sourceDescriptor = Darwin.open(
            url.standardizedFileURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard sourceDescriptor >= 0 else {
            throw NotchShotError.exportFailed("The source file is no longer safely readable")
        }
        let source = FileHandle(fileDescriptor: sourceDescriptor, closeOnDealloc: true)

        var information = stat()
        guard fstat(sourceDescriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_size >= 0,
              information.st_size <= maximumBytes else {
            throw NotchShotError.exportFailed("The source file is unsafe or too large")
        }
        if let expectedIdentity, identity(from: information, descriptor: sourceDescriptor) != expectedIdentity {
            throw NotchShotError.exportFailed(changedMessage)
        }

        let destinationDescriptor = Darwin.open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode
        )
        guard destinationDescriptor >= 0 else {
            throw NotchShotError.destinationUnwritable(destination.path)
        }
        let output = FileHandle(fileDescriptor: destinationDescriptor, closeOnDealloc: true)
        do {
            var total = Int64(0)
            while let chunk = try source.read(upToCount: 1_048_576), !chunk.isEmpty {
                total += Int64(chunk.count)
                guard total <= maximumBytes else {
                    throw NotchShotError.exportFailed("The source file grew beyond the safe copy limit")
                }
                try output.write(contentsOf: chunk)
            }
            try output.synchronize()
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Reads bounded bytes from the same `O_NOFOLLOW` descriptor whose type,
    /// size, and optional external identity were validated. ImageIO and JSON
    /// therefore decode the inode that passed validation, not a later pathname
    /// replacement.
    static func readData(
        at url: URL,
        maximumBytes: Int64,
        expectedIdentity: ExternalFileIdentity? = nil
    ) throws -> Data {
        guard url.isFileURL, maximumBytes >= 0 else {
            throw NotchShotError.exportFailed("The source file is unsafe")
        }
        let descriptor = Darwin.open(
            url.standardizedFileURL.path,
            // Type validation must not wait for a writer on an untrusted FIFO.
            // O_NONBLOCK has no effect on reads from the regular files allowed
            // below, and retains descriptor-based validation against path swaps.
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            throw NotchShotError.exportFailed("The source file is no longer safely readable")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_size >= 0,
              information.st_size <= maximumBytes else {
            throw NotchShotError.exportFailed("The source file is unsafe or too large")
        }
        if let expectedIdentity, identity(from: information, descriptor: descriptor) != expectedIdentity {
            throw NotchShotError.exportFailed("The source file changed after it was selected")
        }

        var data = Data()
        data.reserveCapacity(Int(min(information.st_size, 1_048_576)))
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            guard Int64(data.count) <= maximumBytes - Int64(chunk.count) else {
                throw NotchShotError.exportFailed("The source file grew beyond the safe read limit")
            }
            data.append(chunk)
        }
        return data
    }

    private static func identity(from information: stat, descriptor: Int32) -> ExternalFileIdentity {
        var volume = statfs()
        let hasVolume = fstatfs(descriptor, &volume) == 0
        return identity(from: information, volume: hasVolume ? volume : nil)
    }

    private static func identity(from information: stat, volume: statfs?) -> ExternalFileIdentity {
        ExternalFileIdentity(
            device: UInt64(information.st_dev),
            inode: UInt64(information.st_ino),
            size: information.st_size,
            modifiedSeconds: Int64(information.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(information.st_mtimespec.tv_nsec),
            volume: volume.flatMap { volumeUUIDs.uuid(device: information.st_dev, mount: $0) }
        )
    }

    private static let volumeUUIDs = VolumeUUIDCache()
}

/// Volume UUIDs by mount. A lookup costs about 20 µs and History checks
/// hundreds of files in a row, so answers are kept for a few seconds; the
/// short life bounds how long a volume remounted at the same place with the
/// same device number could be mistaken for the one before it.
private final class VolumeUUIDCache: @unchecked Sendable {
    private struct Entry {
        var uuid: UUID?
        var expires: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func uuid(device: dev_t, mount volume: statfs) -> UUID? {
        let mountPoint = withUnsafeBytes(of: volume.f_mntonname) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        let key = "\(device) \(mountPoint)"
        let now = Date()
        lock.lock()
        if let entry = entries[key], entry.expires > now {
            lock.unlock()
            return entry.uuid
        }
        lock.unlock()

        let uuid = (try? URL(fileURLWithPath: mountPoint, isDirectory: true)
            .resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
            .flatMap(UUID.init(uuidString:))
        lock.lock()
        if entries.count > 64 { entries.removeAll() }
        entries[key] = Entry(uuid: uuid, expires: now.addingTimeInterval(5))
        lock.unlock()
        return uuid
    }
}
