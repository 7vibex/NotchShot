import CoreGraphics
import Foundation
import NotchShotKit

/// Deterministic inputs for the benchmarks.
///
/// Everything here is seeded, so two runs of the suite compare like with like.
/// That matters more than realism for the numbers to mean anything: a benchmark
/// whose input changes between runs measures the input, not the code.
enum Fixtures {

    /// A cheap, reproducible PRNG. `SystemRandomNumberGenerator` would make the
    /// fixtures differ run to run, which is exactly what a benchmark must not do.
    struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1 }

        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    /// A synthetic screenshot: smooth gradients with high-contrast rectangles on
    /// top, so it neither compresses like a solid colour nor like pure noise.
    static func screenshot(width: Int, height: Int, seed: UInt64 = 42) -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { fatalError("Could not allocate the benchmark fixture") }

        var generator = SeededGenerator(seed: seed)
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(red: 0.11, green: 0.12, blue: 0.16, alpha: 1))
        context.fill(full)

        for _ in 0 ..< 400 {
            let x = Double.random(in: 0 ..< Double(width), using: &generator)
            let y = Double.random(in: 0 ..< Double(height), using: &generator)
            let w = Double.random(in: 20 ..< 480, using: &generator)
            let h = Double.random(in: 12 ..< 220, using: &generator)
            context.setFillColor(CGColor(
                red: Double.random(in: 0 ... 1, using: &generator),
                green: Double.random(in: 0 ... 1, using: &generator),
                blue: Double.random(in: 0 ... 1, using: &generator),
                alpha: 1
            ))
            context.fill(CGRect(x: x, y: y, width: w, height: h))
        }

        guard let image = context.makeImage() else {
            fatalError("Could not render the benchmark fixture")
        }
        return image
    }

    /// A near-copy of `base` with a fraction of the frame overpainted, which is
    /// what the comparison view actually sees: two builds of the same screen.
    static func variant(of base: CGImage, changedFraction: Double, seed: UInt64 = 7) -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: base.width,
            height: base.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { fatalError("Could not allocate the benchmark fixture") }

        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        var generator = SeededGenerator(seed: seed)
        let changedHeight = Double(base.height) * changedFraction
        context.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(
            x: 0,
            y: Double.random(in: 0 ..< max(1, Double(base.height) - changedHeight), using: &generator),
            width: Double(base.width),
            height: changedHeight
        ))

        guard let image = context.makeImage() else {
            fatalError("Could not render the benchmark fixture")
        }
        return image
    }

    /// Roughly a page of recognised text, which is what OCR indexing stores per
    /// capture when "Search capture text" is on.
    static func recognizedText(seed: UInt64) -> String {
        var generator = SeededGenerator(seed: seed)
        let words = [
            "Dashboard", "Revenue", "Settings", "Account", "Invoice", "Preview",
            "Overview", "Quarterly", "Projection", "Baseline", "Component",
            "Navigator", "Inspector", "Timeline", "Threshold", "Deployment",
        ]
        var text = ""
        text.reserveCapacity(1400)
        for _ in 0 ..< 200 {
            text += words.randomElement(using: &generator)!
            text += " "
        }
        return text
    }

    /// A history store of `count` captures, half of them carrying indexed text.
    ///
    /// The mix matters: a store where every row has a text blob overstates search
    /// cost, and one where none do hides it entirely.
    ///
    /// Seeded through the on-disk store rather than an injection seam, so the
    /// repository under test is built by the same `load()` the app runs at launch.
    @MainActor
    static func history(count: Int, withIndexedText: Bool = true) -> HistoryRepository {
        HistoryRepository(storeURL: historyStore(count: count, withIndexedText: withIndexedText))
    }

    /// Writes a history store to a temporary file and returns its URL.
    static func historyStore(count: Int, withIndexedText: Bool = true) -> URL {
        let store = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("notchshot-bench-\(count)-\(withIndexedText).json")
        if !FileManager.default.fileExists(atPath: store.path) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted]
            let data = try! encoder.encode(entries(count: count, withIndexedText: withIndexedText))
            try! data.write(to: store, options: .atomic)
        }
        return store
    }

    static func entries(count: Int, withIndexedText: Bool = true) -> [HistoryEntry] {
        (0 ..< count).map { index in
            let asset = CaptureAsset(
                url: URL(fileURLWithPath: "/Users/bench/Pictures/Capture \(index).png"),
                kind: .screenshot,
                pixelSize: CGSize(width: 2880, height: 1800),
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(index)),
                sourceApplication: "com.example.app\(index % 20)",
                sourceApplicationName: "Example App \(index % 20)"
            )
            let text = (withIndexedText && index.isMultiple(of: 2))
                ? recognizedText(seed: UInt64(index) &+ 1)
                : nil
            return HistoryEntry(
                asset: asset,
                thumbnailFilename: "\(asset.id.uuidString).png",
                indexedText: text
            )
        }
    }
}
