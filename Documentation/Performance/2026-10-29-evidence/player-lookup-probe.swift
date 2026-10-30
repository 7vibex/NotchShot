// Player lookup A/B for the 2026-10-29 report: the old full running-app enumeration
// against asking for the two players by bundle identifier, alternating every 2 s as the
// Apple Events poll does. Build with swiftc -O; pass the number of rounds.

import AppKit
@_silgen_name("thread_selfcounts")
func thread_selfcounts(_ type: Int32, _ buffer: UnsafeMutableRawPointer, _ size: Int) -> Int32
func instructions() -> UInt64 { var c: (UInt64, UInt64) = (0, 0); _ = withUnsafeMutableBytes(of: &c) { thread_selfcounts(1, $0.baseAddress!, $0.count) }; return c.0 }
let players = ["com.spotify.client", "com.apple.Music"]
// The app today: every running app's bundle identifier, then a contains check.
func today() -> [String] {
    let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
    return players.filter { running.contains($0) }
}
// Ask for the two players by identifier.
func byIdentifier() -> [String] {
    players.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
}
_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)
let rounds = Int(CommandLine.arguments[1])!
var samples: [String: [(Double, Double)]] = ["today": [], "byid": []]
var mismatches = 0
for round in 0 ..< rounds {
    for mode in (round % 2 == 0 ? ["today", "byid"] : ["byid", "today"]) {
        let i = instructions(); let t = DispatchTime.now().uptimeNanoseconds
        let result = mode == "today" ? today() : byIdentifier()
        samples[mode]!.append((Double(instructions() - i) / 1e6, Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6))
        if result != (mode == "today" ? byIdentifier() : today()) { mismatches += 1 }
        RunLoop.main.run(until: Date().addingTimeInterval(2))
    }
}
for mode in ["today", "byid"] {
    let rows = samples[mode]!.dropFirst()
    let k = rows.map(\.0).sorted(), ms = rows.map(\.1).sorted()
    print(String(format: "%@: n=%d, instructions median %.2f M (range %.2f-%.2f), time median %.2f ms (range %.2f-%.2f)", mode, rows.count, k[k.count / 2], k.first!, k.last!, ms[ms.count / 2], ms.first!, ms.last!))
}
print("result mismatches between the two lookups:", mismatches)
