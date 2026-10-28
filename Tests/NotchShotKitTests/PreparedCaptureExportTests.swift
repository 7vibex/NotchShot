import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import NotchShotKit

@Suite("Prepared capture export", .serialized)
@MainActor
struct PreparedCaptureExportTests {
    private func source() -> CapturedImage {
        CapturedImage(
            cgImage: TestImage.page(width: 512, height: 256, offset: 17), scale: 2,
            sourceRect: CGRect(x: 31, y: 57, width: 256, height: 128)
        )
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prepared-capture-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The pre-optimization fitter, independent of the new encoding-carrying
    /// helper. Keep its attempt count, rounding and final verification intact.
    private func legacyFit(_ image: CGImage, limit: Int, format: ImageFormat, quality: Double) throws -> CGImage {
        var candidate = image
        for _ in 0..<8 {
            try Task.checkCancellation()
            let count = try ImageExport.encode(candidate, format: format, quality: quality, dpiScale: 2).data.count
            if count <= limit { return candidate }
            let ratio = sqrt(Double(limit) / Double(max(count, 1))) * 0.94
            let scale = min(max(ratio, 0.35), 0.92)
            candidate = try SmartExportService.render(candidate, to: CGSize(
                width: max(1, (CGFloat(candidate.width) * scale).rounded(.down)),
                height: max(1, (CGFloat(candidate.height) * scale).rounded(.down))
            ))
        }
        try Task.checkCancellation()
        guard try ImageExport.encode(candidate, format: format, quality: quality, dpiScale: 2).data.count <= limit else {
            throw NotchShotError.exportFailed("Legacy fitting limit")
        }
        return candidate
    }

    @Test("Output matches the original fitter, encoder settings and DPI", arguments: [ImageFormat.png, .jpeg])
    func fidelity(format: ImageFormat) async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = source()
        let quality = 0.63
        for recipeBase in [CaptureRecipe.all[0], CaptureRecipe.all[1]] {
            for limit in [nil, 0, -1, 1_000_000, 2_000] as [Int?] {
                var recipe = recipeBase
                recipe.targetMaximumBytes = limit
                let rendered = try CaptureRecipeRenderer.render(input, recipe: recipe)
                let reference: CGImage
                do {
                    reference = try limit.flatMap { $0 > 0 ? $0 : nil }.map {
                        try legacyFit(rendered.cgImage, limit: $0, format: format, quality: quality)
                    } ?? rendered.cgImage
                } catch {
                    await #expect(throws: NotchShotError.self) {
                        try await CaptureRecipeRenderer.prepareForExport(input, recipe: recipe, format: format, quality: quality)
                    }
                    continue
                }
                let expected = try ImageExport.encode(reference, format: format, quality: quality, dpiScale: 2)
                let prepared = try await CaptureRecipeRenderer.prepareForExport(input, recipe: recipe, format: format, quality: quality)
                let url = directory.appendingPathComponent(UUID().uuidString)
                #expect(try await prepared.write(to: url) == expected.format)
                let actual = try Data(contentsOf: url)
                #expect(actual == expected.data)
                #expect(prepared.image.scale == input.scale && prepared.image.sourceRect == input.sourceRect)
                #expect(prepared.image.cgImage.width == reference.width && prepared.image.cgImage.height == reference.height)
                if let limit, limit > 0 { #expect(actual.count <= limit) }
                let container = try #require(CGImageSourceCreateWithData(actual as CFData, nil))
                let properties = try #require(CGImageSourceCopyPropertiesAtIndex(container, 0, nil) as? [CFString: Any])
                let dpiWidth = try #require(properties[kCGImagePropertyDPIWidth] as? NSNumber)
                let dpiHeight = try #require(properties[kCGImagePropertyDPIHeight] as? NSNumber)
                // PNG's integer pixels-per-metre representation can round DPI.
                #expect(abs(dpiWidth.doubleValue - 144) < 0.1)
                #expect(abs(dpiHeight.doubleValue - 144) < 0.1)
            }
        }
    }

    @Test("An accepted PNG fallback is written with its actual format")
    func acceptedFallback() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = source()
        let encoded = try ImageExport.encode(input.cgImage, format: .png, quality: 1, dpiScale: 2)
        let prepared = PreparedCaptureExport(image: input, format: .heic, quality: 0.63, encoding: encoded)
        let url = directory.appendingPathComponent("fallback")
        #expect(try await prepared.write(to: url) == .png)
        #expect(try Data(contentsOf: url) == encoded.data)
    }

    @Test("Canceled preparation and impossible limits leave an existing destination untouched")
    func cancelledAndImpossible() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("existing.png")
        let marker = Data("existing destination".utf8)
        try marker.write(to: url)
        let input = source()
        let cancelled = Task {
            let prepared = try await CaptureRecipeRenderer.prepareForExport(input, recipe: CaptureRecipe.all[0], format: .png, quality: 1)
            return try await prepared.write(to: url)
        }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        var impossible = CaptureRecipe.all[0]
        impossible.targetMaximumBytes = 1
        await #expect(throws: NotchShotError.self) {
            let prepared = try await CaptureRecipeRenderer.prepareForExport(input, recipe: impossible, format: .png, quality: 1)
            return try await prepared.write(to: url)
        }
        #expect(try Data(contentsOf: url) == marker)
    }

    @Test("A write failure preserves the existing parent file")
    func writeFailure() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let parent = directory.appendingPathComponent("file-as-parent")
        let marker = Data("preserve me".utf8)
        try marker.write(to: parent)
        var recipe = CaptureRecipe.all[0]
        recipe.targetMaximumBytes = 1_000_000
        let prepared = try await CaptureRecipeRenderer.prepareForExport(source(), recipe: recipe, format: .png, quality: 1)
        await #expect(throws: (any Error).self) { try await prepared.write(to: parent.appendingPathComponent("capture.png")) }
        #expect(try Data(contentsOf: parent) == marker)
    }

    @Test("Concurrent preparations keep their own pixels and accepted bytes")
    func independentExports() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = source()
        let second = CapturedImage(cgImage: TestImage.solid(width: 37, height: 29, red: 213), scale: 1, sourceRect: .zero)
        var recipe = CaptureRecipe.all[0]
        recipe.targetMaximumBytes = 1_000_000
        async let a = CaptureRecipeRenderer.prepareForExport(first, recipe: recipe, format: .png, quality: 1)
        async let b = CaptureRecipeRenderer.prepareForExport(second, recipe: recipe, format: .png, quality: 1)
        let pair = try await (a, b)
        let outputs = [pair.0, pair.1]
        for (prepared, input) in zip(outputs, [first, second]) {
            let url = directory.appendingPathComponent(UUID().uuidString)
            _ = try await prepared.write(to: url)
            #expect(try Data(contentsOf: url) == ImageExport.encode(input.cgImage, format: .png, quality: 1, dpiScale: input.scale).data)
        }
    }
}
