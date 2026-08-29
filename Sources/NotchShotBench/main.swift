import AppKit
import CoreGraphics
import Foundation
import NotchShotKit

/// Performance benchmarks for the paths that sit on a user-visible latency
/// budget: taking a capture, searching history, launching, and dragging the
/// comparison threshold slider.
///
/// Run with `swift run -c release NotchShotBench [filter]`. Always release —
/// a debug build measures the absence of the optimiser, not the code.
///
///   swift run -c release NotchShotBench            # everything
///   swift run -c release NotchShotBench history    # only names containing "history"
@MainActor
func runBenchmarks() {
    let filter = CommandLine.arguments.dropFirst().first
    func enabled(_ name: String) -> Bool {
        guard let filter else { return true }
        return name.localizedCaseInsensitiveContains(filter)
    }

    print("NotchShot benchmarks — \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print(String(repeating: "─", count: 92))

    // MARK: History search
    //
    // Runs on every keystroke in the history window, and — because the view's
    // `entries` is a computed property — on every unrelated body evaluation too.

    if enabled("history.search") {
        let large = Fixtures.history(count: 5000)
        let rows = large.entries

        for query in ["zzqqxx", "Example App 3", "Threshold"] {
            let label = query == "zzqqxx" ? "no match" : "matches \(query)"
            let expected = Baselines.searchBefore(rows, query).count
            precondition(
                large.search(query).count == expected
                    && rows.filter { $0.matches(HistoryQuery(query)) }.count == expected
                    && Baselines.searchHoistedNeedle(rows, query).count == expected
                    && Baselines.searchCaseInsensitiveRange(rows, query).count == expected
                    && Baselines.searchSafeReference(rows, query).count == expected
                    && Baselines.searchByteScan(rows, query).count == expected,
                "search variants disagree for \(query)"
            )

            Benchmark.measure("search 5000 · \(label) [before        ]") {
                Benchmark.blackHole(Baselines.searchBefore(rows, query))
            }
            Benchmark.measure("search 5000 · \(label) [hoisted needle]") {
                Benchmark.blackHole(Baselines.searchHoistedNeedle(rows, query))
            }
            Benchmark.measure("search 5000 · \(label) [range options ]") {
                Benchmark.blackHole(Baselines.searchCaseInsensitiveRange(rows, query))
            }
            Benchmark.measure("search 5000 · \(label) [unsafe upper  ]") {
                Benchmark.blackHole(Baselines.searchByteScan(rows, query))
            }
            Benchmark.measure("search 5000 · \(label) [safe reference] ") {
                Benchmark.blackHole(Baselines.searchSafeReference(rows, query))
            }
            Benchmark.measure("search 5000 · \(label) [cold current  ]") {
                let prepared = HistoryQuery(query)
                Benchmark.blackHole(rows.filter { $0.matches(prepared) })
            }
            Benchmark.measure("search 5000 · \(label) [cache hit     ]") {
                Benchmark.blackHole(large.search(query))
            }
        }
    }

    // MARK: History record
    //
    // On the capture critical path: every screenshot lands here before the
    // shelf animates.

    if enabled("history.record") {
        var repository = Fixtures.history(count: 5000, withIndexedText: false)
        let rows = repository.entries
        let asset = CaptureAsset(
            url: URL(fileURLWithPath: "/Users/bench/Pictures/New Capture.png"),
            kind: .screenshot,
            pixelSize: CGSize(width: 2880, height: 1800)
        )
        let newRow = HistoryEntry(asset: asset, thumbnailFilename: nil, indexedText: nil)

        Benchmark.measure("history.record bookkeeping     [before]") {
            Benchmark.blackHole(Baselines.recordBookkeepingBefore(rows, newRow))
        }
        Benchmark.measure(
            "history.record bookkeeping     [after ]",
            setUp: { repository = Fixtures.history(count: 5000, withIndexedText: false) }
        ) {
            repository.record(asset: asset, image: nil, thumbnail: nil)
        }
    }

    // MARK: Managed-storage path checks
    //
    // `AppPaths.owns` gates every read, write and delete of a managed file, so
    // it is called once per history row on load and several times per capture.

    if enabled("paths") {
        let inside = URL(fileURLWithPath: AppPaths.thumbnails.path + "/A1B2.png")
        let outside = URL(fileURLWithPath: "/Users/bench/Pictures/Capture.png")
        let entry = Fixtures.entries(count: 1).first!

        precondition(
            AppPaths.owns(inside) == Baselines.ownsBefore(inside)
                && AppPaths.owns(outside) == Baselines.ownsBefore(outside)
                && entry.thumbnailURL == Baselines.validatedThumbnailURLBefore(
                    filename: entry.thumbnailFilename, id: entry.id
                ),
            "paths benchmark is comparing implementations that disagree"
        )

        Benchmark.measure("paths.support (1000×)          [before]", iterations: 15) {
            for _ in 0 ..< 1000 { Benchmark.blackHole(Baselines.supportBefore) }
        }
        Benchmark.measure("paths.support (1000×)          [after ]", iterations: 15) {
            for _ in 0 ..< 1000 { Benchmark.blackHole(AppPaths.support) }
        }
        Benchmark.measure("paths.owns inside (1000×)      [before]", iterations: 15) {
            for _ in 0 ..< 1000 { Benchmark.blackHole(Baselines.ownsBefore(inside)) }
        }
        Benchmark.measure("paths.owns inside (1000×)      [after ]", iterations: 15) {
            for _ in 0 ..< 1000 { Benchmark.blackHole(AppPaths.owns(inside)) }
        }
        Benchmark.measure("paths.owns outside (1000×)     [before]", iterations: 15) {
            for _ in 0 ..< 1000 { Benchmark.blackHole(Baselines.ownsBefore(outside)) }
        }
        Benchmark.measure("paths.owns outside (1000×)     [after ]", iterations: 15) {
            for _ in 0 ..< 1000 { Benchmark.blackHole(AppPaths.owns(outside)) }
        }
        Benchmark.measure("paths.thumbnailURL (1000×)     [before]", iterations: 15) {
            for _ in 0 ..< 1000 {
                Benchmark.blackHole(Baselines.validatedThumbnailURLBefore(
                    filename: entry.thumbnailFilename, id: entry.id
                ))
            }
        }
        Benchmark.measure("paths.thumbnailURL (1000×)     [after ]", iterations: 15) {
            for _ in 0 ..< 1000 { Benchmark.blackHole(entry.thumbnailURL) }
        }
    }

    // MARK: History load
    //
    // Launch-path cost: the repository is built during app startup.

    if enabled("history.load") {
        let store = Fixtures.historyStore(count: 5000)
        let data = try! Data(contentsOf: store)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let rows = try! decoder.decode([HistoryEntry].self, from: data)
        precondition(
            Baselines.sanitizeThumbnailsBefore(rows) == Baselines.sanitizeThumbnailsAfter(rows)
                && Baselines.sanitizeThumbnailsPrevious(rows)
                    == Baselines.sanitizeThumbnailsAfter(rows),
            "load validation variants disagree"
        )

        // Decoding alone, to separate the unavoidable parse cost from the
        // per-row validation the loader layers on top of it.
        Benchmark.measure("history.load  ├ JSON decode only", iterations: 9) {
            Benchmark.blackHole(try! decoder.decode([HistoryEntry].self, from: data))
        }
        Benchmark.measure("history.load  ├ row validation [before]", iterations: 9) {
            Benchmark.blackHole(Baselines.sanitizeThumbnailsBefore(rows))
        }
        Benchmark.measure("history.load  ├ row validation [previous]", iterations: 9) {
            Benchmark.blackHole(Baselines.sanitizeThumbnailsPrevious(rows))
        }
        Benchmark.measure("history.load  ├ row validation [after ]", iterations: 9) {
            Benchmark.blackHole(Baselines.sanitizeThumbnailsAfter(rows))
        }
        precondition(
            Baselines.coalesceBefore(rows).entries.map(\.id)
                == Baselines.coalesceAfter(rows).entries.map(\.id),
            "coalesce variants disagree"
        )
        Benchmark.measure("history.load  ├ coalesce rows  [before]", iterations: 9) {
            Benchmark.blackHole(Baselines.coalesceBefore(rows))
        }
        Benchmark.measure("history.load  ├ coalesce rows  [after ]", iterations: 9) {
            Benchmark.blackHole(Baselines.coalesceAfter(rows))
        }
        precondition(
            Baselines.loadBefore(from: store) == HistoryRepository(storeURL: store).entries.count,
            "load pipelines disagree on the row count"
        )
        Benchmark.measure("history.load 5000 rows          [before]", iterations: 9) {
            Benchmark.blackHole(Baselines.loadBefore(from: store))
        }
        Benchmark.measure("history.load 5000 rows          [after ]", iterations: 9) {
            Benchmark.blackHole(HistoryRepository(storeURL: store))
        }
    }

    // MARK: Control
    //
    // Nothing under test touches this. Its value across two runs of the suite
    // says how comparable those runs are — on a developer machine the load
    // average swings enough to move every other number by more than the changes
    // being measured do.

    if enabled("control") {
        // Seeded from a runtime value so the loop cannot be constant-folded.
        let seed = UInt64(ProcessInfo.processInfo.processIdentifier) | 0x243F_6A88_85A3_0000
        Benchmark.measure("control.fixed CPU workload", iterations: 15) {
            var accumulator = seed
            for _ in 0 ..< 4_000_000 {
                accumulator ^= accumulator << 13
                accumulator ^= accumulator >> 7
                accumulator ^= accumulator << 17
            }
            Benchmark.blackHole(accumulator)
        }
    }

    // MARK: Difference store strategy
    //
    // The comparison view re-runs this on every tick of the threshold slider,
    // against planes it has already cached, so it is a frame budget.

    if enabled("comparison") {
        let planeBytes = 3840 * 2160 * 4
        var left = [UInt8](repeating: 0, count: planeBytes)
        var right = [UInt8](repeating: 0, count: planeBytes)
        var generator = Fixtures.SeededGenerator(seed: 99)
        for index in stride(from: 0, to: planeBytes, by: 7) {
            left[index] = UInt8.random(in: 0 ... 255, using: &generator)
            right[index] = UInt8.random(in: 0 ... 255, using: &generator)
        }
        precondition(
            Baselines.differenceScalarStore(left, right, threshold: 12)
                == Baselines.differenceVectorStore(left, right, threshold: 12),
            "difference store strategies disagree"
        )

        Benchmark.measure("comparison.absoluteDifference  [scalar store]") {
            Benchmark.blackHole(Baselines.differenceScalarStore(left, right, threshold: 12))
        }
        Benchmark.measure("comparison.absoluteDifference  [vector store]") {
            Benchmark.blackHole(Baselines.differenceVectorStore(left, right, threshold: 12))
        }
    }

    // MARK: History save

    if enabled("history.save") {
        let repository = Fixtures.history(count: 5000)
        let rows = repository.entries
        let pretty = JSONEncoder()
        pretty.dateEncodingStrategy = .iso8601
        pretty.outputFormatting = [.prettyPrinted]
        let compact = JSONEncoder()
        compact.dateEncodingStrategy = .iso8601
        let prettyData = try! pretty.encode(rows)
        let compactData = try! compact.encode(rows)
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("notchshot-bench-save.json")

        print(String(
            format: "  (store size: pretty %.2f MB, compact %.2f MB)",
            Double(prettyData.count) / 1_048_576,
            Double(compactData.count) / 1_048_576
        ))

        Benchmark.measure("history.save 5000 rows to disk", iterations: 9) {
            try! repository.save()
        }
        Benchmark.measure("history.save  ├ encode (pretty-printed)", iterations: 9) {
            Benchmark.blackHole(try! pretty.encode(rows))
        }
        Benchmark.measure("history.save  ├ encode (compact)", iterations: 9) {
            Benchmark.blackHole(try! compact.encode(rows))
        }
        Benchmark.measure("history.save  └ atomic write only", iterations: 9) {
            try! prettyData.write(to: scratch, options: .atomic)
        }
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: Idle cost
    //
    // The notch polls the pointer only while it is showing something; an idle
    // notch runs no timer at all. This is what one tick of that poll reads.

    if enabled("idle") {
        Benchmark.measure("idle.NSEvent.mouseLocation (1000×)", iterations: 15) {
            for _ in 0 ..< 1000 { Benchmark.blackHole(NSEvent.mouseLocation) }
        }
    }

    // MARK: Capture encode and downsample
    //
    // Off the main actor, but still inside the window where the user is waiting
    // for the file to appear.

    if enabled("capture") {
        let fullScreen = Fixtures.screenshot(width: 3456, height: 2234)
        // Distinct sources, cycled: Core Graphics keeps a converted form of a
        // `CGImage` it has already drawn, so resampling the *same* fixture
        // fifteen times reports the cost of the cache rather than of the work.
        let sources = (0 ..< 8).map { Fixtures.screenshot(width: 3456, height: 2234, seed: 100 + UInt64($0)) }
        var cursor = 0

        Benchmark.measure(
            "capture.thumbnail 3456×2234 → 512",
            iterations: 16,
            setUp: { cursor = (cursor + 1) % sources.count }
        ) {
            let thumbnail = ImageExport.makeThumbnail(from: sources[cursor])
            Benchmark.blackHole(thumbnail?.dataProvider?.data)
        }
        Benchmark.blackHole(fullScreen)
        Benchmark.measure("capture.encode png 3456×2234", iterations: 9) {
            Benchmark.blackHole(try? ImageExport.encode(
                fullScreen, format: .png, quality: 1, dpiScale: 2
            ))
        }
        Benchmark.measure("capture.encode heic 3456×2234", iterations: 9) {
            Benchmark.blackHole(try? ImageExport.encode(
                fullScreen, format: .heic, quality: 0.8, dpiScale: 2
            ))
        }
    }

    // MARK: Visual comparison
    //
    // The threshold slider re-runs the difference on every drag tick, so this
    // number is a frame budget, not a one-off.

    if enabled("comparison") {
        let before = Fixtures.screenshot(width: 3840, height: 2160)
        let after = Fixtures.variant(of: before, changedFraction: 0.2)

        Benchmark.measure("comparison.difference 4K", iterations: 15) {
            Benchmark.blackHole(try? ImageComparisonRenderer.difference(
                before: before, after: after, threshold: 12
            ))
        }
    }

    EditorBenchmarks.run(enabled: enabled)

    print(String(repeating: "─", count: 92))
}

runBenchmarks()
