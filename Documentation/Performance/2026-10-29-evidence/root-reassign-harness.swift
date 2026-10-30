// Root-view reassignment harness for the 2026-10-29 report. It ran as a temporary
// file in Tests/NotchShotKitTests and was removed afterwards; copy it back there to rerun:
//   ROOTREASSIGN_HARNESS=1 ROOTREASSIGN_OUT=<file> swift test --filter ZZRootReassignHarness
// Measures what unlock's rebuildPanels costs for an existing panel (rootView reassigned
// with the same context), against a no-op render and a fresh hosting view.

import AppKit
import Darwin
import SwiftUI
import Testing
@testable import NotchShotKit

@_silgen_name("thread_selfcounts")
private func thread_selfcounts(_ type: Int32, _ buffer: UnsafeMutableRawPointer, _ size: Int) -> Int32

@Suite("ZZ root reassign harness", .serialized)
@MainActor
struct ZZRootReassignHarness {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ROOTREASSIGN_HARNESS"] == "1"))
    func reassign() async throws {
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
        func content() -> AnyView { AnyView(NotchRootView(coordinator: coordinator, context: context)) }
        func makeHost() -> (NSWindow, NSHostingView<AnyView>) {
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: content())
            hosting.sizingOptions = []
            hosting.frame = CGRect(origin: .zero, size: size)
            window.contentView = hosting
            return (window, hosting)
        }
        func instructions() -> UInt64 {
            var counts: (UInt64, UInt64) = (0, 0)
            _ = withUnsafeMutableBytes(of: &counts) { thread_selfcounts(1, $0.baseAddress!, $0.count) }
            return counts.0
        }
        func render(_ hosting: NSHostingView<AnyView>) {
            hosting.layoutSubtreeIfNeeded()
            hosting.display()
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(20)) }

        let (window, hosting) = makeHost()
        for _ in 0 ..< 10 { render(hosting); await settle() }

        var rows: [String] = []
        let n = Int(ProcessInfo.processInfo.environment["ROOTREASSIGN_N"] ?? "50") ?? 50
        for round in 1 ... 3 {
            var control: UInt64 = 0, reassign: UInt64 = 0, controlNs: UInt64 = 0, reassignNs: UInt64 = 0
            for _ in 0 ..< n {
                var i = instructions(); var t = DispatchTime.now().uptimeNanoseconds
                render(hosting)
                control += instructions() - i; controlNs += DispatchTime.now().uptimeNanoseconds - t
                await settle()
                i = instructions(); t = DispatchTime.now().uptimeNanoseconds
                hosting.rootView = content()
                render(hosting)
                reassign += instructions() - i; reassignNs += DispatchTime.now().uptimeNanoseconds - t
                await settle()
            }
            var fresh: UInt64 = 0, freshNs: UInt64 = 0
            for _ in 0 ..< 5 {
                try autoreleasepool {
                    let i = instructions(); let t = DispatchTime.now().uptimeNanoseconds
                    let (w, h) = makeHost()
                    render(h)
                    fresh += instructions() - i; freshNs += DispatchTime.now().uptimeNanoseconds - t
                    w.contentView = nil
                    w.close()
                    _ = try #require(Optional(w))
                }
                await settle()
            }
            rows.append(String(
                format: "round %d: no-op render %.2f M instr %.3f ms | reassign + render %.2f M instr %.3f ms | fresh host + first render %.1f M instr %.2f ms",
                round,
                Double(control) / Double(n) / 1e6, Double(controlNs) / Double(n) / 1e6,
                Double(reassign) / Double(n) / 1e6, Double(reassignNs) / Double(n) / 1e6,
                Double(fresh) / 5 / 1e6, Double(freshNs) / 5 / 1e6
            ))
        }
        let out = ProcessInfo.processInfo.environment["ROOTREASSIGN_OUT"] ?? "/dev/stdout"
        try rows.joined(separator: "\n").appending("\n").write(toFile: out, atomically: false, encoding: .utf8)
        withExtendedLifetime(window) {}
    }
}
