// Reproduces the `Process.waitUntilExit()` hang that stopped a full test run
// for five hours in `TerminalRunner.run` (2026-10-29 performance report).
//
// Each round runs eight TerminalRunner-shaped commands at once: launch from a
// detached task, poll `isRunning` with `Task.sleep`, kill the process group on
// timeout, then wait for exit the way `mode` says. A background task keeps
// launching short unrelated children, as the rest of a test run does. A wait
// still blocked after 8 s counts as hung.
//
//   swiftc -O -swift-version 5 process-wait-probe.swift -o process-wait-probe
//   ./process-wait-probe <rounds> wait|poll|handler|queue
//
// wait:    waitUntilExit() where the task resumed (the old code)
// poll:    while isRunning { await Task.sleep(5 ms) } (Process.waitForExit)
// handler: waitUntilExit() with a termination handler set
// queue:   waitUntilExit() on a global dispatch queue
//
// Stays in the scratch folder it is run from; writes only a marker folder
// under $TMPDIR.

import Foundation

final class Box: @unchecked Sendable { var done = false }

func groupExists(_ g: pid_t) -> Bool { errno = 0; return kill(-g, 0) == 0 || errno == EPERM }

func terminateGroup(_ g: pid_t) async {
    _ = kill(-g, SIGTERM)
    let grace = ProcessInfo.processInfo.systemUptime + 0.2
    while groupExists(g), ProcessInfo.processInfo.systemUptime < grace { try? await Task.sleep(for: .milliseconds(10)) }
    if groupExists(g) { _ = kill(-g, SIGKILL) }
}

// One TerminalRunner-shaped run. Returns nil when waitUntilExit outlives the watchdog.
func one(timeoutCase: Bool, dir: String, mode: String) async -> String? {
    let box = Box()
    let process = Process()
    let t = Task.detached(priority: .userInitiated) { () -> Void in
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", timeoutCase ? "(sleep 2; /usr/bin/touch '\(dir)/m') & sleep 10" : "yes x | head -c 264192"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        if mode == "handler" { process.terminationHandler = { _ in } }
        try! process.run()
        let pid = process.processIdentifier
        let deadline = ProcessInfo.processInfo.systemUptime + (timeoutCase ? 1 : 5)
        var timedOut = false
        while process.isRunning {
            if ProcessInfo.processInfo.systemUptime >= deadline { timedOut = true; break }
            try? await Task.sleep(for: .milliseconds(40))
        }
        if process.isRunning, timedOut { await terminateGroup(pid) }
        if mode == "poll" {
            while process.isRunning { try? await Task.sleep(for: .milliseconds(5)) }
        } else if mode == "queue" {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async { process.waitUntilExit(); c.resume() }
            }
        } else {
            process.waitUntilExit()  // "wait" and "handler"
        }
        _ = process.terminationStatus
        if groupExists(pid) { await terminateGroup(pid) }
        box.done = true
    }
    let limit = ProcessInfo.processInfo.systemUptime + 8
    while !box.done, ProcessInfo.processInfo.systemUptime < limit { try? await Task.sleep(for: .milliseconds(50)) }
    if box.done { await t.value; return "ok" }
    let pid = process.processIdentifier
    errno = 0
    let alive = kill(pid, 0) == 0
    return "HUNG pid=\(pid) isRunning=\(process.isRunning) alive=\(alive) errno=\(errno)"
}

let rounds = Int(CommandLine.arguments.dropFirst().first ?? "10") ?? 10
let width = 8
let mode = CommandLine.arguments.dropFirst(2).first ?? "wait"
let dir = NSTemporaryDirectory() + "waitprobe2-\(getpid())"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
// Unrelated short-lived children, as other tests would spawn.
let noise = Task.detached {
    while !Task.isCancelled {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", "exit 0"]
        try? p.run(); p.waitUntilExit()
    }
}
var hung: [String] = []
var total = 0
for r in 0..<rounds {
    await withTaskGroup(of: String?.self) { group in
        for i in 0..<width { group.addTask { await one(timeoutCase: (i + r) % 2 == 0, dir: dir, mode: mode) } }
        for await result in group { total += 1; if let result, result != "ok" { hung.append(result) } }
    }
}
noise.cancel()
print("mode=\(mode) runs=\(total) hung=\(hung.count)")
hung.prefix(5).forEach { print($0) }
exit(0)
