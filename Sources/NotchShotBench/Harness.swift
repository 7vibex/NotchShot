import Foundation

/// Minimal timing harness for the performance benchmarks.
///
/// Reports the *median* rather than the mean: these benchmarks share a machine
/// with the rest of macOS, so the distribution has a long right tail that a mean
/// tracks and a median ignores. The minimum is reported alongside it because for
/// a deterministic, allocation-bound routine the fastest observed run is the one
/// least polluted by unrelated scheduling.
struct BenchmarkResult {
    let name: String
    let medianSeconds: Double
    let minimumSeconds: Double
    let iterations: Int

    var medianMilliseconds: Double { medianSeconds * 1000 }
    var minimumMilliseconds: Double { minimumSeconds * 1000 }
}

enum Benchmark {
    /// Runs `body` `iterations` times after `warmup` untimed runs.
    ///
    /// `setUp` runs before each timed iteration and is excluded from the timing,
    /// which is what makes it possible to benchmark mutating operations without
    /// the fixture rebuild landing in the measurement.
    @discardableResult
    static func measure(
        _ name: String,
        iterations: Int = 15,
        warmup: Int = 3,
        setUp: () -> Void = {},
        _ body: () -> Void
    ) -> BenchmarkResult {
        for _ in 0 ..< warmup {
            setUp()
            body()
        }

        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        for _ in 0 ..< iterations {
            setUp()
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            let end = DispatchTime.now().uptimeNanoseconds
            samples.append(Double(end - start) / 1_000_000_000)
        }

        samples.sort()
        let median = samples[samples.count / 2]
        let result = BenchmarkResult(
            name: name,
            medianSeconds: median,
            minimumSeconds: samples[0],
            iterations: iterations
        )
        report(result)
        return result
    }

    private static func report(_ result: BenchmarkResult) {
        let median = String(format: "%9.3f", result.medianMilliseconds)
        let minimum = String(format: "%9.3f", result.minimumMilliseconds)
        let name = result.name.padding(toLength: 46, withPad: " ", startingAt: 0)
        print("\(name) median \(median) ms   min \(minimum) ms   n=\(result.iterations)")
    }

    /// Keeps the optimiser from deleting a computation whose result is unused.
    ///
    /// Writing the value somewhere it cannot prove is dead is the part that
    /// matters. `withExtendedLifetime` alone was not enough: it left the control
    /// benchmark's arithmetic loop free to be folded away entirely, which showed
    /// up as a workload that took 0.000 ms.
    @inline(never)
    static func blackHole<T>(_ value: T) {
        sink = UInt(bitPattern: ObjectIdentifier(T.self).hashValue) &+ sunkCount
        sunkCount &+= 1
        withExtendedLifetime(value) {}
    }

    @inline(never)
    static func blackHole(_ value: UInt64) {
        sink = UInt(truncatingIfNeeded: value)
    }

    nonisolated(unsafe) private static var sink: UInt = 0
    nonisolated(unsafe) private static var sunkCount: UInt = 0
}
