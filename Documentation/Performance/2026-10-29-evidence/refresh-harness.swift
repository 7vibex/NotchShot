// Island refresh harness for the 2026-10-29 report (30 October follow-up). It ran as a
// temporary file in Tests/NotchShotKitTests and was removed afterwards; copy it back there
// to rerun:  REFRESH_HARNESS=1 REFRESH_OUT=<file> swift test --filter ZZRefreshHarness
// Feeds synthetic Claude hooks straight into the monitor of a real island, offscreen, with
// the app's `context.onSnapshotChange` wiring and source observation, and counts main-thread
// instructions from each hook until the run loop is quiet. Opens no socket.

import AppKit
import Darwin
import SwiftUI
import Testing
@testable import NotchShotKit

@_silgen_name("thread_selfcounts")
private func thread_selfcounts(_ type: Int32, _ buffer: UnsafeMutableRawPointer, _ size: Int) -> Int32

@Suite("ZZ refresh harness", .serialized)
@MainActor
struct ZZRefreshHarness {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["REFRESH_HARNESS"] == "1"))
    func hookRefreshes() async throws {
        let coordinator = AppCoordinator()
        coordinator.rendersAsActiveDisplay = true
        let metrics = NotchMetrics(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            hasPhysicalNotch: true,
            notchSize: CGSize(width: 185, height: 32),
            menuBarHeight: 32
        )
        let display = NotchDisplayContext(displayID: 1, metrics: metrics, isPrimary: true, isBuiltIn: true)
        let size = CGSize(width: NotchLayout.maximumSize.width + NotchLayout.shadowPadding * 2,
                          height: NotchLayout.maximumSize.height + NotchLayout.shadowPadding)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: AnyView(NotchRootView(coordinator: coordinator, context: display)))
        hosting.sizingOptions = []
        hosting.frame = CGRect(origin: .zero, size: size)
        window.contentView = hosting

        // The app's wiring from `AppCoordinator.start()` and `ContextCoordinator.start()`,
        // without starting any service.
        coordinator.context.claude.onSnapshotChange = { [weak context = coordinator.context] snapshot in
            context?.updateClaude(snapshot)
        }
        var direct = 0
        coordinator.context.onSnapshotChange = { [weak coordinator] snapshot in
            direct += 1
            coordinator?.arbiter.context = snapshot
            coordinator?.refreshActivity()
        }
        coordinator.observeIslandSources()

        func instructions() -> UInt64 {
            var counts: (UInt64, UInt64) = (0, 0)
            _ = withUnsafeMutableBytes(of: &counts) { thread_selfcounts(1, $0.baseAddress!, $0.count) }
            return counts.0
        }
        func render() {
            hosting.layoutSubtreeIfNeeded()
            hosting.display()
        }
        var tick = 0
        func hook(_ event: String) throws {
            tick += 1
            let object: [String: Any] = [
                "session_id": "synthetic-harness", "hook_event_name": event,
                "tool_name": ["Read", "Bash", "Edit", "Grep"][tick % 4],
                "prompt": "Synthetic prompt", "cwd": "/tmp/synthetic-project",
            ]
            coordinator.context.claude.receiveHookData(try JSONSerialization.data(withJSONObject: object))
        }
        func quiet() async {
            for _ in 0 ..< 4 {
                render()
                try? await Task.sleep(for: .milliseconds(25))
            }
        }

        try hook("UserPromptSubmit")
        for _ in 0 ..< 30 { try hook("PreToolUse"); await quiet() }
        var rows: [String] = []
        for round in 1 ... 5 {
            var perHook: [UInt64] = []
            let directBefore = direct
            for _ in 0 ..< 20 {
                await quiet()
                let start = instructions()
                try hook("PreToolUse")
                for _ in 0 ..< 6 {
                    render()
                    try? await Task.sleep(for: .milliseconds(25))
                }
                perHook.append(instructions() - start)
            }
            let sorted = perHook.sorted()
            rows.append(String(
                format: "round %d: per hook median %.2f M, min %.2f M, max %.2f M; direct refreshes %d of 20",
                round, Double(sorted[10]) / 1e6, Double(sorted[0]) / 1e6, Double(sorted[19]) / 1e6,
                direct - directBefore
            ))
        }
        let out = ProcessInfo.processInfo.environment["REFRESH_OUT"] ?? "/dev/stdout"
        try rows.joined(separator: "\n").appending("\n").write(toFile: out, atomically: false, encoding: .utf8)
        withExtendedLifetime(window) {}
    }
}
