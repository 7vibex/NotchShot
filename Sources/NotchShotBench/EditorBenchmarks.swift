import AppKit
import CoreGraphics
import Foundation
import NotchShotKit

/// Benchmarks for the subsystems behind the editor, the scrolling capture and
/// the export sheet — the parts of the app the first pass never measured.
@MainActor
enum EditorBenchmarks {

    /// A document with `count` annotations spread over the frame, in the mix a
    /// real one has: mostly shapes and arrows, some text, a few redactions.
    static func document(elementCount: Int, size: CGSize, includeRedactions: Bool) -> AnnotationDocument {
        var generator = Fixtures.SeededGenerator(seed: 21)
        let kinds: [AnnotationKind] = [.rectangle, .arrow, .ellipse, .line, .pencil, .text, .counter]
        let elements = (0 ..< elementCount).map { index -> AnnotationElement in
            let kind: AnnotationKind = (includeRedactions && index.isMultiple(of: 9))
                ? .pixelate
                : kinds[index % kinds.count]
            let origin = CGPoint(
                x: Double.random(in: 0 ..< size.width * 0.8, using: &generator),
                y: Double.random(in: 0 ..< size.height * 0.8, using: &generator)
            )
            let points: [CGPoint] = kind == .pencil
                ? (0 ..< 40).map { step in
                    CGPoint(x: origin.x + Double(step) * 3, y: origin.y + Double(step % 7) * 4)
                }
                : [origin, CGPoint(x: origin.x + 220, y: origin.y + 140)]
            return AnnotationElement(
                kind: kind,
                points: points,
                style: AnnotationStyle(),
                text: kind == .text ? "Annotation \(index)" : "",
                order: index,
                counterValue: index + 1
            )
        }
        return AnnotationDocument(
            sourcePixelSize: size,
            elements: elements
        )
    }

    static func run(enabled: (String) -> Bool) {
        // MARK: Annotation export
        //
        // What the user waits on after pressing Export in the editor.

        if enabled("annotation") {
            let size = CGSize(width: 2880, height: 1800)
            let source = Fixtures.screenshot(width: 2880, height: 1800)
            let light = document(elementCount: 12, size: size, includeRedactions: false)
            let heavy = document(elementCount: 120, size: size, includeRedactions: false)
            let redacted = document(elementCount: 40, size: size, includeRedactions: true)

            Benchmark.measure("annotation.render 12 elements", iterations: 9) {
                Benchmark.blackHole(try? AnnotationRenderer.render(document: light, source: source))
            }
            Benchmark.measure("annotation.render 120 elements", iterations: 9) {
                Benchmark.blackHole(try? AnnotationRenderer.render(document: heavy, source: source))
            }
            Benchmark.measure("annotation.render 40 with redactions", iterations: 9) {
                Benchmark.blackHole(try? AnnotationRenderer.render(document: redacted, source: source))
            }

            // Hit testing runs on pointer events while editing.
            let point = CGPoint(x: size.width / 2, y: size.height / 2)
            Benchmark.measure("annotation.hitTest 120 elements (1000×)", iterations: 15) {
                for _ in 0 ..< 1000 { Benchmark.blackHole(heavy.element(at: point)) }
            }
            // The editor's `Canvas` reads this on every repaint, which during a
            // drag is every frame.
            Benchmark.measure("annotation.sortedElements 120 (1000×)", iterations: 15) {
                for _ in 0 ..< 1000 { Benchmark.blackHole(heavy.sortedElements) }
            }
        }

        // MARK: Smart export

        if enabled("export") {
            let source = Fixtures.screenshot(width: 3456, height: 2234)
            Benchmark.measure("export.render 3456→1600 wide", iterations: 9) {
                Benchmark.blackHole(try? SmartExportService.render(
                    source,
                    to: CGSize(width: 1600, height: 1034)
                ))
            }
        }

        // MARK: Scrolling stitch
        //
        // Runs once at the end of a scrolling capture, with the user waiting.

        if enabled("stitch") {
            let frames = scrollingFrames(count: 8, width: 1200, height: 900, advance: 640)
            Benchmark.measure("stitch 8 frames 1200×900", iterations: 9) {
                Benchmark.blackHole(try? ScrollingStitcher.stitch(frames: frames))
            }
        }
    }

    /// Frames of one tall page seen through a scrolling window, so consecutive
    /// frames genuinely overlap and the matcher has something real to lock onto.
    static func scrollingFrames(count: Int, width: Int, height: Int, advance: Int) -> [CGImage] {
        let pageHeight = height + advance * count
        let page = Fixtures.screenshot(width: width, height: pageHeight, seed: 5)
        return (0 ..< count).compactMap { index in
            page.cropping(to: CGRect(
                x: 0,
                y: index * advance,
                width: width,
                height: height
            ))
        }
    }
}
