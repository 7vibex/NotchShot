import Darwin
import Foundation

/// Stable identity captured when a Finder file enters the shelf. Requiring the
/// same device/inode/size/mtime later prevents a path swap from turning Save As
/// or Bug Report into a copier for unrelated local content.
public struct ExternalFileIdentity: Codable, Sendable, Equatable {
    public var device: UInt64
    public var inode: UInt64
    public var size: Int64
    public var modifiedSeconds: Int64
    public var modifiedNanoseconds: Int64
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
        guard lstat(url.standardizedFileURL.path, &information) == 0 else { return nil }
        let type = information.st_mode & S_IFMT
        guard type == S_IFREG || (allowsDirectory && type == S_IFDIR),
              information.st_size >= 0,
              type == S_IFDIR || information.st_size <= maximumBytes else { return nil }
        return identity(from: information)
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
        guard destination.isFileURL,
              !FileManager.default.fileExists(atPath: destination.path) else {
            throw NotchShotError.destinationUnwritable(destination.path)
        }
        let maximum = asset.ownership == .externalReference
            ? maximumExternalBytes : maximumOwnedBytes
        let sourceDescriptor = Darwin.open(
            asset.url.standardizedFileURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard sourceDescriptor >= 0 else {
            throw NotchShotError.exportFailed("The source file is no longer safely readable")
        }
        let source = FileHandle(fileDescriptor: sourceDescriptor, closeOnDealloc: true)

        var information = stat()
        guard fstat(sourceDescriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_size >= 0,
              information.st_size <= maximum else {
            throw NotchShotError.exportFailed("The source file is unsafe or too large")
        }
        let openedIdentity = identity(from: information)
        if asset.ownership == .externalReference,
           asset.externalFileIdentity != openedIdentity {
            throw NotchShotError.exportFailed(
                "That Finder file changed after it was added. Remove it and add the current file again."
            )
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
                guard total <= maximum else {
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
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
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
        if let expectedIdentity, identity(from: information) != expectedIdentity {
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

    private static func identity(from information: stat) -> ExternalFileIdentity {
        ExternalFileIdentity(
            device: UInt64(information.st_dev),
            inode: UInt64(information.st_ino),
            size: information.st_size,
            modifiedSeconds: Int64(information.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(information.st_mtimespec.tv_nsec)
        )
    }
}
