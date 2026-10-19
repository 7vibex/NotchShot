import AppKit
import ImageIO
import PDFKit
import Testing
@testable import NotchShotKit

@Suite("PDF conversion cancellation")
struct PDFConversionCancellationTests {
    @Test("A canceled public PDF conversion writes no pages and preserves existing files")
    func publicCancellation() async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdf = try makePDF(in: directory, pages: 2)
        let existing = directory.appendingPathComponent("fixture-page1.png")
        let original = Data("pre-existing destination".utf8)
        try original.write(to: existing)
        let request = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MediaConversion.convert(pdf, to: .pngPages, in: directory)
        }
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(try Data(contentsOf: existing) == original)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) == ["fixture.pdf", "fixture-page1.png"])
    }

    @Test("PDF conversion retains page limit, ordering and two-times raster dimensions")
    func pageLimitAndOrder() async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdf = try makePDF(in: directory, pages: MediaConversion.maximumPDFPages + 1)
        let outputs = try await MediaConversion.convert(pdf, to: .pngPages, in: directory)
        #expect(outputs.map(\.lastPathComponent) == (1...MediaConversion.maximumPDFPages).map { "fixture-page\($0).png" })
        for (index, output) in outputs.enumerated() {
            let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == 16 && image.height == 12)
            let bitmap = NSBitmapImageRep(cgImage: image)
            // Black/white bits encode the original page number, independent of
            // PDFKit's color-profile conversion of intermediate channel values.
            for bit in 0..<6 {
                let color = try #require(bitmap.colorAt(x: (bit + 1) * 2 + 1, y: 6)?.usingColorSpace(.sRGB))
                let expected = ((index + 1) >> bit) & 1 == 0 ? CGFloat(0) : CGFloat(1)
                #expect(abs(color.redComponent - expected) < 0.015)
            }
        }
    }

    @Test("An unavailable second page fails and rolls back this attempt's first page")
    func unavailablePageRollsBack() async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdf = try makePDF(in: directory, pages: 2)
        let existing = directory.appendingPathComponent("fixture-page1.png")
        let published = directory.appendingPathComponent("fixture-page1 2.png")
        let original = Data("pre-existing destination".utf8)
        try original.write(to: existing)
        let request = Task.detached {
            try MediaConversion.renderPDFPages(pdf, baseName: "fixture", directory: directory) { document, index in
                if index == 1 {
                    #expect(FileManager.default.fileExists(atPath: published.path))
                    return nil
                }
                return document.page(at: index)
            }
        }
        await #expect(throws: NotchShotError.exportFailed("PDF page 2 could not be read")) { try await request.value }
        #expect(try Data(contentsOf: existing) == original)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) == ["fixture.pdf", "fixture-page1.png"])
    }

    @Test("Cancellation after publishing page one rolls back only this attempt's output")
    func activeCancellationRollsBack() async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdf = try makePDF(in: directory, pages: 2)
        let existing = directory.appendingPathComponent("fixture-page1.png")
        let published = directory.appendingPathComponent("fixture-page1 2.png")
        let original = Data("pre-existing destination".utf8)
        try original.write(to: existing)
        let request = Task.detached {
            try MediaConversion.renderPDFPages(pdf, baseName: "fixture", directory: directory) { document, index in
                if index == 1 {
                    #expect(FileManager.default.fileExists(atPath: published.path))
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                return document.page(at: index)
            }
        }
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(try Data(contentsOf: existing) == original)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) == ["fixture.pdf", "fixture-page1.png"])
    }

    @Test("Rollback preserves a published page replaced by another writer")
    func replacedPageIsPreserved() async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdf = try makePDF(in: directory, pages: 2)
        let existing = directory.appendingPathComponent("fixture-page1.png")
        let published = directory.appendingPathComponent("fixture-page1 2.png")
        let original = Data("pre-existing destination".utf8)
        let replacement = Data("replacement owned by another writer".utf8)
        try original.write(to: existing)
        let request = Task.detached {
            try MediaConversion.renderPDFPages(pdf, baseName: "fixture", directory: directory) { document, index in
                if index == 1 {
                    #expect(FileManager.default.fileExists(atPath: published.path))
                    #expect(throws: Never.self) { try replacement.write(to: published, options: .atomic) }
                    return nil
                }
                return document.page(at: index)
            }
        }
        await #expect(throws: NotchShotError.exportFailed("PDF page 2 could not be read")) { try await request.value }
        #expect(try Data(contentsOf: existing) == original)
        #expect(try Data(contentsOf: published) == replacement)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) == ["fixture.pdf", "fixture-page1.png", "fixture-page1 2.png"])
    }

    private func workspace() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-cancellation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makePDF(in directory: URL, pages: Int) throws -> URL {
        let url = directory.appendingPathComponent("fixture.pdf")
        var box = CGRect(x: 0, y: 0, width: 8, height: 6)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for index in 0..<pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(box)
            for bit in 0..<6 {
                let value = ((index + 1) >> bit) & 1 == 0 ? CGFloat(0) : CGFloat(1)
                context.setFillColor(CGColor(gray: value, alpha: 1))
                context.fill(CGRect(x: bit + 1, y: 0, width: 1, height: 6))
            }
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }
}
