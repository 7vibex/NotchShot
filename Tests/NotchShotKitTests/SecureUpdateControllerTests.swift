import Foundation
import Testing
@testable import NotchShotKit

/// The updater must stay disabled unless a signed HTTPS feed is fully
/// configured. Local builds ship without feed values and must never contact
/// a placeholder service.
@Suite("Secure updater configuration")
@MainActor
struct SecureUpdateControllerTests {

    /// 32 zero bytes as base64 — structurally valid, never a real release key.
    private var validKey: String {
        Data(repeating: 0, count: 32).base64EncodedString()
    }

    private func bundle(feed: String?, key: String?) throws -> Bundle {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("notchshot-updater-tests-\(UUID().uuidString).bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var plist: [String: Any] = [:]
        if let feed { plist["SUFeedURL"] = feed }
        if let key { plist["SUPublicEDKey"] = key }
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: dir.appendingPathComponent("Info.plist"))
        guard let bundle = Bundle(url: dir) else {
            Issue.record("Could not load test bundle at \(dir.path)")
            throw CancellationError()
        }
        return bundle
    }

    @Test("HTTPS feed with a 32-byte key is the only valid configuration")
    func validConfiguration() throws {
        let good = try bundle(
            feed: "https://updates.example.com/notchshot/appcast.xml",
            key: validKey)
        #expect(SecureUpdateController.configurationIsValid(in: good))
    }

    @Test("Local builds without feed values stay updater-disabled")
    func missingValuesFailClosed() throws {
        #expect(!SecureUpdateController.configurationIsValid(
            in: try bundle(feed: nil, key: nil)))
        #expect(!SecureUpdateController.configurationIsValid(
            in: try bundle(feed: "https://updates.example.com/appcast.xml", key: nil)))
        #expect(!SecureUpdateController.configurationIsValid(
            in: try bundle(feed: nil, key: validKey)))
    }

    @Test("Non-HTTPS feeds and embedded credentials are rejected")
    func insecureFeedsRejected() throws {
        for feed in [
            "http://updates.example.com/appcast.xml",
            "ftp://updates.example.com/appcast.xml",
            "https://user:pass@updates.example.com/appcast.xml",
            "not a url",
        ] {
            #expect(!SecureUpdateController.configurationIsValid(
                in: try bundle(feed: feed, key: validKey)), "feed: \(feed)")
        }
    }

    @Test("Malformed public keys are rejected")
    func malformedKeysRejected() throws {
        let feed = "https://updates.example.com/notchshot/appcast.xml"
        for key in [
            "not-base64!!!",
            Data(repeating: 1, count: 16).base64EncodedString(),
            Data(repeating: 2, count: 64).base64EncodedString(),
            "",
        ] {
            #expect(!SecureUpdateController.configurationIsValid(
                in: try bundle(feed: feed, key: key)), "key length variant rejected")
        }
    }
}
