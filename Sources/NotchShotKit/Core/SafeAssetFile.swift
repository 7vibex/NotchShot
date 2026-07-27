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
        guard url.isFileURL else { return nil }
        var information = stat()
        guard lstat(url.standardizedFileURL.path, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_size >= 0,
              information.st_size <= maximumBytes else { return nil }
        return ExternalFileIdentity(
            device: UInt64(information.st_dev),
            inode: UInt64(information.st_ino),
            size: information.st_size,
            modifiedSeconds: Int64(information.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(information.st_mtimespec.tv_nsec)
        )
    }

    static func isCurrentAndSafe(_ asset: CaptureAsset) -> Bool {
        let maximum = asset.ownership == .externalReference
            ? maximumExternalBytes : maximumOwnedBytes
        guard let current = identity(at: asset.url, maximumBytes: maximum) else { return false }
        guard asset.ownership == .externalReference else { return true }
        return asset.externalFileIdentity == current
    }

    /// Copies from an `O_NOFOLLOW` descriptor into a new destination. The
    /// descriptor pins the validated inode even if its path is replaced during
    /// the operation; the caller supplies a unique staging destination.
    static func copy(_ asset: CaptureAsset, to destination: URL) throws {
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
        let openedIdentity = ExternalFileIdentity(
            device: UInt64(information.st_dev),
            inode: UInt64(information.st_ino),
            size: information.st_size,
            modifiedSeconds: Int64(information.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(information.st_mtimespec.tv_nsec)
        )
        if asset.ownership == .externalReference,
           asset.externalFileIdentity != openedIdentity {
            throw NotchShotError.exportFailed(
                "That Finder file changed after it was added. Remove it and add the current file again."
            )
        }

        let destinationDescriptor = Darwin.open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
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
}
