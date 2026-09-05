import AppKit
import Foundation
import UniformTypeIdentifiers

/// Rename, move, and compress for things sitting in the shelf.
///
/// The shelf already holds real files, so the actions people expect from Finder
/// are the ones missing here — and every one of them changes a path the rest of
/// the app is holding. That is why these are pure functions returning the new
/// location rather than methods that mutate state: the caller is responsible for
/// telling History and the shelf where the file went, and a function that
/// cannot forget to is easier to reason about than one that must remember.
///
/// Every path goes through the same validation `SafeAssetFile` applies
/// elsewhere: regular files only, no symlinks, and an external reference must
/// still be the exact inode that was approved when it was dropped.
public enum ShelfFileOperations {

    public enum OperationError: LocalizedError, Equatable {
        case emptyName
        case illegalName
        case nameTooLong
        case sourceUnavailable
        case destinationExists(String)
        case destinationUnwritable(String)
        case nothingToCompress

        public var errorDescription: String? {
            switch self {
            case .emptyName: "Give the file a name"
            case .illegalName: "That name cannot be used for a file"
            case .nameTooLong: "That name is too long for the file system"
            case .sourceUnavailable: "That file changed or is no longer safely readable"
            case .destinationExists(let name): "\(name) already exists in that folder"
            case .destinationUnwritable(let path): "NotchShot could not write to \(path)"
            case .nothingToCompress: "There is nothing to compress"
            }
        }
    }

    /// Longest single path component APFS and HFS+ both accept, in bytes.
    static let maximumNameBytes = 255

    /// Cleans a user-typed name to something the file system will accept,
    /// or returns nil when nothing usable is left.
    ///
    /// Deliberately conservative rather than clever. `/` is the path separator
    /// and `:` is what Finder still displays as one, so both have to go; a
    /// leading dot would hide the file the user just named, which is a
    /// surprise rather than a choice. Everything else the user typed is kept —
    /// including spaces and Unicode, which are perfectly legal.
    public static func sanitizedName(_ raw: String) -> String? {
        var name = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        name = name.components(separatedBy: .controlCharacters).joined()
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Validates a proposed name and returns the filename to write.
    ///
    /// The extension is preserved from the original unless the user typed one,
    /// because a screenshot silently renamed from `.png` to nothing stops
    /// opening when double-clicked.
    public static func resolvedFilename(
        for raw: String,
        replacing currentURL: URL
    ) throws -> String {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OperationError.emptyName
        }
        guard let cleaned = sanitizedName(raw) else { throw OperationError.illegalName }

        let currentExtension = currentURL.pathExtension
        let typedExtension = (cleaned as NSString).pathExtension
        let filename: String
        if currentExtension.isEmpty || !typedExtension.isEmpty {
            // A typed extension is deliberate. Preserve the current extension
            // only when the user supplied a bare basename.
            filename = cleaned
        } else {
            filename = "\(cleaned).\(currentExtension)"
        }
        guard filename.utf8.count <= maximumNameBytes else { throw OperationError.nameTooLong }
        return filename
    }

    // MARK: Rename

    /// Renames in place and returns the new URL.
    @discardableResult
    public static func rename(_ asset: CaptureAsset, to raw: String) throws -> URL {
        guard SafeAssetFile.isCurrentAndSafe(asset) else { throw OperationError.sourceUnavailable }
        let filename = try resolvedFilename(for: raw, replacing: asset.url)
        let directory = asset.url.deletingLastPathComponent()
        let destination = directory.appendingPathComponent(filename)

        // Renaming a file to the name it already has is a no-op, not a clash.
        guard destination.standardizedFileURL != asset.url.standardizedFileURL else {
            return asset.url
        }
        // On a case-insensitive volume — the macOS default — `shot.png` and
        // `Shot.png` are the same path, so a plain existence check reports a
        // clash with the very file being renamed and refuses a rename Finder
        // performs happily. Only a *different* file is a real collision.
        if FileManager.default.fileExists(atPath: destination.path),
           !isSameFile(destination, asset.url) {
            throw OperationError.destinationExists(filename)
        }
        do {
            try FileManager.default.moveItem(at: asset.url, to: destination)
        } catch {
            throw OperationError.destinationUnwritable(destination.path)
        }
        return destination
    }

    /// Identity by volume and inode, which is what "the same file" means on a
    /// case-insensitive volume where two spellings share one entry.
    private static func isSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        var left = stat()
        var right = stat()
        guard lstat(lhs.path, &left) == 0, lstat(rhs.path, &right) == 0 else { return false }
        return left.st_dev == right.st_dev && left.st_ino == right.st_ino
    }

    // MARK: Move

    /// Moves into `folder`, falling back to a copy across volumes, and returns
    /// the new URL.
    @discardableResult
    public static func move(_ asset: CaptureAsset, toFolder folder: URL) throws -> URL {
        guard SafeAssetFile.isCurrentAndSafe(asset) else { throw OperationError.sourceUnavailable }
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw OperationError.destinationUnwritable(folder.path)
        }

        let filename = asset.url.lastPathComponent
        let destination = folder.appendingPathComponent(filename)
        guard destination.standardizedFileURL != asset.url.standardizedFileURL else {
            return asset.url
        }
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw OperationError.destinationExists(filename)
        }
        do {
            try fileManager.moveItem(at: asset.url, to: destination)
        } catch {
            // A move across volumes is a copy plus an unlink, and Foundation
            // reports the whole thing as one failure. Retry explicitly so the
            // common "drag it to an external disk" case works.
            do {
                try fileManager.copyItem(at: asset.url, to: destination)
                do {
                    try fileManager.removeItem(at: asset.url)
                } catch {
                    // A reported move must not quietly leave two copies. Roll
                    // the destination back when the source cannot be unlinked.
                    try? fileManager.removeItem(at: destination)
                    throw error
                }
            } catch {
                throw OperationError.destinationUnwritable(destination.path)
            }
        }
        return destination
    }

    // MARK: Compress

    /// Suggested archive name for a set of assets: the file's own name for one,
    /// a neutral collection name for several.
    public static func suggestedArchiveName(for assets: [CaptureAsset]) -> String {
        guard let first = assets.first else { return "Archive" }
        if assets.count == 1 {
            return first.url.deletingPathExtension().lastPathComponent
        }
        return "NotchShot Files"
    }

    /// Zips `assets` to `destination` and returns it.
    ///
    /// Uses `NSFileCoordinator`'s `.forUploading` reading intent, which is the
    /// same machinery Finder's "Compress" uses — so the archive opens with a
    /// double-click and carries no NotchShot-specific structure. Several files
    /// are staged into one directory first, because that intent archives a
    /// single item.
    @discardableResult
    public static func compress(_ assets: [CaptureAsset], to destination: URL) throws -> URL {
        guard !assets.isEmpty else { throw OperationError.nothingToCompress }
        for asset in assets where !SafeAssetFile.isCurrentAndSafe(asset) {
            throw OperationError.sourceUnavailable
        }
        guard !assets.contains(where: {
            $0.url.standardizedFileURL == destination.standardizedFileURL
        }) else {
            throw OperationError.destinationExists(destination.lastPathComponent)
        }
        let fileManager = FileManager.default

        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("notchshot-zip-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        // `.forUploading` zips directories only. A regular-file snapshot is
        // still the original bytes, even if the destination is named `.zip`.
        let source = staging.appendingPathComponent(
            suggestedArchiveName(for: assets), isDirectory: true
        )
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        var used = Set<String>()
        for asset in assets {
            // Two captures can legitimately share a filename once they come
            // from different folders; the archive has to keep both.
            let name = uniqueName(asset.url.lastPathComponent, in: &used)
            try SafeAssetFile.copy(
                asset,
                to: source.appendingPathComponent(name),
                mode: SafeAssetFile.userVisibleMode
            )
        }

        var coordinationError: NSError?
        var thrown: Error?
        NSFileCoordinator().coordinate(
            readingItemAt: source,
            options: [.forUploading],
            error: &coordinationError
        ) { archive in
            let stagedDestination = destination.deletingLastPathComponent()
                .appendingPathComponent(".notchshot-archive-\(UUID().uuidString)")
            defer { try? fileManager.removeItem(at: stagedDestination) }
            do {
                try fileManager.copyItem(at: archive, to: stagedDestination)
                if fileManager.fileExists(atPath: destination.path) {
                    _ = try fileManager.replaceItemAt(destination, withItemAt: stagedDestination)
                } else {
                    try fileManager.moveItem(at: stagedDestination, to: destination)
                }
            } catch {
                thrown = error
            }
        }
        if let thrown { throw thrown }
        if coordinationError != nil {
            throw OperationError.destinationUnwritable(destination.path)
        }
        return destination
    }

    static func uniqueName(_ name: String, in used: inout Set<String>) -> String {
        guard used.contains(name) else {
            used.insert(name)
            return name
        }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            if !used.contains(candidate) {
                used.insert(candidate)
                return candidate
            }
            counter += 1
        }
    }
}
