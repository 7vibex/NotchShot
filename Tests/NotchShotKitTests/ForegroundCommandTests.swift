import Darwin
import Foundation
import Testing

import NotchShotAIReporterSupport

/// `activity run` must behave like the command typed directly: the same exit
/// status, still the terminal's foreground job, and Ctrl-C delivered to it.
/// Serialized because the runner changes process-wide signal handling while
/// a command runs.
@Suite("Wrapped command", .serialized)
struct ForegroundCommandTests {
    @Test("The exit status is what a shell would report")
    func exitStatus() throws {
        #expect(try ForegroundCommand.run(["/bin/sh", "-c", "exit 3"]) == .exited(3))
        #expect(try ForegroundCommand.run(["/bin/sh", "-c", "exit 0"]).shellStatus == 0)
        // `env` reports a command it cannot find with 127, as a shell does.
        #expect(try ForegroundCommand.run(["notchshot-missing-\(UUID().uuidString)"]) == .exited(127))
    }

    @Test("The command stays in the caller's process group, in its directory")
    func sameProcessGroup() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("pgid").path
        let outcome = try ForegroundCommand.run(
            ["/bin/sh", "-c", #"ps -o pgid= -p $$ > "$1"; pwd -P >> "$1""#, "sh", output],
            currentDirectory: folder.path
        )
        #expect(outcome == .exited(0))
        let lines = try String(contentsOfFile: output, encoding: .utf8)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        // Foundation's `Process` gives the child a group of its own, which the
        // terminal treats as a background job.
        #expect(lines.first == String(getpgrp()))
        let resolved = try #require(realpath(folder.path, nil))
        defer { free(resolved) }
        #expect(lines.last == String(cString: resolved))
    }

    @Test("An interrupt reaches the command, and the caller's handling comes back")
    func interruptReachesTheCommand() throws {
        var before = sigaction()
        sigaction(SIGINT, nil, &before)
        let started = ContinuousClock.now
        // A shell started with the interrupt ignored could not be interrupted
        // and would sleep the full five seconds.
        let outcome = try ForegroundCommand.run(["/bin/sh", "-c", "kill -INT $$; sleep 5"])
        #expect(outcome == .signaled(SIGINT))
        #expect(outcome.shellStatus == 130)
        #expect(started.duration(to: .now) < .seconds(4))
        var after = sigaction()
        sigaction(SIGINT, nil, &after)
        #expect(Self.handler(after) == Self.handler(before))
    }

    @Test("A terminate sent to the wrapper is passed on to the command")
    func terminateIsForwarded() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ready = folder.appendingPathComponent("ready").path
        // Sent only once the command has set its trap and is waiting, so it
        // lands while the runner ignores terminates and forwards them. Never
        // sent otherwise: by then it would end the test process.
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: ready), Date() < deadline { usleep(10_000) }
            if FileManager.default.fileExists(atPath: ready) { kill(getpid(), SIGTERM) }
        }
        let outcome = try ForegroundCommand.run(
            ["/bin/sh", "-c", #"trap 'exit 42' TERM; : > "$1"; sleep 10 & wait"#, "sh", ready]
        )
        #expect(outcome == .exited(42))
    }

    private static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-command-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func handler(_ action: sigaction) -> Int {
        action.__sigaction_u.__sa_handler.map { unsafeBitCast($0, to: Int.self) } ?? 0
    }
}
