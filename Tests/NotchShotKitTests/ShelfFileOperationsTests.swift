import Foundation
import Testing

@testable import NotchShotKit

/// Rename, move and compress each change a path that History, the shelf, the
/// stack and "restore last" are all holding. The file-system half is pinned
/// here; `relocate` in the coordinator is what keeps the four in step.
@Suite("Shelf file operations")
struct ShelfFileOperationsTests {

    private func makeDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("notchshot-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func makeFile(
        _ name: String,
        in directory: URL,
        bytes: Int = 64
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    private func asset(at url: URL) -> CaptureAsset {
        CaptureAsset(
            url: url,
            kind: .screenshot,
            pixelSize: CGSize(width: 10, height: 10),
            ownership: .userDocument
        )
    }

    private func extractedFiles(from archive: URL) throws -> [String: Data] {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "The output must be a ZIP that macOS can extract")
        let enumerator = try #require(FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey]
        ))
        var files: [String: Data] = [:]
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                files[url.lastPathComponent] = try Data(contentsOf: url)
            }
        }
        return files
    }

    // MARK: Names

    @Test("A typed name keeps the original extension")
    func nameKeepsExtension() throws {
        let current = URL(fileURLWithPath: "/tmp/Shot.png")
        #expect(try ShelfFileOperations.resolvedFilename(for: "Invoice", replacing: current) == "Invoice.png")
        // Typing the same extension must not double it.
        #expect(try ShelfFileOperations.resolvedFilename(for: "Invoice.png", replacing: current) == "Invoice.png")
        // A deliberately different one is the user's call.
        #expect(try ShelfFileOperations.resolvedFilename(for: "Invoice.jpg", replacing: current) == "Invoice.jpg")
    }

    @Test("Separators and leading dots are removed rather than written")
    func nameIsSanitized() {
        #expect(ShelfFileOperations.sanitizedName("a/b:c") == "a-b-c")
        // A leading dot would hide the file the user just named.
        #expect(ShelfFileOperations.sanitizedName(".hidden") == "hidden")
        #expect(ShelfFileOperations.sanitizedName("  spaced  ") == "spaced")
        #expect(ShelfFileOperations.sanitizedName("   ") == nil)
        // Substitution is uniform: a name made only of separators becomes a
        // name made only of dashes, rather than a special case that is hard to
        // explain next to "a/b" being accepted as "a-b".
        #expect(ShelfFileOperations.sanitizedName("///") == "---")
        // Nothing usable left, though, is refused.
        #expect(ShelfFileOperations.sanitizedName("...") == nil)
        #expect(ShelfFileOperations.sanitizedName("\u{0001}\u{0002}") == nil)
        // Unicode and spaces are perfectly legal and must survive.
        #expect(ShelfFileOperations.sanitizedName("Café notes") == "Café notes")
    }

    @Test("An empty or over-long name is refused")
    func badNamesThrow() {
        let current = URL(fileURLWithPath: "/tmp/Shot.png")
        #expect(throws: ShelfFileOperations.OperationError.emptyName) {
            try ShelfFileOperations.resolvedFilename(for: "  ", replacing: current)
        }
        #expect(throws: ShelfFileOperations.OperationError.illegalName) {
            try ShelfFileOperations.resolvedFilename(for: "...", replacing: current)
        }
        #expect(throws: ShelfFileOperations.OperationError.nameTooLong) {
            try ShelfFileOperations.resolvedFilename(
                for: String(repeating: "n", count: 300),
                replacing: current
            )
        }
    }

    // MARK: Rename

    @Test("Rename moves the file and reports the new location")
    func renameMovesFile() throws {
        let directory = try makeDirectory()
        let original = try makeFile("Shot.png", in: directory)

        let renamed = try ShelfFileOperations.rename(asset(at: original), to: "Bug report")

        #expect(renamed.lastPathComponent == "Bug report.png")
        #expect(FileManager.default.fileExists(atPath: renamed.path))
        #expect(!FileManager.default.fileExists(atPath: original.path))
    }

    @Test("Renaming to the existing name is accepted, not treated as a clash")
    func renameToSameNameSucceeds() throws {
        let directory = try makeDirectory()
        let original = try makeFile("Shot.png", in: directory)

        let renamed = try ShelfFileOperations.rename(asset(at: original), to: "Shot")

        #expect(renamed.standardizedFileURL == original.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: original.path))
    }

    @Test("Rename refuses to overwrite a different file")
    func renameRefusesCollision() throws {
        let directory = try makeDirectory()
        let original = try makeFile("Shot.png", in: directory)
        try makeFile("Taken.png", in: directory)

        #expect(throws: ShelfFileOperations.OperationError.destinationExists("Taken.png")) {
            try ShelfFileOperations.rename(asset(at: original), to: "Taken")
        }
        // The original is untouched by the refusal.
        #expect(FileManager.default.fileExists(atPath: original.path))
    }

    @Test("A file that vanished cannot be renamed")
    func renameRefusesMissingSource() throws {
        let directory = try makeDirectory()
        let missing = directory.appendingPathComponent("Gone.png")

        #expect(throws: ShelfFileOperations.OperationError.sourceUnavailable) {
            try ShelfFileOperations.rename(asset(at: missing), to: "Anything")
        }
    }

    // MARK: Move

    @Test("Move relocates the file into the chosen folder")
    func moveRelocatesFile() throws {
        let source = try makeDirectory()
        let destination = try makeDirectory()
        let original = try makeFile("Shot.png", in: source)

        let moved = try ShelfFileOperations.move(asset(at: original), toFolder: destination)

        #expect(moved.deletingLastPathComponent().standardizedFileURL == destination.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: moved.path))
        #expect(!FileManager.default.fileExists(atPath: original.path))
    }

    @Test("Move refuses a folder that already holds that name")
    func moveRefusesCollision() throws {
        let source = try makeDirectory()
        let destination = try makeDirectory()
        let original = try makeFile("Shot.png", in: source)
        try makeFile("Shot.png", in: destination)

        #expect(throws: ShelfFileOperations.OperationError.destinationExists("Shot.png")) {
            try ShelfFileOperations.move(asset(at: original), toFolder: destination)
        }
        #expect(FileManager.default.fileExists(atPath: original.path))
    }

    @Test("Move refuses a destination that is not a directory")
    func moveRefusesNonDirectory() throws {
        let directory = try makeDirectory()
        let original = try makeFile("Shot.png", in: directory)
        let notAFolder = try makeFile("Decoy.png", in: directory)

        #expect(throws: (any Error).self) {
            try ShelfFileOperations.move(asset(at: original), toFolder: notAFolder)
        }
    }

    // MARK: Compress

    @Test("One file compresses to a readable archive")
    func compressesSingleFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try makeFile("Shot.png", in: directory, bytes: 4_096)
        let archive = directory.appendingPathComponent("Shot.zip")

        try ShelfFileOperations.compress([asset(at: original)], to: archive)

        #expect(FileManager.default.fileExists(atPath: archive.path))
        let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        #expect(size > 0)
        // The source is an input, not something the archive consumes.
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(try extractedFiles(from: archive) == ["Shot.png": Data(contentsOf: original)])
    }

    @Test("Several files compress into one archive")
    func compressesSeveralFiles() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let assets = try (0 ..< 3).map { index in
            asset(at: try makeFile("Shot \(index).png", in: directory, bytes: 2_048))
        }
        let archive = directory.appendingPathComponent("Bundle.zip")

        try ShelfFileOperations.compress(assets, to: archive)

        #expect(FileManager.default.fileExists(atPath: archive.path))
        let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        #expect(size > 0)
        let extracted = try extractedFiles(from: archive)
        #expect(extracted.count == assets.count)
        for asset in assets {
            #expect(try extracted[asset.url.lastPathComponent] == Data(contentsOf: asset.url))
        }
    }

    @Test("Compressing over an existing archive replaces it")
    func compressReplacesExistingArchive() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try makeFile("Shot.png", in: directory, bytes: 4_096)
        let archive = try makeFile("Shot.zip", in: directory, bytes: 8)

        try ShelfFileOperations.compress([asset(at: original)], to: archive)

        let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        #expect(size > 8)
        #expect(try extractedFiles(from: archive) == ["Shot.png": Data(contentsOf: original)])
    }

    @Test("An archive cannot replace the source it is compressing")
    func compressRefusesItsOwnSourcePath() throws {
        let directory = try makeDirectory()
        let original = try makeFile("Archive.zip", in: directory, bytes: 4_096)

        #expect(throws: ShelfFileOperations.OperationError.destinationExists("Archive.zip")) {
            try ShelfFileOperations.compress([asset(at: original)], to: original)
        }
        #expect(FileManager.default.fileExists(atPath: original.path))
        let size = try original.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        #expect(size == 4_096)
    }

    @Test("Compressing nothing is refused")
    func compressRefusesEmptySelection() throws {
        let directory = try makeDirectory()
        #expect(throws: ShelfFileOperations.OperationError.nothingToCompress) {
            try ShelfFileOperations.compress([], to: directory.appendingPathComponent("x.zip"))
        }
    }

    /// Two captures from different folders can legitimately share a filename,
    /// and an archive that silently kept one of them would lose user data.
    @Test("Duplicate filenames are disambiguated inside the archive")
    func duplicateNamesAreDisambiguated() {
        var used = Set<String>()
        #expect(ShelfFileOperations.uniqueName("Shot.png", in: &used) == "Shot.png")
        #expect(ShelfFileOperations.uniqueName("Shot.png", in: &used) == "Shot 2.png")
        #expect(ShelfFileOperations.uniqueName("Shot.png", in: &used) == "Shot 3.png")
        #expect(ShelfFileOperations.uniqueName("README", in: &used) == "README")
        #expect(ShelfFileOperations.uniqueName("README", in: &used) == "README 2")
    }

    // MARK: Availability

    /// A file dragged in from Finder is the user's document sitting where they
    /// put it; renaming it from a preview shelf would edit their folder as a
    /// side effect.
    @Test("Rename and Move are offered only for files NotchShot owns")
    func renameAndMoveSkipExternalReferences() {
        let external = CaptureAsset(
            url: URL(fileURLWithPath: "/Users/test/Desktop/Theirs.png"),
            kind: .screenshot,
            pixelSize: CGSize(width: 10, height: 10),
            ownership: .externalReference
        )
        let owned = CaptureAsset(
            url: URL(fileURLWithPath: "/Users/test/Desktop/Ours.png"),
            kind: .screenshot,
            pixelSize: CGSize(width: 10, height: 10),
            ownership: .userDocument
        )

        #expect(!ShareAction.rename.isAvailable(for: external))
        #expect(!ShareAction.moveTo.isAvailable(for: external))
        #expect(ShareAction.rename.isAvailable(for: owned))
        #expect(ShareAction.moveTo.isAvailable(for: owned))
        // Compressing and previewing someone else's file changes nothing about it.
        #expect(ShareAction.compress.isAvailable(for: external))
        #expect(ShareAction.quickLook.isAvailable(for: external))
        #expect(ShareAction.airDrop.isAvailable(for: external))
    }
}
