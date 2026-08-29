import Foundation
import Testing

@testable import NotchShotKit

/// `AppPaths.owns` gates every read, write and delete of a managed file, and it
/// grew a fast path that answers without resolving the whole pathname twice.
/// These tests pin the answer against a transcription of the implementation the
/// fast path replaced, across the path shapes that can actually differ:
/// symbolic links above the root, at the root, inside the tail, and pointing
/// back in from outside; plus tails that do not exist yet.
@Suite("Managed storage ownership")
struct SymlinkEscapeTests {

    /// The pre-optimisation implementation, kept verbatim as the oracle.
    private static func referenceOwns(_ url: URL, within supportRoot: URL) -> Bool {
        func resolved(_ url: URL) -> URL {
            let fileManager = FileManager.default
            var existingAncestor = url.standardizedFileURL
            var missingComponents: [String] = []
            while existingAncestor.path != "/" {
                let isSymlink = (try? existingAncestor.resourceValues(
                    forKeys: [.isSymbolicLinkKey]
                ).isSymbolicLink) == true
                if fileManager.fileExists(atPath: existingAncestor.path) || isSymlink {
                    break
                }
                missingComponents.append(existingAncestor.lastPathComponent)
                existingAncestor.deleteLastPathComponent()
            }
            var out = existingAncestor.resolvingSymlinksInPath().standardizedFileURL
            for component in missingComponents.reversed() {
                out.appendPathComponent(component)
            }
            return out.standardizedFileURL
        }

        let lexicalRoot = supportRoot.standardizedFileURL.path
        let resolvedRoot = resolved(supportRoot).path
        guard resolvedRoot == lexicalRoot else { return false }
        let candidate = resolved(url).path
        return candidate == resolvedRoot || candidate.hasPrefix(resolvedRoot + "/")
    }

    /// Builds a sandbox whose layout covers every case the fast path reasons
    /// about, and returns the root plus every candidate worth asking about.
    private static func makeFixture() throws -> (root: URL, outside: URL, candidates: [URL], cleanUp: () -> Void) {
        let fileManager = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("notchshot-owns-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("Support", isDirectory: true)
        let outside = base.appendingPathComponent("Outside", isDirectory: true)

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: outside.appendingPathComponent("secret.txt"))

        // A real subdirectory holding a real file.
        let real = root.appendingPathComponent("Thumbnails", isDirectory: true)
        try fileManager.createDirectory(at: real, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: real.appendingPathComponent("present.png"))

        // A directory symlink escaping the root.
        try fileManager.createSymbolicLink(
            at: root.appendingPathComponent("Escape", isDirectory: true),
            withDestinationURL: outside
        )
        // A file symlink escaping the root.
        try fileManager.createSymbolicLink(
            at: real.appendingPathComponent("escape.png"),
            withDestinationURL: outside.appendingPathComponent("secret.txt")
        )
        // A dangling symlink: exists to `lstat`, absent to `stat`.
        try fileManager.createSymbolicLink(
            at: real.appendingPathComponent("dangling.png"),
            withDestinationURL: outside.appendingPathComponent("missing.txt")
        )
        // A symlink from outside pointing back in — lexically out, really in.
        try fileManager.createSymbolicLink(
            at: outside.appendingPathComponent("back-in", isDirectory: true),
            withDestinationURL: real
        )

        let candidates: [URL] = [
            root,
            root.appendingPathComponent("safe.png"),
            root.appendingPathComponent("Thumbnails/present.png"),
            root.appendingPathComponent("Thumbnails/escape.png"),
            root.appendingPathComponent("Thumbnails/dangling.png"),
            root.appendingPathComponent("Thumbnails/missing.png"),
            root.appendingPathComponent("Missing/Deeper/leaf.png"),
            root.appendingPathComponent("Escape/secret.txt"),
            root.appendingPathComponent("Escape"),
            root.appendingPathComponent("Thumbnails/../safe.png"),
            root.appendingPathComponent("../Outside/secret.txt"),
            outside,
            outside.appendingPathComponent("secret.txt"),
            outside.appendingPathComponent("back-in/present.png"),
            URL(fileURLWithPath: "/etc/hosts"),
            URL(fileURLWithPath: "/tmp/notchshot-owns-probe.png"),
            URL(fileURLWithPath: "/"),
        ]

        return (root, outside, candidates, { try? fileManager.removeItem(at: base) })
    }

    @Test("Fast path agrees with full resolution on every path shape")
    func fastPathMatchesFullResolution() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.cleanUp() }

        for candidate in fixture.candidates {
            #expect(
                AppPaths.owns(candidate, within: fixture.root)
                    == Self.referenceOwns(candidate, within: fixture.root),
                "disagreement for \(candidate.path)"
            )
        }
    }

    @Test("Agreement holds when the root itself is reached through a symlink")
    func symlinkedRootMatchesFullResolution() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.cleanUp() }

        // A root spelled through a symbolic link never resolves to itself, so
        // every answer under it must be `false` — the case that would break if
        // the fast path skipped checking the root's own components.
        let linkedRoot = fixture.outside.appendingPathComponent("back-in", isDirectory: true)
        for candidate in fixture.candidates + [linkedRoot.appendingPathComponent("present.png")] {
            #expect(
                AppPaths.owns(candidate, within: linkedRoot)
                    == Self.referenceOwns(candidate, within: linkedRoot),
                "disagreement for \(candidate.path) under a symlinked root"
            )
        }
    }

    @Test("Escapes through a symlinked subdirectory are still rejected")
    func escapeRejected() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.cleanUp() }

        #expect(!AppPaths.owns(fixture.root.appendingPathComponent("Escape/secret.txt"), within: fixture.root))
        #expect(!AppPaths.owns(fixture.root.appendingPathComponent("Thumbnails/escape.png"), within: fixture.root))
        #expect(AppPaths.owns(fixture.root.appendingPathComponent("Thumbnails/present.png"), within: fixture.root))
        #expect(AppPaths.owns(fixture.root.appendingPathComponent("Thumbnails/missing.png"), within: fixture.root))
    }
}
