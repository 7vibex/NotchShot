// Scroll harness used for the 2026-10-29 report. It ran as a temporary file in
// Tests/NotchShotKitTests and was removed afterwards; copy it back there to rerun:
//   SCROLL_HARNESS=1 SCROLL_OUT=<file> swift test --filter ZZScrollHarness
//
// Hosts the real HistoryView and ClipboardView, over the shared stores the app
// itself reads, in titled windows that are never ordered in. Read only: the
// coordinator is never started, so retention, indexing and saving don't run.
// Each frame scrolls the list by `stride` points, then lays out, displays and
// flushes Core Animation. The main run loop then spins for the rest of an
// 8.33 ms frame so thumbnail loads land as they would. A run loop observer
// records every busy stretch on the main thread. Only numbers are written out.

import AppKit
import Darwin
import QuartzCore
import SwiftUI
import Testing
@testable import NotchShotKit

@_silgen_name("thread_selfcounts")
private func thread_selfcounts(_ type: Int32, _ buffer: UnsafeMutableRawPointer, _ size: Int) -> Int32

@Suite("ZZ scroll harness", .serialized)
@MainActor
struct ZZScrollHarness {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SCROLL_HARNESS"] == "1"))
    func scrollLists() throws {
        _ = NSApplication.shared
        let coordinator = AppCoordinator()
        var report: [String: Any] = [
            "history_rows": coordinator.history.entries.count,
            "clipboard_rows": coordinator.clipboard.entries.count,
        ]
        for stride in [40.0, 120.0] {
            for (name, view) in [
                ("history", AnyView(HistoryView(coordinator: coordinator))),
                ("clipboard", AnyView(ClipboardView(coordinator: coordinator))),
            ] {
                var result: [String: Any] = [:]
                try autoreleasepool {
                    result = try Self.measure(view, size: CGSize(width: 860, height: 540), stride: stride)
                }
                result["live_heap_mb_after_close"] = Self.liveHeapMB()
                result["window_freed_after_close"] = Self.lastWindow == nil
                report["\(name)_stride_\(Int(stride))"] = result
            }
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if let path = ProcessInfo.processInfo.environment["SCROLL_OUT"] {
            try data.write(to: URL(fileURLWithPath: path))
        }
        print(String(decoding: data, as: UTF8.self))
    }

    private static let frame = 1.0 / 120.0
    private static weak var lastWindow: NSWindow?

    private static func measure(_ view: AnyView, size: CGSize, stride: Double) throws -> [String: Any] {
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        lastWindow = window
        window.contentView = NSHostingView(rootView: view)
        window.layoutIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        spin(1.0)

        let scrollView = try #require(findTableScrollView(in: window.contentView!), "no List scroll view")
        let table = try #require(scrollView.documentView as? NSTableView)
        let clip = scrollView.contentView
        let maxY = max(0, table.frame.height - clip.bounds.height)
        let heapBefore = liveHeapMB()

        // Control: the same frames without moving the list.
        let control = run(frames: 60, scrollView: scrollView, window: window) { _ in clip.bounds.origin.y }

        // Down to the end and back up, twice.
        var targets: [Double] = []
        for _ in 0 ..< 2 {
            var y = 0.0
            while y < maxY { y = min(maxY, y + stride); targets.append(y) }
            while y > 0 { y = max(0, y - stride); targets.append(y) }
        }
        let scrolled = run(frames: targets.count, scrollView: scrollView, window: window) { targets[$0] }
        let heapAfter = liveHeapMB()
        window.close()
        return [
            "rows": table.numberOfRows,
            "content_height": table.frame.height,
            "stride_pt": stride,
            "control": control,
            "scrolling": scrolled,
            "live_heap_mb_before": heapBefore,
            "live_heap_mb_after": heapAfter,
        ]
    }

    private static func run(
        frames: Int, scrollView: NSScrollView, window: NSWindow, target: (Int) -> Double
    ) -> [String: Any] {
        var steps: [Double] = []
        var worstPerFrame: [Double] = []
        let watch = BusyWatch()
        let mainBefore = mainThreadCounts(), cpuBefore = mainThreadCPU(), processBefore = processInstructions()
        for index in 0 ..< frames {
            let start = CACurrentMediaTime()
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: target(index)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            window.layoutIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            let step = CACurrentMediaTime() - start
            steps.append(step * 1000)
            watch.reset()
            spin(max(0, frame - step))
            worstPerFrame.append(max(step, watch.longest) * 1000)
        }
        watch.stop()
        let mainAfter = mainThreadCounts(), cpuAfter = mainThreadCPU()
        spin(1.0) // let decodes still in flight finish before the process count
        let processAfter = processInstructions()
        return summary(steps, prefix: "step").merging(summary(worstPerFrame, prefix: "frame")) { $1 }
            .merging([
                "frames": frames,
                "main_instructions_m": Double(mainAfter.instructions - mainBefore.instructions) / 1e6,
                "main_cycles_m": Double(mainAfter.cycles - mainBefore.cycles) / 1e6,
                "main_cpu_ms": (cpuAfter - cpuBefore) * 1000,
                "process_instructions_m": Double(processAfter - processBefore) / 1e6,
            ]) { $1 }
    }

    private static func summary(_ values: [Double], prefix: String) -> [String: Any] {
        let sorted = values.sorted()
        func percentile(_ p: Double) -> Double {
            sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
        }
        return [
            "\(prefix)_median_ms": percentile(0.5),
            "\(prefix)_p95_ms": percentile(0.95),
            "\(prefix)_p99_ms": percentile(0.99),
            "\(prefix)_max_ms": sorted.last ?? 0,
            "\(prefix)_over_8_3ms": values.filter { $0 > 8.33 }.count,
            "\(prefix)_over_16_7ms": values.filter { $0 > 16.7 }.count,
        ]
    }

    /// Instructions and cycles retired by the calling thread.
    private static func mainThreadCounts() -> (instructions: UInt64, cycles: UInt64) {
        var counts: (UInt64, UInt64) = (0, 0)
        _ = withUnsafeMutableBytes(of: &counts) { thread_selfcounts(1, $0.baseAddress!, $0.count) }
        return (counts.0, counts.1)
    }

    private static func mainThreadCPU() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1e9
    }

    private static func processInstructions() -> UInt64 {
        var info = rusage_info_v6()
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) }
        }
        return info.ri_instructions
    }

    private static func spin(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static func findTableScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView, scrollView.documentView is NSTableView { return scrollView }
        for subview in view.subviews {
            if let found = findTableScrollView(in: subview) { return found }
        }
        return nil
    }

    private static func liveHeapMB() -> Double {
        spin(0.3)
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        return Double(statistics.size_in_use) / 1_048_576
    }
}

/// The longest stretch the main run loop spent between waking and sleeping.
@MainActor
private final class BusyWatch {
    private var observer: CFRunLoopObserver?
    private var wokeAt: CFTimeInterval?
    private(set) var longest: Double = 0

    init() {
        observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0
        ) { [weak self] _, activity in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = CACurrentMediaTime()
                if activity == .afterWaiting {
                    self.wokeAt = now
                } else if let wokeAt = self.wokeAt {
                    self.longest = max(self.longest, now - wokeAt)
                    self.wokeAt = nil
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    func reset() { longest = 0; wokeAt = nil }

    func stop() {
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
    }
}
