import Foundation
import Testing
@testable import NotchShotKit

/// The OSD helper's strict signature check is reused only while the bundle is
/// unchanged on disk; any change, or a bundle that can't be read, checks again.
@Suite("Signature verdict cache")
struct SignatureVerdictCacheTests {
    @Test("An unchanged bundle is validated once")
    func unchangedBundleValidatesOnce() throws {
        let bundle = try Self.makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }
        var cache = SignatureVerdictCache()
        var checks = 0

        for _ in 0 ..< 3 {
            #expect(cache.isValid(for: BundleFileStamps(bundle: bundle)) { checks += 1; return true })
        }
        #expect(checks == 1)
    }

    @Test("A failed verdict is kept too, so a broken helper isn't rechecked on every call")
    func failedVerdictIsKept() throws {
        let bundle = try Self.makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }
        var cache = SignatureVerdictCache()
        var checks = 0

        #expect(!cache.isValid(for: BundleFileStamps(bundle: bundle)) { checks += 1; return false })
        #expect(!cache.isValid(for: BundleFileStamps(bundle: bundle)) { checks += 1; return true })
        #expect(checks == 1)
    }

    @Test("Editing, adding or replacing a file checks again")
    func changedBundleValidatesAgain() throws {
        let bundle = try Self.makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }
        let helper = bundle.appendingPathComponent("Contents/MacOS/Helper")
        let changes: [() throws -> Void] = [
            // Same size, modification time set back: only the change time moves.
            {
                let attributes = try FileManager.default.attributesOfItem(atPath: helper.path)
                try Data("HELPER-B".utf8).write(to: helper)
                try FileManager.default.setAttributes(
                    [.modificationDate: attributes[.modificationDate] as Any], ofItemAtPath: helper.path
                )
            },
            { try Data("extra".utf8).write(to: bundle.appendingPathComponent("Contents/Resources/New")) },
            {
                let replacement = bundle.appendingPathComponent("Contents/Replacement")
                try Data("HELPER-C".utf8).write(to: replacement)
                _ = try FileManager.default.replaceItemAt(helper, withItemAt: replacement)
            },
            { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path) },
        ]
        var cache = SignatureVerdictCache()
        var checks = 0
        _ = cache.isValid(for: BundleFileStamps(bundle: bundle)) { checks += 1; return true }

        for (index, change) in changes.enumerated() {
            try change()
            _ = cache.isValid(for: BundleFileStamps(bundle: bundle)) { checks += 1; return true }
            #expect(checks == index + 2, "change \(index) was not noticed")
        }
    }

    @Test("A bundle that can't be read is checked every time")
    func unreadableBundleIsNeverCached() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("SignatureVerdictCacheTests-\(UUID().uuidString).app")
        #expect(BundleFileStamps(bundle: missing) == nil)
        var cache = SignatureVerdictCache()
        var checks = 0
        for _ in 0 ..< 2 {
            _ = cache.isValid(for: BundleFileStamps(bundle: missing)) { checks += 1; return true }
        }
        #expect(checks == 2)
    }

    @Test("A verdict recorded off the main thread is reused like one checked here")
    func recordedVerdictIsReused() throws {
        let bundle = try Self.makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }
        var cache = SignatureVerdictCache()
        #expect(!cache.hasVerdict)
        cache.record(false, for: BundleFileStamps(bundle: bundle))
        #expect(cache.hasVerdict)
        var checks = 0
        #expect(!cache.isValid(for: BundleFileStamps(bundle: bundle)) { checks += 1; return true })
        #expect(checks == 0)

        // An unreadable bundle records nothing, so the next enable checks again.
        var unread = SignatureVerdictCache()
        unread.record(true, for: nil)
        #expect(!unread.hasVerdict)
    }

    private static func makeBundle() throws -> URL {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("SignatureVerdictCacheTests-\(UUID().uuidString).app")
        for directory in ["Contents/MacOS", "Contents/Resources"] {
            try FileManager.default.createDirectory(
                at: bundle.appendingPathComponent(directory), withIntermediateDirectories: true
            )
        }
        try Data("HELPER-A".utf8).write(to: bundle.appendingPathComponent("Contents/MacOS/Helper"))
        try Data("plist".utf8).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        return bundle
    }
}
