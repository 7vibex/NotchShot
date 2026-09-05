import AppKit
import Foundation
import ImageIO
import NotchShotKit

/// Paired post-save-panel handler benchmark. The reference preserves the old
/// second render; the current path reports metadata from the image it wrote.
@MainActor
enum ExportHandlerBenchmarks {
    static func run() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-export-bench-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cases: [(String, Int, Int, Int, Bool)] = [
            ("light", 2880, 1800, 12, false),
            ("heavy", 2880, 1800, 120, false),
            ("redactions", 2880, 1800, 40, true),
            ("heavy4K", 3840, 2160, 120, false),
        ]
        for (name, width, height, count, redactions) in cases {
            let controller = AnnotationDocumentController(
                source: Fixtures.screenshot(width: width, height: height),
                document: EditorBenchmarks.document(elementCount: count,
                    size: CGSize(width: width, height: height), includeRedactions: redactions)
            )
            let beforeURL = root.appendingPathComponent("before.png")
            let afterURL = root.appendingPathComponent("after.png")
            for iteration in -3..<15 {
                // AppKit drains temporary objects between UI events. Match
                // that lifetime instead of retaining every simulated export.
                let before: Double
                let after: Double
                if iteration.isMultiple(of: 2) {
                    before = try autoreleasepool { try measure(controller, to: beforeURL, reference: true) }
                    after = try autoreleasepool { try measure(controller, to: afterURL, reference: false) }
                } else {
                    after = try autoreleasepool { try measure(controller, to: afterURL, reference: false) }
                    before = try autoreleasepool { try measure(controller, to: beforeURL, reference: true) }
                }
                try autoreleasepool {
                    // Validate complete output and equal encoded bytes outside
                    // the timed interval. A skipped/failed export cannot pass.
                    let beforeData = try Data(contentsOf: beforeURL)
                    let afterData = try Data(contentsOf: afterURL)
                    precondition(beforeData == afterData)
                    guard let source = CGImageSourceCreateWithURL(afterURL as CFURL, nil),
                          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                        fatalError("Export benchmark did not produce a decodable PNG")
                    }
                    precondition(image.width == width && image.height == height)
                }
                if iteration >= 0 {
                    let row: [String: Any] = ["case": name, "iteration": iteration,
                        "reference_ms": before, "current_ms": after]
                    print(String(decoding: try JSONSerialization.data(withJSONObject: row, options: .sortedKeys), as: UTF8.self))
                }
            }
        }
    }

    @inline(never)
    private static func measure(_ controller: AnnotationDocumentController, to url: URL, reference: Bool) throws -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        let size: CGSize
        if reference {
            _ = try controller.exportImage(to: url, format: .png)
            let image = try controller.renderFlattened()
            size = CGSize(width: image.width, height: image.height)
        } else {
            size = try controller.exportImageResult(to: url, format: .png).pixelSize
        }
        Benchmark.blackHole(CaptureAsset(url: url, kind: .screenshot,
            pixelSize: size, scale: controller.document.sourceScale))
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
}
