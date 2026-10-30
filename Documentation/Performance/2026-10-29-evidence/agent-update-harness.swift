// Agent update harness for the 2026-10-29 report. It ran as a temporary file in
// Tests/NotchShotKitTests and was removed afterwards; copy it back there to rerun:
//   AGENT_HARNESS=1 AGENT_OUT=<file> swift test --filter ZZAgentUpdateHarness
// Feeds synthetic agent records into a real island, offscreen, and measures the main
// thread in 50 ms slices after one update. Opens no socket and touches no AI Activity folder.

import AppKit
import Darwin
import SwiftUI
import Testing
@testable import NotchShotKit

@_silgen_name("thread_selfcounts")
private func thread_selfcounts(_ type: Int32, _ buffer: UnsafeMutableRawPointer, _ size: Int) -> Int32

@Suite("ZZ agent update harness", .serialized)
@MainActor
struct ZZAgentUpdateHarness {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENT_HARNESS"] == "1"))
    func agentUpdates() async throws {
        let coordinator = AppCoordinator()
        coordinator.rendersAsActiveDisplay = true
        let metrics = NotchMetrics(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            hasPhysicalNotch: true,
            notchSize: CGSize(width: 185, height: 32),
            menuBarHeight: 32
        )
        let context = NotchDisplayContext(displayID: 1, metrics: metrics, isPrimary: true, isBuiltIn: true)
        let size = CGSize(width: NotchLayout.maximumSize.width + NotchLayout.shadowPadding * 2,
                          height: NotchLayout.maximumSize.height + NotchLayout.shadowPadding)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: AnyView(NotchRootView(coordinator: coordinator, context: context)))
        hosting.sizingOptions = []
        hosting.frame = CGRect(origin: .zero, size: size)
        window.contentView = hosting

        func instructions() -> UInt64 {
            var counts: (UInt64, UInt64) = (0, 0)
            _ = withUnsafeMutableBytes(of: &counts) { thread_selfcounts(1, $0.baseAddress!, $0.count) }
            return counts.0
        }
        func render() {
            hosting.layoutSubtreeIfNeeded()
            hosting.display()
        }
        let started = Date().addingTimeInterval(-300)
        var tick = 0
        func agents() -> [AIActivitySnapshot] {
            (0 ..< 3).map { index in
                AIActivitySnapshot(
                    id: "agent-\(index)",
                    source: .codex,
                    state: .working,
                    title: "Session \(index)",
                    detail: "Step \(tick + index)",
                    progress: Double((tick + index) % 10) / 10,
                    workspace: "project-\(index)",
                    steps: [AIActivityStep(id: "s", label: "Step \(tick)", state: .working)],
                    startedAt: started,
                    updatedAt: Date()
                )
            }
        }
        func publish() {
            tick += 1
            coordinator.context.updateAI(
                AIActivityPolicy.contextSnapshot(from: agents(), now: Date(), mayInterruptMedia: true)
            )
            // The app's source observation would schedule this.
            coordinator.refreshActivity()
        }

        var visibleTick = 0
        var withProgress = false
        func agentsNow(visible: Bool) -> [AIActivitySnapshot] {
            if visible { visibleTick += 1 }
            return (0 ..< 3).map { index in
                AIActivitySnapshot(
                    id: "agent-\(index)",
                    source: .claude,
                    state: .working,
                    title: "Session \(index)",
                    detail: "Tool \(visibleTick + index)",
                    progress: withProgress ? Double(visibleTick % 10) / 10 : nil,
                    workspace: "project-\(index)",
                    startedAt: started,
                    updatedAt: Date()
                )
            }
        }
        func send(visible: Bool) {
            coordinator.context.updateAI(
                AIActivityPolicy.contextSnapshot(from: agentsNow(visible: visible), now: Date(), mayInterruptMedia: true)
            )
            coordinator.refreshActivity()
        }
        // One run-loop slice, as a display link would drive it on screen.
        func slice() async -> UInt64 {
            let i = instructions()
            render()
            try? await Task.sleep(for: .milliseconds(50))
            return instructions() - i
        }
        send(visible: true)
        for _ in 0 ..< 60 { _ = await slice() }
        var rows = ["activity: \(coordinator.activity)".prefix(160).description]
        for expanded in [false, true] {
            if expanded {
                coordinator.toggleExpanded()
                for _ in 0 ..< 60 { _ = await slice() }
            }
            for (label, visible, progress) in [("timestamp only", false, false), ("new tool text", true, false), ("new progress", true, true)] {
                withProgress = progress
                for round in 1 ... 3 {
                    var quiet: UInt64 = 0
                    for _ in 0 ..< 20 { quiet += await slice() }
                    send(visible: visible)
                    var after: [UInt64] = []
                    for _ in 0 ..< 40 { after.append(await slice()) }
                    let busySlices = after.firstIndex { $0 < 2 * (quiet / 20) + 500_000 } ?? after.count
                    rows.append(String(
                        format: "%@ %@ round %d: quiet %.2f M per 50 ms; after one update %.1f M over 2 s, busy for %d slices (%.0f ms); first slices %@",
                        expanded ? "expanded" : "compact ", label as NSString, round,
                        Double(quiet) / 20 / 1e6,
                        Double(after.reduce(0, +)) / 1e6, busySlices, Double(busySlices) * 50,
                        after.prefix(12).map { String(format: "%.1f", Double($0) / 1e6) }.joined(separator: " ")
                    ))
                }
            }
        }
        let out = ProcessInfo.processInfo.environment["AGENT_OUT"] ?? "/dev/stdout"
        try rows.joined(separator: "\n").appending("\n").write(toFile: out, atomically: false, encoding: .utf8)
        withExtendedLifetime(window) {}
    }
}
