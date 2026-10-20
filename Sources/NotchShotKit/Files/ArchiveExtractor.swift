import Darwin
import Foundation

/// Unpacks archives dropped on the notch, the way Archive Utility does: next
/// to the archive, into one item when the archive holds one item, otherwise
/// into a folder named after it.
///
/// Everything runs through the system's own tools — `ditto` for ZIP, which
/// keeps resource forks and extended attributes, `bsdtar` for tar, 7-Zip and
/// RAR, and `gunzip`/`bunzip2` for single compressed files. Each extraction
/// lands in a hidden staging folder beside the archive first, so a failed or
/// half-finished run never leaves partial files where the user looks.
enum ArchiveExtractor {
    enum Format: Equatable {
        case zip
        case tarFamily
        case gzip
        case bzip2
    }

    struct Result: Equatable {
        /// What appeared next to the archive.
        var outputURL: URL
        var itemCount: Int
    }

    enum Failure: LocalizedError, Equatable {
        case unsupported(String)
        case passwordProtected(String)
        case failed(String, String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let name): "\(name) isn't an archive NotchShot can open"
            case .passwordProtected(let name): "\(name) is password-protected. Open it in Archive Utility instead."
            case .failed(let name, let reason): "Couldn't extract \(name)" + (reason.isEmpty ? "" : ": \(reason)")
            }
        }
    }

    private static let tarExtensions: Set<String> = ["tar", "tgz", "tbz", "tbz2", "txz", "tlz", "7z", "rar", "xar", "cpio", "lha", "lzh", "cab"]
    private static let compressedTarSuffixes = [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.lzma", ".tar.zst"]

    static func format(of url: URL) -> Format? {
        let name = url.lastPathComponent.lowercased()
        if compressedTarSuffixes.contains(where: { name.hasSuffix($0) }) { return .tarFamily }
        switch url.pathExtension.lowercased() {
        case "zip": return .zip
        case "gz": return .gzip
        case "bz2": return .bzip2
        case let ext where tarExtensions.contains(ext): return .tarFamily
        default: return nil
        }
    }

    static func isArchive(_ url: URL) -> Bool {
        guard format(of: url) != nil else { return false }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile ?? false
    }

    /// The name the archive's contents get: `Photos.tar.gz` → `Photos`.
    static func baseName(of url: URL) -> String {
        let name = url.lastPathComponent
        let lower = name.lowercased()
        if let suffix = compressedTarSuffixes.first(where: { lower.hasSuffix($0) }) {
            return String(name.dropLast(suffix.count))
        }
        let stem = url.deletingPathExtension().lastPathComponent
        return stem.isEmpty ? name : stem
    }

    /// Extracts beside the archive, or into Downloads when that folder is
    /// read-only (an archive on a disk image, say).
    static func extract(_ archive: URL, fileManager: FileManager = .default) throws -> Result {
        let displayName = archive.lastPathComponent
        guard let format = format(of: archive) else { throw Failure.unsupported(displayName) }
        var destination = archive.deletingLastPathComponent()
        if !fileManager.isWritableFile(atPath: destination.path),
           let downloads = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            destination = downloads
        }
        let staging = destination.appendingPathComponent(".notchshot-extract-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: staging) }

        switch format {
        case .zip:
            try run("/usr/bin/ditto", ["-x", "-k", archive.path, staging.path], name: displayName)
        case .tarFamily:
            // bsdtar refuses absolute paths and `..` members unless told
            // otherwise, so nothing can be written outside the staging folder.
            try run("/usr/bin/tar", ["-x", "-f", archive.path, "-C", staging.path], name: displayName)
        case .gzip, .bzip2:
            let output = staging.appendingPathComponent(baseName(of: archive))
            try run(
                format == .gzip ? "/usr/bin/gunzip" : "/usr/bin/bunzip2",
                ["-c", archive.path],
                name: displayName,
                stdout: output
            )
        }
        if format != .zip {
            try carryQuarantine(from: archive, into: staging, name: displayName, fileManager: fileManager)
        }

        let items = try fileManager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            .filter { !ignoredNames.contains($0.lastPathComponent) }
        guard !items.isEmpty else { throw Failure.failed(displayName, "the archive is empty") }
        let output: URL
        if items.count == 1 {
            output = uniqueURL(for: items[0].lastPathComponent, in: destination, fileManager: fileManager)
            try fileManager.moveItem(at: items[0], to: output)
        } else {
            output = uniqueURL(for: baseName(of: archive), in: destination, fileManager: fileManager)
            try fileManager.createDirectory(at: output, withIntermediateDirectories: false)
            for item in items {
                try fileManager.moveItem(at: item, to: output.appendingPathComponent(item.lastPathComponent))
            }
        }
        return Result(outputURL: output, itemCount: items.count)
    }

    /// Gatekeeper checks a downloaded app or script only while it carries its
    /// download's quarantine. `ditto` gives the archive's quarantine to every
    /// item it unpacks, as Archive Utility does; `bsdtar`, `gunzip` and
    /// `bunzip2` give none, and `bsdtar` even restores a member's own stored
    /// quarantine, which can claim the user already approved it. So every
    /// unpacked item gets the archive's value, replacing whatever it had, and
    /// an item that can't take it fails the extraction instead of arriving
    /// unchecked.
    private static func carryQuarantine(
        from archive: URL,
        into staging: URL,
        name: String,
        fileManager: FileManager
    ) throws {
        let attribute = "com.apple.quarantine"
        let length = getxattr(archive.path, attribute, nil, 0, 0, 0)
        guard length > 0 else { return }
        var value = [UInt8](repeating: 0, count: length)
        let failure = Failure.failed(name, "its files couldn't be marked as downloaded")
        guard getxattr(archive.path, attribute, &value, length, 0, 0) == length else { throw failure }

        // A read-only item refuses new attributes, and an unreadable folder
        // hides what's inside, so the owner's access is widened for the walk
        // and narrowed again once everything is marked.
        var restoredModes: [(path: String, mode: mode_t)] = []
        var pending = try fileManager.contentsOfDirectory(atPath: staging.path)
            .map { staging.appendingPathComponent($0).path }
        while let path = pending.popLast() {
            var information = stat()
            guard lstat(path, &information) == 0 else { throw failure }
            let type = information.st_mode & S_IFMT
            // A link runs nothing itself; what it points to inside the
            // archive is marked on its own.
            guard type != S_IFLNK else { continue }
            let mode = information.st_mode & 0o7777
            let needed = type == S_IFDIR ? S_IRWXU : S_IWUSR
            if mode & needed != needed {
                guard fchmodat(AT_FDCWD, path, mode | needed, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure }
                restoredModes.append((path, mode))
            }
            guard setxattr(path, attribute, value, length, 0, XATTR_NOFOLLOW) == 0 else { throw failure }
            if type == S_IFDIR {
                pending += try fileManager.contentsOfDirectory(atPath: path)
                    .map { (path as NSString).appendingPathComponent($0) }
            }
        }
        // Deepest first, so no folder closes before its contents are done.
        for item in restoredModes.reversed() {
            fchmodat(AT_FDCWD, item.path, item.mode, AT_SYMLINK_NOFOLLOW)
        }
    }

    /// Finder metadata a ZIP made on a Mac carries along.
    static let ignoredNames: Set<String> = ["__MACOSX", ".DS_Store"]

    /// `Name`, then `Name 2`, `Name 3`… — Finder's own pattern.
    static func uniqueURL(for name: String, in folder: URL, fileManager: FileManager = .default) -> URL {
        let candidate = folder.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        for index in 2 ... 999 {
            let numbered = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            let url = folder.appendingPathComponent(numbered)
            if !fileManager.fileExists(atPath: url.path) { return url }
        }
        return folder.appendingPathComponent("\(stem) \(UUID().uuidString.prefix(8))" + (ext.isEmpty ? "" : ".\(ext)"))
    }

    private static func run(_ tool: String, _ arguments: [String], name: String, stdout: URL? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        // No terminal: a tool that wants a password fails instead of waiting.
        process.standardInput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        var outputHandle: FileHandle?
        if let stdout {
            FileManager.default.createFile(atPath: stdout.path, contents: nil)
            outputHandle = try FileHandle(forWritingTo: stdout)
            process.standardOutput = outputHandle
        } else {
            process.standardOutput = FileHandle.nullDevice
        }
        try process.run()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try? outputHandle?.close()
        guard process.terminationStatus == 0 else {
            let text = String(decoding: message, as: UTF8.self)
            let lower = text.lowercased()
            if lower.contains("passphrase") || lower.contains("password") || lower.contains("encrypt") {
                throw Failure.passwordProtected(name)
            }
            let reason = text.split(separator: "\n").first.map {
                String($0).replacingOccurrences(of: "tar: ", with: "").replacingOccurrences(of: "ditto: ", with: "")
            } ?? ""
            throw Failure.failed(name, String(reason.prefix(120)))
        }
    }
}
