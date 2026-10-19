import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import NotchShotKit

@Suite("Export safety regressions")
struct ExportSafetyRegressionTests {
    private func sourceImage() -> CGImage {
        TestImage.make(width: 32, height: 32) { context in
            for x in 0..<32 {
                context.setFillColor(red: CGFloat(x) / 32, green: 0.5, blue: 0.2, alpha: 1)
                context.fill(CGRect(x: x, y: 0, width: 1, height: 32))
            }
        }
    }

    private func pixelationDocument(from: CGPoint = .zero, to: CGPoint = CGPoint(x: 24, y: 24)) -> AnnotationDocument {
        AnnotationDocument(
            sourcePixelSize: CGSize(width: 32, height: 32),
            sourceScale: 1,
            elements: [.rect(kind: .pixelate, from: from, to: to, style: AnnotationStyle())]
        )
    }

    @Test("Pixelation failure refuses both burn-in and finished export")
    func pixelationFailureRefusesExport() throws {
        let source = sourceImage()
        let document = pixelationDocument()
        #expect(throws: NotchShotError.self) {
            _ = try AnnotationRenderer.burnRedactions(document: document, into: source, pixelation: { _, _, _, _ in nil })
        }
        #expect(throws: NotchShotError.self) {
            _ = try AnnotationRenderer.render(document: document, source: source, pixelation: { _, _, _, _ in nil })
        }
        // A failure neither returns the original as an export nor alters the
        // editable source. An independent normal call still redacts it.
        let exported = try AnnotationRenderer.render(document: document, source: source)
        let region = CGRect(x: 0, y: 0, width: 24, height: 24)
        #expect(TestImage.distinctColors(source, in: region).count > 10)
        #expect(TestImage.distinctColors(exported, in: region).count <= 4)
    }

    @Test("Partly outside pixelation clips and still destroys visible detail")
    func clippedPixelationRemainsSafe() throws {
        let source = sourceImage()
        let document = pixelationDocument(from: CGPoint(x: -8, y: -8), to: CGPoint(x: 24, y: 24))
        let exported = try AnnotationRenderer.render(document: document, source: source)
        #expect(TestImage.distinctColors(exported, in: CGRect(x: 0, y: 0, width: 24, height: 24)).count <= 4)
        let unchanged = TestImage.pixel(exported, x: 28, y: 28)
        let original = TestImage.pixel(source, x: 28, y: 28)
        #expect(unchanged.r == original.r && unchanged.g == original.g && unchanged.b == original.b)
    }

    @Test("Entirely outside redactions need no pixelation output")
    func outsidePixelationIsHarmless() throws {
        let source = sourceImage()
        let document = pixelationDocument(from: CGPoint(x: 40, y: 40), to: CGPoint(x: 48, y: 48))
        let rendered = try AnnotationRenderer.render(document: document, source: source, pixelation: { _, _, _, _ in
            Issue.record("An outside redaction must not request pixelation")
            return nil
        })
        #expect(TestImage.pixel(rendered, x: 12, y: 12).r == TestImage.pixel(source, x: 12, y: 12).r)
    }

    private func fixture() throws -> (directory: URL, source: URL, bytes: Data) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notchshot-export-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let source = directory.appendingPathComponent("authorized.txt")
        let bytes = Data("authorized private bytes".utf8)
        try bytes.write(to: source)
        return (directory, source, bytes)
    }

    private var configuration: ShareLinkConfiguration {
        var value = ShareLinkConfiguration()
        value.endpoint = "https://storage.invalid"
        value.bucket = "test"
        value.accessKeyID = "test-key"
        return value
    }

    private func response(for request: URLRequest, status: Int = 200) throws -> HTTPURLResponse {
        let url = try #require(request.url)
        return try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
    }

    @Test("The public URL uploader refuses symlinks before any request")
    func symlinkUploadIsRefused() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let link = fixture.directory.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.source)
        await #expect(throws: ShareLinkUploader.UploadError.self) {
            _ = try await ShareLinkUploader.upload(link, configuration: configuration, secret: "fake")
        }
    }

    @Test("The asset uploader refuses replacement of the stored identity")
    func replacedAssetIsRefused() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let identity = try #require(SafeAssetFile.identity(at: fixture.source, maximumBytes: ShareLinkUploader.maximumBytes))
        let asset = CaptureAsset(url: fixture.source, kind: .text, pixelSize: .zero, ownership: .externalReference, externalFileIdentity: identity)
        try Data("unapproved replacement".utf8).write(to: fixture.source, options: .atomic)
        await #expect(throws: ShareLinkUploader.UploadError.self) {
            _ = try await ShareLinkUploader.upload(asset, configuration: configuration, secret: "fake")
        }
    }

    @Test("External assets without a recorded identity are refused")
    func unverifiedExternalAssetIsRefused() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var asset = CaptureAsset(url: fixture.source, kind: .text, pixelSize: .zero, ownership: .externalReference)
        asset.externalFileIdentity = nil
        await #expect(throws: ShareLinkUploader.UploadError.self) {
            _ = try await ShareLinkUploader.upload(asset, configuration: configuration, secret: "fake")
        }
    }

    @Test("Owned assets without a stored identity are refused by the asset uploader")
    func unverifiedOwnedAssetsAreRefused() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        for ownership in [CaptureAssetOwnership.userDocument, .managedTemporary] {
            let asset = CaptureAsset(
                url: fixture.source, kind: .text, pixelSize: .zero,
                ownership: ownership, captureMissingFileIdentities: false
            )
            #expect(asset.externalFileIdentity == nil)
            await #expect(throws: ShareLinkUploader.UploadError.self) {
                _ = try await ShareLinkUploader.upload(asset, configuration: configuration, secret: "fake")
            }
        }
    }

    @Test("Legacy owned selection pins its identity before asynchronous upload")
    func legacySelectionRefusesLaterReplacement() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        for ownership in [CaptureAssetOwnership.userDocument, .managedTemporary] {
            let legacy = CaptureAsset(
                url: fixture.source, kind: .text, pixelSize: .zero,
                ownership: ownership, captureMissingFileIdentities: false
            )
            let selected = try ShareLinkUploader.assetForSelection(legacy)
            #expect(legacy.externalFileIdentity == nil)
            #expect(selected.externalFileIdentity != nil)
            try Data("replacement after selection".utf8).write(to: fixture.source, options: .atomic)
            await #expect(throws: ShareLinkUploader.UploadError.self) {
                _ = try await ShareLinkUploader.upload(selected, configuration: configuration, secret: "fake")
            }
        }
    }

    @Test("Hash, length and body use a private snapshot even after source replacement")
    func stableSnapshotIsUploadedAndCleaned() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let probe = SnapshotProbe()
        _ = try await ShareLinkUploader.upload(fixture.source, expectedIdentity: nil, configuration: configuration, secret: "fake") { request, snapshot in
            await probe.record(snapshot)
            #expect(snapshot != fixture.source)
            let attributes = try FileManager.default.attributesOfItem(atPath: snapshot.deletingLastPathComponent().path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
            let permissions = try FileManager.default.attributesOfItem(atPath: snapshot.path)
            #expect((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            try Data("replacement that was never approved".utf8).write(to: fixture.source, options: .atomic)
            let body = try Data(contentsOf: snapshot)
            #expect(body == fixture.bytes)
            #expect(request.value(forHTTPHeaderField: "content-length") == String(body.count))
            #expect(request.value(forHTTPHeaderField: "x-amz-content-sha256") == S3Signer.hex(SHA256.hash(data: body)))
            #expect(request.value(forHTTPHeaderField: "content-type") == "text/plain")
            return (Data(), try response(for: request))
        }
        let snapshot = try #require(await probe.snapshot)
        #expect(!FileManager.default.fileExists(atPath: snapshot.deletingLastPathComponent().path))
    }

    @Test("Service rejection removes its snapshot")
    func rejectionCleansSnapshot() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let probe = SnapshotProbe()
        await #expect(throws: ShareLinkUploader.UploadError.self) {
            _ = try await ShareLinkUploader.upload(fixture.source, expectedIdentity: nil, configuration: configuration, secret: "fake") { request, snapshot in
                await probe.record(snapshot)
                return (Data("<Error><Code>AccessDenied</Code></Error>".utf8), try response(for: request, status: 403))
            }
        }
        let snapshot = try #require(await probe.snapshot)
        #expect(!FileManager.default.fileExists(atPath: snapshot.deletingLastPathComponent().path))
    }

    @Test("Transport errors and cancellation remove their snapshots")
    func transportFailureCleansSnapshot() async throws {
        for cancellation in [false, true] {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let probe = SnapshotProbe()
            await #expect(throws: (any Error).self) {
                _ = try await ShareLinkUploader.upload(fixture.source, expectedIdentity: nil, configuration: configuration, secret: "fake") { _, snapshot in
                    await probe.record(snapshot)
                    if cancellation { throw CancellationError() }
                    throw URLError(.cannotConnectToHost)
                }
            }
            let snapshot = try #require(await probe.snapshot)
            #expect(!FileManager.default.fileExists(atPath: snapshot.deletingLastPathComponent().path))
        }
    }

    @Test("Task cancellation after transport returns cleans the snapshot")
    func cancelledUploadCleansSnapshot() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let probe = SnapshotProbe()
        let upload = Task {
            try await ShareLinkUploader.upload(fixture.source, expectedIdentity: nil, configuration: configuration, secret: "fake") { request, snapshot in
                await probe.record(snapshot)
                withUnsafeCurrentTask { $0?.cancel() }
                return (Data(), try response(for: request))
            }
        }
        await #expect(throws: CancellationError.self) { _ = try await upload.value }
        let snapshot = try #require(await probe.snapshot)
        #expect(!FileManager.default.fileExists(atPath: snapshot.deletingLastPathComponent().path))
    }

    @Test("An empty file has a zero length and the SHA-256 of its empty body")
    func emptyFileHasConsistentMetadata() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try Data().write(to: fixture.source)
        _ = try await ShareLinkUploader.upload(fixture.source, expectedIdentity: nil, configuration: configuration, secret: "fake") { request, snapshot in
            #expect(try Data(contentsOf: snapshot).isEmpty)
            #expect(request.value(forHTTPHeaderField: "content-length") == "0")
            #expect(request.value(forHTTPHeaderField: "x-amz-content-sha256") == S3Signer.emptyPayloadHash)
            return (Data(), try response(for: request))
        }
    }

    @Test("The upload cap is enforced before the transport")
    func oversizedFileIsRefused() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let handle = try FileHandle(forWritingTo: fixture.source)
        try handle.truncate(atOffset: UInt64(ShareLinkUploader.maximumBytes) + 1)
        try handle.close()
        await #expect(throws: ShareLinkUploader.UploadError.self) {
            _ = try await ShareLinkUploader.upload(fixture.source, expectedIdentity: nil, configuration: configuration, secret: "fake") { _, _ in
                Issue.record("An oversized file must not reach the transport")
                throw CancellationError()
            }
        }
    }
}

private actor SnapshotProbe {
    private(set) var snapshot: URL?
    func record(_ value: URL) { snapshot = value }
}
