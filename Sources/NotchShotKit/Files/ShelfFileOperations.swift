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
        case sidecarUnavailable(String)
        case sidecarUnwritable(String)
        case nothingToCompress

        public var errorDescription: String? {
            switch self {
            case .emptyName: "Give the file a name"
            case .illegalName: "That name cannot be used for a file"
            case .nameTooLong: "That name is too long for the file system"
            case .sourceUnavailable: "That file changed or is no longer safely readable"
            case .destinationExists(let name): "\(name) already exists in that folder"
            case .destinationUnwritable(let path): "NotchShot could not write to \(path)"
            case .sidecarUnavailable(let name):
                "\(name) could not be verified as this recording's subtitle, so nothing was moved"
            case .sidecarUnwritable(let name):
                "The recording was moved back because its subtitle \(name) could not be moved"
            case .nothingToCompress: "There is nothing to compress"
            }
        }
    }

    /// The result of a rename or move.
    ///
    /// `url` is the primary file's new location. `captionURL` is present only
    /// when a caption that NotchShot generated for this exact recording was
    /// verified and moved with it; a same-stem `.srt` that merely existed at
    /// the destination is never adopted, and never touched.
    public struct RelocatedFile: Sendable, Equatable {
        public var url: URL
        public var captionURL: URL?
        public var captionIdentity: ExternalFileIdentity?

        public init(
            url: URL,
            captionURL: URL? = nil,
            captionIdentity: ExternalFileIdentity? = nil
        ) {
            self.url = url
            self.captionURL = captionURL
            self.captionIdentity = captionIdentity
        }

        /// Forwarders for call sites that only ever read the primary location.
        public var path: String { url.path }
        public var lastPathComponent: String { url.lastPathComponent }
        public var standardizedFileURL: URL { url.standardizedFileURL }
        public func deletingLastPathComponent() -> URL { url.deletingLastPathComponent() }
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

    /// Renames in place and returns the new location, moving the exact verified
    /// caption with the recording when it owns one.
    @discardableResult
    public static func rename(_ asset: CaptureAsset, to raw: String) throws -> RelocatedFile {
        guard SafeAssetFile.isCurrentAndSafe(asset) else { throw OperationError.sourceUnavailable }
        let filename = try resolvedFilename(for: raw, replacing: asset.url)
        let directory = asset.url.deletingLastPathComponent()
        let destination = directory.appendingPathComponent(filename)
        return try relocate(asset, to: destination)
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
    /// the new location, moving the exact verified caption with the recording
    /// when it owns one.
    @discardableResult
    public static func move(_ asset: CaptureAsset, toFolder folder: URL) throws -> RelocatedFile {
        guard SafeAssetFile.isCurrentAndSafe(asset) else { throw OperationError.sourceUnavailable }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw OperationError.destinationUnwritable(folder.path)
        }
        return try relocate(asset, to: folder.appendingPathComponent(asset.url.lastPathComponent))
    }

    // MARK: Relocation

    /// Moves the primary file and, when it owns one, the exact caption that was
    /// generated for it.
    ///
    /// The caption plan is validated completely before the first file moves:
    /// an unverifiable caption (a legacy row with no identity, or a sidecar
    /// whose file no longer matches its recorded identity) refuses the whole
    /// operation. If the primary moved but the caption could not, the primary
    /// is moved back, so a reported success always means both are in place.
    private static func relocate(_ asset: CaptureAsset, to destination: URL) throws -> RelocatedFile {
        let fileManager = FileManager.default
        // Renaming a file to the name it already has, or moving it to the
        // folder it already lives in, is a no-op rather than a clash. The
        // existing caption ownership must survive it.
        if destination.standardizedFileURL == asset.url.standardizedFileURL {
            return existingRelocation(for: asset)
        }
        // On a case-insensitive volume — the macOS default — `shot.png` and
        // `Shot.png` are the same path, so a plain existence check reports a
        // clash with the very file being renamed and refuses a rename Finder
        // performs happily. Only a *different* file is a real collision.
        if fileManager.fileExists(atPath: destination.path),
           !isSameFile(destination, asset.url) {
            throw OperationError.destinationExists(destination.lastPathComponent)
        }

        let captionPlan = try captionRelocationPlan(for: asset, to: destination)

        do {
            try moveFile(from: asset.url, to: destination)
        } catch {
            throw OperationError.destinationUnwritable(destination.path)
        }
        guard let captionPlan else {
            return RelocatedFile(url: destination)
        }
        do {
            try moveFile(from: captionPlan.source, to: captionPlan.destination)
        } catch {
            // The recording already moved. Put it back rather than leave the
            // file system and the reported location disagreeing.
            try? moveFile(from: destination, to: asset.url)
            throw OperationError.sidecarUnwritable(captionPlan.destination.lastPathComponent)
        }
        let identity = SafeAssetFile.identity(
            at: captionPlan.destination,
            maximumBytes: SafeAssetFile.maximumOwnedBytes
        )
        return RelocatedFile(
            url: destination,
            captionURL: captionPlan.destination,
            captionIdentity: identity
        )
    }

    /// A relocation that ends where it started, so the verified caption keeps
    /// its exact ownership instead of being cleared as if it were absent.
    private static func existingRelocation(for asset: CaptureAsset) -> RelocatedFile {
        guard let captionURL = asset.captionURL,
              let validated = HistoryRepository.validatedCaptionURL(
                  path: captionURL.path,
                  for: asset.url
              ),
              let identity = asset.captionFileIdentity,
              SafeAssetFile.identity(
                  at: validated,
                  maximumBytes: SafeAssetFile.maximumOwnedBytes
              ) == identity else {
            return RelocatedFile(url: asset.url)
        }
        return RelocatedFile(
            url: asset.url,
            captionURL: validated,
            captionIdentity: identity
        )
    }

    private struct CaptionPlan {
        var source: URL
        var destination: URL
    }

    /// The caption move, or nil when the recorded caption is already gone.
    /// Every rejection happens before the primary file is touched.
    private static func captionRelocationPlan(
        for asset: CaptureAsset,
        to destination: URL
    ) throws -> CaptionPlan? {
        guard let captionURL = asset.captionURL else { return nil }
        guard let source = HistoryRepository.validatedCaptionURL(
            path: captionURL.path,
            for: asset.url
        ) else {
            throw OperationError.sidecarUnavailable(captionURL.lastPathComponent)
        }
        guard FileManager.default.fileExists(atPath: source.path) else {
            // A caption recorded earlier is already gone. There is nothing to
            // move, and nothing at the destination is ours to claim.
            return nil
        }
        guard let identity = asset.captionFileIdentity,
              SafeAssetFile.identity(
                  at: source,
                  maximumBytes: SafeAssetFile.maximumOwnedBytes
              ) == identity else {
            // Legacy rows and replaced sidecars cannot be verified. Refusing
            // keeps an unrelated same-stem file from being renamed under the
            // recording's name.
            throw OperationError.sidecarUnavailable(source.lastPathComponent)
        }
        let captionDestination = destination
            .deletingLastPathComponent()
            .appendingPathComponent(destination.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("srt")
        guard captionDestination.standardizedFileURL != source.standardizedFileURL else {
            return CaptionPlan(source: source, destination: captionDestination)
        }
        if FileManager.default.fileExists(atPath: captionDestination.path),
           !isSameFile(captionDestination, source) {
            throw OperationError.destinationExists(captionDestination.lastPathComponent)
        }
        return CaptionPlan(source: source, destination: captionDestination)
    }

    /// Moves when possible and copies across volumes. Foundation reports a
    /// cross-volume move as one failure, so the fallback is explicit here for
    /// the same reason it is in `move`.
    private static func moveFile(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        do {
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            do {
                try fileManager.copyItem(at: source, to: destination)
                do {
                    try fileManager.removeItem(at: source)
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
    }

    /// Best-effort undo of a completed relocation after a later metadata step
    /// failed. The caption goes back first so a recording is never left
    /// separated from the subtitle it owns.
    static func rollback(_ relocation: RelocatedFile, to asset: CaptureAsset) {
        let fileManager = FileManager.default
        if let captionURL = relocation.captionURL,
           let expectedIdentity = relocation.captionIdentity,
           let originalCaption = asset.captionURL,
           fileManager.fileExists(atPath: captionURL.path),
           SafeAssetFile.identity(
               at: captionURL,
               maximumBytes: SafeAssetFile.maximumOwnedBytes
           ) == expectedIdentity {
            try? moveFile(from: captionURL, to: originalCaption)
        }
        if fileManager.fileExists(atPath: relocation.url.path) {
            try? moveFile(from: relocation.url, to: asset.url)
        }
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
