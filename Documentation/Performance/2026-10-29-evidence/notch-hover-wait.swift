import AppKit

// Waits for the pointer to reach the notch: the top 60 pt of the screen with a
// camera housing (or the main screen when the lid is closed), 520 pt wide around
// its centre. Exits 0 when it does, 1 after the timeout in seconds ($1, default 900).
let timeout = Double(CommandLine.arguments.dropFirst().first ?? "900") ?? 900
let deadline = Date().addingTimeInterval(timeout)

func zone() -> CGRect? {
    guard let primary = NSScreen.screens.first else { return nil }
    let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? primary
    let f = screen.frame
    // CoreGraphics global space: origin at the primary screen's top-left, y down.
    let top = primary.frame.maxY - f.maxY
    return CGRect(x: f.midX - 260, y: top, width: 520, height: 60)
}

var area = zone()
var tick = 0
while Date() < deadline {
    tick += 1
    if tick % 50 == 0 { area = zone() }
    if let area, let point = CGEvent(source: nil)?.location, area.contains(point) {
        print("hover \(Int(point.x)),\(Int(point.y))")
        exit(0)
    }
    usleep(100_000)
}
exit(1)
