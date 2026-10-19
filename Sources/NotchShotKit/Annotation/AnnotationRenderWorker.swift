import AppKit
import CoreGraphics
import Foundation

struct EncodedAnnotationImage: Sendable {
    let data: Data
    let format: ImageFormat
    let pixelSize: CGSize
    let sourceScale: CGFloat
}

/// All mutable editor state is copied on the main actor before submitting work.
/// CGImage is immutable; the snapshot owns its reference for the whole job.
struct AnnotationRenderSnapshot: @unchecked Sendable {
    let source: CGImage
    let document: AnnotationDocument
    let seams: [StitchSeam]

    func render(isPreview: Bool = false) throws -> CapturedImage {
        try Task.checkCancellation()
        let image = try AnnotationRenderer.render(
            document: document, source: source,
            options: AnnotationRenderer.Options(isPreview: isPreview, seams: seams)
        )
        try Task.checkCancellation()
        return CapturedImage(cgImage: image, scale: document.sourceScale, sourceRect: .zero)
    }

    func encode(format: ImageFormat, quality: Double) throws -> EncodedAnnotationImage {
        let flattened = try render()
        let encoded = try ImageExport.encode(flattened.cgImage, format: format, quality: quality, dpiScale: document.sourceScale)
        try Task.checkCancellation()
        return EncodedAnnotationImage(data: encoded.data, format: encoded.format, pixelSize: flattened.pixelSize, sourceScale: document.sourceScale)
    }

    func export(to url: URL, format: ImageFormat, quality: Double) throws -> AnnotationDocumentController.ImageExportResult {
        let encoded = try encode(format: format, quality: quality)
        // Cancellation before committing leaves the destination untouched.
        // Once atomic writing starts, finish its rename and return its metadata.
        try Task.checkCancellation()
        try ImageExport.writeEncoded(encoded.data, to: url)
        var finalURL = url
        if encoded.format != format {
            let preferred = url.deletingPathExtension().appendingPathExtension(encoded.format.fileExtension)
            if FileManager.default.fileExists(atPath: preferred.path) {
                finalURL = AppPaths.uniqueURL(
                    in: preferred.deletingLastPathComponent(),
                    name: preferred.deletingPathExtension().lastPathComponent,
                    extension: encoded.format.fileExtension
                )
            } else {
                finalURL = preferred
            }
            try FileManager.default.moveItem(at: url, to: finalURL)
        }
        return AnnotationDocumentController.ImageExportResult(
            url: finalURL, pixelSize: encoded.pixelSize, sourceScale: encoded.sourceScale
        )
    }
}

/// One bitmap job at a time across editors. Canceled queued jobs check before
/// allocating canvases; views allow one output action and cancel stale previews.
actor AnnotationRenderWorker {
    static let shared = AnnotationRenderWorker()

    func render(_ snapshot: AnnotationRenderSnapshot, isPreview: Bool = false) throws -> CapturedImage {
        try autoreleasepool { try snapshot.render(isPreview: isPreview) }
    }

    func encode(_ snapshot: AnnotationRenderSnapshot, format: ImageFormat, quality: Double) throws -> EncodedAnnotationImage {
        try autoreleasepool { try snapshot.encode(format: format, quality: quality) }
    }

    func export(_ snapshot: AnnotationRenderSnapshot, to url: URL, format: ImageFormat, quality: Double) throws -> AnnotationDocumentController.ImageExportResult {
        try autoreleasepool { try snapshot.export(to: url, format: format, quality: quality) }
    }
}
