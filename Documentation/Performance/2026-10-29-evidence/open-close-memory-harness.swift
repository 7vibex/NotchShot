// Open/close memory harness used for the 2026-10-29 report. It ran as a
// temporary file in Tests/NotchShotKitTests and was removed afterwards; copy it
// back there to rerun:
//   OPENCLOSE_HARNESS=1 OPENCLOSE_CYCLES=100 OPENCLOSE_OUT=<file> swift test --filter ZZOpenCloseMemoryHarness

import AppKit
import Darwin
import SwiftUI
import Testing
@testable import NotchShotKit

// Temporary measurement harness, not part of the suite: OPENCLOSE_HARNESS=1.
@Suite("ZZ open/close memory harness", .serialized)
@MainActor
struct ZZOpenCloseMemoryHarness {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENCLOSE_HARNESS"] == "1"))
    func openCloseCycles() async throws {
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
        let hosting = NSHostingView(rootView: NotchRootView(coordinator: coordinator, context: context))
        hosting.sizingOptions = []
        hosting.frame = CGRect(origin: .zero, size: size)
        window.contentView = hosting
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))

        var changeNs: UInt64 = 0, layoutNs: UInt64 = 0, drawNs: UInt64 = 0, renders: UInt64 = 0
        func render() async {
            try? await Task.sleep(for: .milliseconds(4))
            let a = DispatchTime.now().uptimeNanoseconds
            hosting.layoutSubtreeIfNeeded()
            let b = DispatchTime.now().uptimeNanoseconds
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let c = DispatchTime.now().uptimeNanoseconds
            layoutNs += b - a; drawNs += c - b; renders += 1
        }
        func timed(_ body: () -> Void) {
            let a = DispatchTime.now().uptimeNanoseconds
            body()
            changeNs += DispatchTime.now().uptimeNanoseconds - a
        }
        func cycle() async {
            timed { coordinator.toggleExpanded() }
            await render()
            timed { coordinator.toggleExpanded() }
            await render()
            timed { coordinator.setHovering(true) }
            await render()
            timed { coordinator.setHovering(false) }
            await render()
        }
        func liveBytes() -> Double {
            var stats = malloc_statistics_t()
            malloc_zone_statistics(nil, &stats)
            return Double(stats.size_in_use) / 1_048_576
        }
        func footprint() -> Double {
            var info = rusage_info_v6()
            _ = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) }
            }
            return Double(info.ri_phys_footprint) / 1_048_576
        }

        for _ in 0 ..< 20 { await cycle() }
        try? await Task.sleep(for: .milliseconds(300))
        var rows: [String] = []
        changeNs = 0; layoutNs = 0; drawNs = 0; renders = 0
        let cycles = Int(ProcessInfo.processInfo.environment["OPENCLOSE_CYCLES"] ?? "100") ?? 100
        let base = liveBytes()
        rows.append(String(format: "after warm-up: live %.2f MB, footprint %.1f MB", base, footprint()))
        let started = DispatchTime.now().uptimeNanoseconds
        for block in 1 ... 4 {
            for _ in 0 ..< cycles { await cycle() }
            try? await Task.sleep(for: .milliseconds(300))
            rows.append(String(format: "after %d cycles: live %.2f MB (%+.3f), footprint %.1f MB",
                               block * cycles, liveBytes(), liveBytes() - base, footprint()))
        }
        let perCycle = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6 / Double(4 * cycles)
        rows.append(String(format: "%.2f ms per cycle (4 state changes, each rendered)", perCycle))
        let n = Double(max(renders, 1))
        rows.append(String(format: "per state: change %.3f ms, layout %.3f ms, cacheDisplay %.3f ms (n=%d)",
                           Double(changeNs) / 1e6 / n, Double(layoutNs) / 1e6 / n, Double(drawNs) / 1e6 / n, renders))
        rows.append("activity at end: \(coordinator.activity)")
        let out = ProcessInfo.processInfo.environment["OPENCLOSE_OUT"] ?? "/dev/stdout"
        try rows.joined(separator: "\n").appending("\n").write(toFile: out, atomically: false, encoding: .utf8)
        withExtendedLifetime(window) {}
    }
}
