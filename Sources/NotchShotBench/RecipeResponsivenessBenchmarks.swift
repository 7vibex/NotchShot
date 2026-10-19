import CoreGraphics
import Foundation
import NotchShotKit

/// Measures delivery of an unrelated main-actor task during real recipe work.
/// This is a synthetic responsiveness check, not a screenshot or frame-rate test.
@MainActor
enum RecipeResponsivenessBenchmarks {
    static func run() async throws {
        let clock = ContinuousClock()
        let useWorker = ProcessInfo.processInfo.environment["NOTCHSHOT_RECIPE_MODE"] == "worker"
        let path = ProcessInfo.processInfo.environment["NOTCHSHOT_RECIPE_RESULTS"]
            ?? Fixtures.runDirectory.appendingPathComponent("recipe-responsiveness.jsonl").path
        let url = URL(fileURLWithPath: path)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let journal = try FileHandle(forWritingTo: url)
        defer { try? journal.close() }
        var bounded = CaptureRecipe.all[0]
        bounded.id = "custom-bounded"
        bounded.targetMaximumBytes = 600_000
        let recipes = [CaptureRecipe.all[0], CaptureRecipe.all[1], CaptureRecipe.all[2], bounded]
        for recipe in recipes {
            var delays: [Double] = []
            var totals: [Double] = []
            for iteration in 0..<11 {
                // A fresh immutable source avoids warming a CGImage conversion cache.
                let source = Fixtures.screenshot(width: 3456, height: 2234, seed: UInt64(100 + iteration))
                let input = CapturedImage(
                    cgImage: source, scale: 2,
                    sourceRect: CGRect(x: 0, y: 0, width: 1728, height: 1117)
                )
                let start = clock.now
                let probe = Task { @MainActor in start.duration(to: clock.now) }
                let output = useWorker
                    ? try await CaptureRecipeRenderer.prepare(input, recipe: recipe, format: .png, quality: 1)
                    : try prepare(input, recipe: recipe)
                let total = milliseconds(start.duration(to: clock.now))
                let delay = milliseconds(await probe.value)
                precondition(output.cgImage.width > 0 && output.cgImage.height > 0)
                precondition(output.scale == input.scale && output.sourceRect == input.sourceRect)
                if let size = recipe.outputPixelSize { precondition(output.pixelSize == size) }
                if iteration == 0 {
                    let reference = try prepare(input, recipe: recipe)
                    let expected = try ImageExport.encode(reference.cgImage, format: .png, quality: 1, dpiScale: 2).data
                    let actual = try ImageExport.encode(output.cgImage, format: .png, quality: 1, dpiScale: 2).data
                    precondition(actual == expected, "worker changed recipe pixels")
                }
                if let limit = recipe.targetMaximumBytes {
                    let bytes = try ImageExport.encode(output.cgImage, format: .png, quality: 1, dpiScale: 2).data
                    precondition(bytes.count <= limit, "bounded recipe did not fit")
                }
                if iteration >= 2 {
                    delays.append(delay)
                    totals.append(total)
                    let data = try JSONSerialization.data(withJSONObject: [
                        "recipe": recipe.id, "iteration": iteration - 2,
                        "mode": useWorker ? "worker" : "baseline",
                        "mainActorDelayMS": delay, "totalMS": total,
                        "width": output.cgImage.width, "height": output.cgImage.height,
                    ], options: [.sortedKeys])
                    try journal.write(contentsOf: data + Data([10]))
                }
            }
            print("recipe \(recipe.id): main-actor delivery median \(delays.sorted()[delays.count / 2]) ms; work median \(totals.sorted()[totals.count / 2]) ms; n=\(delays.count)")
        }
        print("recipe raw samples: \(path)")
    }

    private static func prepare(_ input: CapturedImage, recipe: CaptureRecipe) throws -> CapturedImage {
        var output = try CaptureRecipeRenderer.render(input, recipe: recipe)
        if let limit = recipe.targetMaximumBytes {
            output = CapturedImage(
                cgImage: try SmartExportService.renderToFit(
                    output.cgImage, maximumBytes: limit, format: .png, quality: 1, dpiScale: output.scale
                ),
                scale: output.scale, sourceRect: output.sourceRect
            )
        }
        return output
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}
