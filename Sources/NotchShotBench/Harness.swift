import Foundation

/// One timed iteration, kept in execution order.
struct BenchmarkSample: Sendable {
    let benchmark: String
    let iteration: Int
    let elapsedSeconds: Double
    let succeeded: Bool
}

/// Run-wide facts recorded with every sample so a result file is
/// self-describing even when it is copied off the machine that produced it.
struct BenchmarkEnvironment: Sendable {
    let sourceSHA: String?
    let operatingSystem: String
    let toolchain: String
}

extension BenchmarkEnvironment {
    static let current: BenchmarkEnvironment = {
        BenchmarkEnvironment(
            sourceSHA: BenchmarkEnvironment.gitSourceSHA(),
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            toolchain: BenchmarkEnvironment.swiftToolchain()
        )
    }()

    private static func gitSourceSHA() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-parse", "HEAD"]
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let sha = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    private static func swiftToolchain() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", "--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil {
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !output.isEmpty { return output }
            }
        }
        #if swift(>=6.3)
        return "Swift >= 6.3"
        #elseif swift(>=6.2)
        return "Swift >= 6.2"
        #else
        return "Swift toolchain unknown"
        #endif
    }
}

/// A completed benchmark. Raw samples stay in execution order; the summaries
/// are derived only from iterations that actually produced output.
struct BenchmarkResult {
    let name: String
    let samples: [BenchmarkSample]
    let warmupCount: Int
    let warmupFailures: Int
    let environment: BenchmarkEnvironment

    var iterations: Int { samples.count }
    var failures: Int { samples.filter { !$0.succeeded }.count }
    var isValid: Bool { failures == 0 && warmupFailures == 0 && !samples.isEmpty }

    private var succeededSeconds: [Double] {
        samples.filter(\.succeeded).map(\.elapsedSeconds).sorted()
    }

    var medianSeconds: Double {
        let values = succeededSeconds
        return values.isEmpty ? .nan : values[values.count / 2]
    }

    var minimumSeconds: Double {
        succeededSeconds.first ?? .nan
    }

    var medianMilliseconds: Double { medianSeconds * 1000 }
    var minimumMilliseconds: Double { minimumSeconds * 1000 }
}

/// Minimal timing harness for the performance benchmarks.
///
/// Reports the *median* rather than the mean: these benchmarks share a machine
/// with the rest of macOS, so the distribution has a long right tail that a mean
/// tracks and a median ignores. The minimum is reported alongside it because for
/// a deterministic, allocation-bound routine the fastest observed run is the one
/// least polluted by unrelated scheduling.
enum Benchmark {
    static var environment: BenchmarkEnvironment { BenchmarkJournal.shared?.environment ?? .current }

    /// Runs `body` `iterations` times after `warmup` untimed runs.
    ///
    /// `setUp` runs before each timed iteration and is excluded from the timing,
    /// which is what makes it possible to benchmark mutating operations without
    /// the fixture rebuild landing in the measurement.
    ///
    /// A throwing iteration is recorded as a failure rather than crashing, and
    /// the result is only valid when every timed iteration succeeded. Callers
    /// that need a benchmark to fail loudly should check `isValid`.
    @discardableResult
    static func measure(
        _ name: String,
        iterations: Int = 15,
        warmup: Int = 3,
        setUp: () -> Void = {},
        _ body: () throws -> Void
    ) -> BenchmarkResult {
        var warmupFailures = 0
        for _ in 0 ..< warmup {
            setUp()
            do { try body() } catch { warmupFailures += 1 }
        }

        var samples: [BenchmarkSample] = []
        samples.reserveCapacity(iterations)
        for iteration in 0 ..< iterations {
            setUp()
            let start = DispatchTime.now().uptimeNanoseconds
            var succeeded = true
            do {
                try body()
            } catch {
                succeeded = false
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            let sample = BenchmarkSample(
                benchmark: name,
                iteration: iteration,
                elapsedSeconds: elapsed,
                succeeded: succeeded
            )
            samples.append(sample)
            BenchmarkJournal.shared?.record(sample)
        }

        let result = BenchmarkResult(
            name: name,
            samples: samples,
            warmupCount: warmup,
            warmupFailures: warmupFailures,
            environment: environment
        )
        report(result)
        BenchmarkJournal.shared?.recordSummary(result)
        return result
    }

    /// Closes the raw-sample journal and returns its path, if one was opened.
    @discardableResult
    static func finish() -> URL? {
        defer { BenchmarkJournal.shared?.close() }
        BenchmarkJournal.shared?.writeRunEnd()
        return BenchmarkJournal.shared?.url
    }

    private static func report(_ result: BenchmarkResult) {
        let median = result.medianSeconds.isNaN ? "      n/a" : String(format: "%9.3f", result.medianMilliseconds)
        let minimum = result.minimumSeconds.isNaN ? "      n/a" : String(format: "%9.3f", result.minimumMilliseconds)
        let name = result.name.padding(toLength: 46, withPad: " ", startingAt: 0)
        let failures = result.failures > 0 ? "   FAILURES=\(result.failures + result.warmupFailures)" : ""
        print("\(name) median \(median) ms   min \(minimum) ms   n=\(result.iterations)\(failures)")
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

/// Append-only JSON Lines journal. One metadata line, one line per timed
/// iteration in execution order, one summary line per benchmark, and a closing
/// run-end line.
private final class BenchmarkJournal: @unchecked Sendable {
    static let shared: BenchmarkJournal? = BenchmarkJournal()

    let url: URL
    let environment: BenchmarkEnvironment
    private let handle: FileHandle

    private init?() {
        environment = .current
        let override = ProcessInfo.processInfo.environment["NOTCHSHOT_BENCH_RESULTS"]
        let target: URL
        if let override, !override.isEmpty {
            target = URL(fileURLWithPath: override)
        } else {
            target = FileManager.default.temporaryDirectory
                .appendingPathComponent("notchshot-bench-\(getpid())-\(UUID().uuidString.prefix(8)).jsonl")
        }
        guard FileManager.default.createFile(atPath: target.path, contents: nil),
              let handle = FileHandle(forWritingAtPath: target.path) else { return nil }
        self.url = target
        self.handle = handle
        var metadata: [String: Any] = [
            "record": "run",
            "operating_system": environment.operatingSystem,
            "toolchain": environment.toolchain,
        ]
        if let sha = environment.sourceSHA { metadata["source_sha"] = sha }
        write(metadata)
    }

    func record(_ sample: BenchmarkSample) {
        var row: [String: Any] = [
            "record": "sample",
            "benchmark": sample.benchmark,
            "iteration": sample.iteration,
            "elapsed_seconds": sample.elapsedSeconds,
            "succeeded": sample.succeeded,
        ]
        appendEnvironment(&row)
        write(row)
    }

    func recordSummary(_ result: BenchmarkResult) {
        var row: [String: Any] = [
            "record": "summary",
            "benchmark": result.name,
            "iterations": result.iterations,
            "failures": result.failures,
            "warmup_count": result.warmupCount,
            "warmup_failures": result.warmupFailures,
            "valid": result.isValid,
        ]
        if !result.medianSeconds.isNaN { row["median_seconds"] = result.medianSeconds }
        if !result.minimumSeconds.isNaN { row["minimum_seconds"] = result.minimumSeconds }
        appendEnvironment(&row)
        write(row)
    }

    func writeRunEnd() {
        var row: [String: Any] = ["record": "run_end"]
        appendEnvironment(&row)
        write(row)
    }

    func close() {
        try? handle.close()
    }

    private func appendEnvironment(_ row: inout [String: Any]) {
        row["operating_system"] = environment.operatingSystem
        row["toolchain"] = environment.toolchain
        if let sha = environment.sourceSHA { row["source_sha"] = sha }
    }

    private func write(_ row: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        handle.write(data)
        handle.write(Data([10]))
    }
}
