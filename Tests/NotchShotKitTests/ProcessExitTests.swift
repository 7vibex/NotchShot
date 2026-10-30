import Foundation
import Testing
@testable import NotchShotKit

/// The replacements for `waitUntilExit()` must come back with the exit status
/// readable. The race they avoid needs load to show, so it is not reproduced
/// here: `Documentation/Performance/2026-10-29-evidence/process-wait-probe.swift`
/// does that, and passes against `waitUntilExit()` as well as these.
@Suite("Process exit")
struct ProcessExitTests {
    @Test("Async and blocking waits return with the exit status", .timeLimit(.minutes(1)))
    func waitsReturnTheStatus() async throws {
        let statuses = try await withThrowingTaskGroup(of: (Int32, Int32).self) { group in
            for index: Int32 in 0 ..< 24 {
                group.addTask {
                    let process = Self.shell("sleep 0.0$((\(index) % 5)); exit \(index)")
                    try process.run()
                    if index.isMultiple(of: 2) {
                        await process.waitForExit()
                    } else {
                        process.blockUntilExit()
                    }
                    #expect(!process.isRunning)
                    return (index, process.terminationStatus)
                }
            }
            return try await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
        }
        #expect(statuses.count == 24)
        #expect(statuses.allSatisfy { $0.key == $0.value })
    }

    @Test("A terminated process is waited for, not abandoned", .timeLimit(.minutes(1)))
    func terminatedProcess() async throws {
        let process = Self.shell("sleep 10")
        try process.run()
        process.terminate()
        await process.waitForExit()
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGTERM)
    }

    private static func shell(_ command: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }
}
