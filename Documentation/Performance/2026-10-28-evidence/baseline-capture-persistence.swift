import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import NotchShotKit

/// Completed recipe preparation and atomic file output, with output validation
/// outside timing. Uses disposable files and never touches the general clipboard.
@MainActor
enum CapturePersistenceBenchmarks {
    static func run() async throws {
        let directory = Fixtures.runDirectory.appendingPathComponent("capture-persistence")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = ProcessInfo.processInfo.environment["NOTCHSHOT_CAPTURE_RESULTS"]
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("notchshot-capture-persistence-\(UUID().uuidString).jsonl").path
        let journalURL = URL(fileURLWithPath: path)
        precondition(!FileManager.default.fileExists(atPath: path), "Use a fresh results path")
        FileManager.default.createFile(atPath: path, contents: nil)
        let journal = try FileHandle(forWritingTo: journalURL)
        defer { try? journal.close() }
        let clock = ContinuousClock()
        let source = CapturedImage(
            cgImage: Fixtures.screenshot(width: 3456, height: 2234), scale: 2,
            sourceRect: CGRect(x: 80, y: 50, width: 1728, height: 1117)
        )
        for (label, format, quality, fraction) in [
            ("standard-png", ImageFormat.png, 1.0, 0.0),
            ("bounded-png-fits", .png, 1.0, 2.0),
            ("bounded-png-resize", .png, 1.0, 0.1),
            ("bounded-jpeg-resize", .jpeg, 0.72, 0.5),
        ] {
            var recipe = CaptureRecipe.all[0]
            let originalBytes = try ImageExport.encode(
                source.cgImage, format: format, quality: quality, dpiScale: source.scale
            ).data.count
            if fraction > 0 { recipe.targetMaximumBytes = Int(Double(originalBytes) * fraction) }
            let reference = try await CaptureRecipeRenderer.prepare(
                source, recipe: recipe, format: format, quality: quality
            )
            let expected = try ImageExport.encode(
                reference.cgImage, format: format, quality: quality, dpiScale: reference.scale
            )
            var totals: [Double] = []
            for iteration in 0..<11 {
                let url = directory.appendingPathComponent("\(label)-\(iteration).image")
                precondition(!FileManager.default.fileExists(atPath: url.path))
                let start = clock.now
                let heartbeat = Task { @MainActor in milliseconds(start.duration(to: clock.now)) }
                let output = try await prepareAndWrite(
                    source, recipe: recipe, format: format, quality: quality, to: url
                )
                let total = milliseconds(start.duration(to: clock.now))
                let delivery = await heartbeat.value
                let actual = try Data(contentsOf: url)
                precondition(actual == expected.data, "Persisted bytes changed")
                precondition(output.format == expected.format && output.image.pixelSize == reference.pixelSize)
                precondition(output.image.scale == source.scale && output.image.sourceRect == source.sourceRect)
                if let limit = recipe.targetMaximumBytes { precondition(actual.count <= limit) }
                guard let decoded = CGImageSourceCreateWithData(actual as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(decoded, 0, nil) else {
                    fatalError("Persisted capture cannot be decoded")
                }
                precondition(image.width == reference.cgImage.width && image.height == reference.cgImage.height)
                if iteration >= 2 {
                    totals.append(total)
                    let row: [String: Any] = [
                        "workload": label, "iteration": iteration - 2, "totalMS": total,
                        "mainActorDeliveryMS": delivery, "bytes": actual.count,
                        "width": image.width, "height": image.height,
                        "sha256": SHA256.hash(data: actual).map { String(format: "%02x", $0) }.joined(),
                    ]
                    try journal.write(contentsOf: JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([10]))
                }
                try FileManager.default.removeItem(at: url)
            }
            print("capture-persistence \(label): completed median \(totals.sorted()[totals.count / 2]) ms; n=\(totals.count)")
        }
        try journal.write(contentsOf: Data("{\"event\":\"run_end\",\"samples\":36}\n".utf8))
        print("capture-persistence samples: \(path)")
    }

    private static func prepareAndWrite(
        _ source: CapturedImage, recipe: CaptureRecipe, format: ImageFormat,
        quality: Double, to url: URL
    ) async throws -> (image: CapturedImage, format: ImageFormat) {
        let image = try await CaptureRecipeRenderer.prepare(source, recipe: recipe, format: format, quality: quality)
        let written = try await ImageExport.write(image, to: url, format: format, quality: quality)
        return (image, written)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}
