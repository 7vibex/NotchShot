// On-screen island probe for the 2026-10-29 report. Real NotchShot views in real,
// visible borderless windows (bottom-left, accessory app, never key), measured with
// the process's own rusage and WindowServer's CPU time from `ps`.
//
//   IslandProbe progress   idle / timestamp-only / percentage-change phases, compact island
//   IslandProbe rim        song line and playback meter, static vs animating
//   IslandProbe openclose  toggles the island open and closed every 1.5 s (for a hitch trace)
//   IslandProbe pacing     closed vs open/close: display-link gaps on the main thread, instructions per cycle
//   IslandProbe hold       opens the island and holds it, for a window screenshot
//   IslandProbe scroll     History (or PROBE_LIST=clipboard) in a visible window, scrolled 0, 8 and
//                          24 pt per display frame; read only, over the stores the app reads. The
//                          clipboard list needs `-notchshot.clipboardEnabled '<true/>'` after the
//                          other arguments, since the probe has its own preferences domain.
//   IslandProbe stall      opens and closes every 1.5 s while a background thread pings the main
//                          queue each millisecond; prints the longest wait after each open and close.
//                          Needs no visible window, so it also runs while the Mac is locked. Judge
//                          it by the opens: waits after a close ran 40-311 ms in every build tried.
//   IslandProbe soak       opens the island, steps through the capture menu, a full shelf and the
//                          agents page, back to the capture menu, and closes; seconds per step, then
//                          cycles. Prints footprint and instructions every 10 cycles. The five shelf
//                          captures are solid-colour PNGs in a temporary folder it removes at the end.
//   Every mode except `stall` shows its windows at the bottom left of the screen. Run them only
//   with the user's go-ahead: a locked, dark screen can be woken at any time. PROBE_OFFSCREEN=1
//   places them outside every display instead, for runs that don't need the screen (soak).
//   Arguments after the mode: seconds per phase, rounds.
//   PROBE_SCREEN=real lays the island out on this Mac's main screen and notch instead of a
//   14-inch one (1512 x 982 points, a 185 pt notch).
//
// Build: in a scratch copy of the package, put this file at Sources/IslandProbe/main.swift, add
// `.executableTarget(name: "IslandProbe", dependencies: ["NotchShotKit"], path: "Sources/IslandProbe",
// swiftSettings: [.swiftLanguageMode(.v5)])` and its product, then
// `swift build -c release -Xswiftc -enable-testing --product IslandProbe` and run it from .build/release.
// The fade variants in the report were env switches added to that copy's IslandGlassShell.swift only.
// The staged capture menu was compared as two binaries of this probe, one built with HEAD's
// NotchRootView.swift and IslandMotion.swift and one with the change's, run alternately.
//
// The coordinator is never started: no media poll, no socket, no monitors.
import AppKit
import Darwin
import SwiftUI
@testable import NotchShotKit

setvbuf(stdout, nil, _IOLBF, 0)

struct Usage {
    var instructions: UInt64 = 0
    var cpu: UInt64 = 0
    var wakeups: UInt64 = 0
    var energy: UInt64 = 0
    var footprint: UInt64 = 0
    var wall = Date()
    var windowServer = 0.0

    static func now() -> Usage {
        var info = rusage_info_v6()
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0)
            }
        }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Usage(
            instructions: info.ri_instructions,
            cpu: (info.ri_user_time + info.ri_system_time) * UInt64(timebase.numer) / UInt64(timebase.denom),
            wakeups: info.ri_interrupt_wkups,
            energy: info.ri_energy_nj,
            footprint: info.ri_phys_footprint,
            wall: Date()
        )
    }
}

/// WindowServer's accumulated CPU time in seconds, from `ps` (its rusage is root-only).
func windowServerSeconds() -> Double {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-o", "time=", "-p", "\(windowServerPID)"]
    let pipe = Pipe()
    task.standardOutput = pipe
    try? task.run()
    task.blockUntilExit()
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    // [hh:]mm:ss.cc
    var seconds = 0.0
    for part in text.split(separator: ":") { seconds = seconds * 60 + (Double(part) ?? 0) }
    return seconds
}

let windowServerPID: Int32 = {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    task.arguments = ["-x", "WindowServer"]
    let pipe = Pipe()
    task.standardOutput = pipe
    try? task.run()
    task.blockUntilExit()
    return Int32(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
}()

func report(_ label: String, _ a: Usage, _ b: Usage, visible: Bool) {
    let secs = b.wall.timeIntervalSince(a.wall)
    print(String(
        format: "%@ %.1f s visible=%@ | app %.2f M instr/s, %.2f%% core, %.1f wakeups/s, %.2f mJ/s, footprint %.1f MB | WindowServer %.2f%% core",
        label as NSString, secs, visible ? "yes" : "NO",
        Double(b.instructions - a.instructions) / secs / 1e6,
        Double(b.cpu - a.cpu) / 1e9 / secs * 100,
        Double(b.wakeups - a.wakeups) / secs,
        Double(b.energy - a.energy) / 1e6 / secs,
        Double(b.footprint) / 1_048_576,
        (b.windowServer - a.windowServer) / secs * 100
    ))
}

@MainActor
final class Probe {
    let mode: String
    let phaseSeconds: Double
    let rounds: Int
    var windows: [NSWindow] = []

    init(mode: String, phaseSeconds: Double, rounds: Int) {
        self.mode = mode
        self.phaseSeconds = phaseSeconds
        self.rounds = rounds
    }

    func window(size: CGSize, origin: CGPoint, content: NSView) -> NSWindow {
        var origin = origin
        // PROBE_OFFSCREEN=1 puts the window well outside every display, so
        // nothing shows on screen; the probe refuses to run if it would.
        let offscreen = ProcessInfo.processInfo.environment["PROBE_OFFSCREEN"] == "1"
        if offscreen {
            let union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
            origin = CGPoint(x: union.minX - 8000, y: union.minY - 8000)
        }
        let window = NSWindow(contentRect: CGRect(origin: origin, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        content.frame = CGRect(origin: .zero, size: size)
        window.contentView = content
        window.orderFrontRegardless()
        if offscreen {
            window.setFrameOrigin(origin)
            if NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) {
                print("window \(window.frame) would show on a display; stopping")
                exit(1)
            }
            print("off screen at \(window.frame)")
        }
        windows.append(window)
        return window
    }

    var allVisible: Bool { windows.allSatisfy { $0.occlusionState.contains(.visible) } }

    func measure(_ label: String, seconds: Double, during: (() -> Void)? = nil) async {
        var a = Usage.now()
        a.windowServer = windowServerSeconds()
        a = { var u = Usage.now(); u.windowServer = a.windowServer; return u }()
        let wasVisible = allVisible
        var timer: Timer?
        if let during {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { during() }
            }
        }
        try? await Task.sleep(for: .seconds(seconds))
        timer?.invalidate()
        var b = Usage.now()
        b.windowServer = windowServerSeconds()
        report(label, a, b, visible: wasVisible && allVisible)
    }

    // MARK: Island

    func makeIsland() -> AppCoordinator {
        let coordinator = AppCoordinator()
        coordinator.rendersAsActiveDisplay = true
        let metrics = ProcessInfo.processInfo.environment["PROBE_SCREEN"] == "real"
            ? NotchMetrics.metrics(for: NSScreen.screens[0])
            : NotchMetrics(
                screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                hasPhysicalNotch: true,
                notchSize: CGSize(width: 185, height: 32),
                menuBarHeight: 32
            )
        let context = NotchDisplayContext(displayID: 1, metrics: metrics, isPrimary: true, isBuiltIn: true)
        let size = CGSize(width: NotchLayout.maximumSize.width + NotchLayout.shadowPadding * 2,
                          height: NotchLayout.maximumSize.height + NotchLayout.shadowPadding)
        let hosting = NSHostingView(rootView: AnyView(NotchRootView(coordinator: coordinator, context: context)))
        hosting.sizingOptions = []
        _ = window(size: size, origin: CGPoint(x: 16, y: 16), content: hosting)
        return coordinator
    }

    let started = Date().addingTimeInterval(-300)
    var tick = 0

    func sendAgents(_ coordinator: AppCoordinator, advance: Bool) {
        if advance { tick += 1 }
        let agents = (0 ..< 3).map { index in
            AIActivitySnapshot(
                id: "agent-\(index)",
                source: .claude,
                state: .working,
                title: "Session \(index)",
                detail: "Editing files",
                progress: Double((tick + index) % 10) / 10 + 0.05,
                workspace: "project-\(index)",
                startedAt: started,
                updatedAt: Date()
            )
        }
        coordinator.context.updateAI(
            AIActivityPolicy.contextSnapshot(from: agents, now: Date(), mayInterruptMedia: true)
        )
        coordinator.refreshActivity()
    }

    func runProgress() async {
        let coordinator = makeIsland()
        sendAgents(coordinator, advance: true)
        try? await Task.sleep(for: .seconds(4))
        print("activity: \(String(describing: coordinator.activity).prefix(140)) visible=\(allVisible)")
        let phases: [(String, (() -> Void)?)] = [
            ("idle     ", nil),
            ("timestamp", { self.sendAgents(coordinator, advance: false) }),
            ("percent  ", { self.sendAgents(coordinator, advance: true) }),
        ]
        for round in 0 ..< rounds {
            for k in 0 ..< phases.count {
                let (label, action) = phases[(k + round) % phases.count]
                await measure("round \(round + 1) \(label)", seconds: phaseSeconds, during: action)
            }
        }
    }

    // MARK: Song line and meter

    struct RimMeter: View {
        var glides: Bool
        var bounces: Bool
        var body: some View {
            VStack(spacing: 8) {
                PlaybackIndicator(isPlaying: bounces, accentColor: .white, animates: true)
                LayerProgressRim(progress: 0.3, remaining: glides ? 200 : nil, inset: 10)
                    .frame(width: 240, height: 12)
            }
            .padding(12)
            .background(Color.black)
        }
    }

    func runRim() async {
        let hosting = NSHostingView(rootView: RimMeter(glides: false, bounces: false))
        hosting.sizingOptions = []
        _ = window(size: CGSize(width: 264, height: 60), origin: CGPoint(x: 16, y: 16), content: hosting)
        try? await Task.sleep(for: .seconds(3))
        let phases: [(String, Bool, Bool)] = [
            ("neither    ", false, false),
            ("line glides", true, false),
            ("meter only ", false, true),
            ("both       ", true, true),
        ]
        for round in 0 ..< rounds {
            for k in 0 ..< phases.count {
                let (label, glides, bounces) = phases[(k + round) % phases.count]
                hosting.rootView = RimMeter(glides: glides, bounces: bounces)
                try? await Task.sleep(for: .seconds(1))
                await measure("round \(round + 1) \(label)", seconds: phaseSeconds)
            }
        }
    }

    // MARK: Open and close

    func runOpenClose() async {
        let coordinator = makeIsland()
        sendAgents(coordinator, advance: true)
        print("pid \(getpid()) ready; toggling in 6 s")
        try? await Task.sleep(for: .seconds(6))
        await measure("closed, idle  ", seconds: 5)
        var a = Usage.now()
        a.windowServer = windowServerSeconds()
        let cycles = Int(phaseSeconds / 3)
        for _ in 0 ..< cycles {
            coordinator.toggleExpanded()
            try? await Task.sleep(for: .seconds(1.5))
            coordinator.toggleExpanded()
            try? await Task.sleep(for: .seconds(1.5))
        }
        var b = Usage.now()
        b.windowServer = windowServerSeconds()
        report("\(cycles) open/close cycles", a, b, visible: allVisible)
        print(String(format: "per cycle: %.1f M instructions", Double(b.instructions - a.instructions) / Double(cycles) / 1e6))
    }

    // MARK: Frame pacing

    /// Display-link callbacks on the main thread: a gap of more than 1.5 frames
    /// means the main thread missed a frame.
    final class FrameClock: NSObject {
        var stamps: [CFTimeInterval] = []
        @objc func tick(_ link: CADisplayLink) { stamps.append(link.timestamp) }
        func summary(_ label: String) {
            let gaps = zip(stamps.dropFirst(), stamps).map { ($0 - $1) * 1000 }
            guard let frame = gaps.sorted().dropFirst(gaps.count / 2).first else { return print("\(label): no frames") }
            let late = gaps.filter { $0 > frame * 1.5 }
            let missed = late.map { Int(($0 / frame).rounded()) - 1 }.reduce(0, +)
            print(String(format: "%@ %d frames at %.1f ms; %d late callbacks, %d frames missed, longest gap %.1f ms",
                         label as NSString, gaps.count, frame, late.count, missed, gaps.max() ?? 0))
        }
    }

    func runPacing() async {
        let coordinator = makeIsland()
        sendAgents(coordinator, advance: true)
        try? await Task.sleep(for: .seconds(3))
        for round in 1 ... rounds {
            for toggles in [false, true] {
                let clock = FrameClock()
                let link = windows[0].contentView!.displayLink(target: clock, selector: #selector(FrameClock.tick(_:)))
                link.add(to: .main, forMode: .common)
                let a = Usage.now()
                let cycles = Int(phaseSeconds / 3)
                for _ in 0 ..< cycles {
                    if toggles { coordinator.toggleExpanded() }
                    try? await Task.sleep(for: .seconds(1.5))
                    if toggles { coordinator.toggleExpanded() }
                    try? await Task.sleep(for: .seconds(1.5))
                }
                let b = Usage.now()
                link.invalidate()
                let label = "round \(round) \(toggles ? "open/close" : "closed    ")"
                clock.summary(label)
                print(String(format: "%@ %.1f M instructions per 3 s cycle, visible=%@", label as NSString,
                             Double(b.instructions - a.instructions) / Double(cycles) / 1e6, allVisible ? "yes" : "NO"))
            }
        }
    }

    // MARK: Repeated use

    /// Many opens, each visiting every page the probe can fill: the capture
    /// menu, a full shelf, the agents page and the capture menu again, then
    /// closed. Retained growth shows as footprint that keeps rising after the
    /// first cycles.
    func runSoak() async {
        let coordinator = makeIsland()
        sendAgents(coordinator, advance: true)
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("IslandProbeSoak-\(getpid())")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for index in 0 ..< AppCoordinator.maximumShelfItems {
            let url = folder.appendingPathComponent("capture-\(index).png")
            let image = NSImage(size: CGSize(width: 640, height: 400), flipped: false) { rect in
                NSColor(calibratedHue: Double(index) / 5, saturation: 0.6, brightness: 0.8, alpha: 1).setFill()
                rect.fill()
                return true
            }
            if let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: url)
            }
            let asset = CaptureAsset(url: url, kind: .screenshot, pixelSize: CGSize(width: 640, height: 400))
            coordinator.push(ShelfItem(asset: asset, thumbnail: image, image: nil))
        }
        coordinator.hideShelf()
        try? await Task.sleep(for: .seconds(3))
        print("shelf \(coordinator.shelfItems.count) items, available \(coordinator.isTabAvailable(.shelf)); "
            + "agents available \(coordinator.isTabAvailable(.agents)); visible=\(allVisible)")
        let steps: [(String, () -> Void)] = [
            ("capture", { coordinator.toggleExpanded() }),
            ("shelf  ", { coordinator.showTab(.shelf) }),
            ("agents ", { coordinator.showTab(.agents) }),
            ("capture", { coordinator.showTab(.capture) }),
            ("closed ", { coordinator.toggleExpanded() }),
        ]
        var last = Usage.now()
        var lastCycle = 0
        print(String(format: "cycle 0 footprint %.1f MB", Double(last.footprint) / 1_048_576))
        for cycle in 1 ... rounds {
            for (name, step) in steps {
                step()
                if cycle == 1 { print("  \(name) \(String(describing: coordinator.activity).prefix(110))") }
                try? await Task.sleep(for: .seconds(phaseSeconds))
            }
            sendAgents(coordinator, advance: true)
            if cycle == 1 || cycle % 10 == 0 {
                let now = Usage.now()
                print(String(format: "cycle %d footprint %.1f MB, %.1f M instructions per cycle, visible=%@",
                             cycle, Double(now.footprint) / 1_048_576,
                             Double(now.instructions - last.instructions) / Double(cycle - lastCycle) / 1e6,
                             allVisible ? "yes" : "NO"))
                last = now
                lastCycle = cycle
            }
        }
    }

    // MARK: Scrolling

    func findTableScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView, scrollView.documentView is NSTableView { return scrollView }
        for subview in view.subviews {
            if let found = findTableScrollView(in: subview) { return found }
        }
        return nil
    }

    /// Moves the list by `stride` points at each display-link callback, down
    /// to the end and back up, and keeps the callbacks' timestamps.
    final class Scroller: NSObject {
        let clock = FrameClock()
        let scrollView: NSScrollView
        let maxY: Double
        let stride: Double
        var direction = 1.0
        var travelled = 0.0
        init(scrollView: NSScrollView, maxY: Double, stride: Double) {
            self.scrollView = scrollView
            self.maxY = maxY
            self.stride = stride
        }
        @objc func tick(_ link: CADisplayLink) {
            clock.tick(link)
            guard stride > 0, maxY > 0 else { return }
            let clip = scrollView.contentView
            var y = clip.bounds.origin.y + stride * direction
            if y >= maxY { y = maxY; direction = -1 }
            if y <= 0 { y = 0; direction = 1 }
            travelled += abs(y - clip.bounds.origin.y)
            clip.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(clip)
        }
    }

    /// History or the clipboard list (PROBE_LIST), over the stores the app
    /// reads. The coordinator is never started, so nothing is saved, indexed
    /// or pruned. A titled window, as the app's own, never key.
    func runScroll() async {
        let coordinator = AppCoordinator()
        let which = ProcessInfo.processInfo.environment["PROBE_LIST"] ?? "history"
        let root = which == "clipboard"
            ? AnyView(ClipboardView(coordinator: coordinator))
            : AnyView(HistoryView(coordinator: coordinator))
        let hosting = NSHostingView(rootView: root)
        let size = CGSize(width: 860, height: 540)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 16, y: 16), size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.contentView = hosting
        window.orderFrontRegardless()
        windows.append(window)
        try? await Task.sleep(for: .seconds(4))
        guard let scrollView = findTableScrollView(in: hosting),
              let table = scrollView.documentView as? NSTableView else { return print("no list found") }
        let maxY = max(0, table.frame.height - scrollView.contentView.bounds.height)
        print("\(which): \(table.numberOfRows) rows, \(Int(table.frame.height)) pt tall, visible=\(allVisible), footprint \(String(format: "%.1f", Double(Usage.now().footprint) / 1_048_576)) MB")
        for round in 1 ... rounds {
            for stride in [0.0, 8.0, 24.0] {
                let scroller = Scroller(scrollView: scrollView, maxY: maxY, stride: stride)
                let link = hosting.displayLink(target: scroller, selector: #selector(Scroller.tick(_:)))
                link.add(to: .main, forMode: .common)
                var a = Usage.now()
                a.windowServer = windowServerSeconds()
                a = { var u = Usage.now(); u.windowServer = a.windowServer; return u }()
                try? await Task.sleep(for: .seconds(phaseSeconds))
                var b = Usage.now()
                b.windowServer = windowServerSeconds()
                link.invalidate()
                let label = String(format: "round %d %@ %2.0f pt/frame", round, which as NSString, stride)
                scroller.clock.summary(label)
                report(label + String(format: " travelled %.0f pt", scroller.travelled), a, b, visible: allVisible)
            }
        }
    }


    // MARK: Main-thread stalls

    /// Pings the main queue from a background thread every millisecond and
    /// keeps every wait over 4 ms. Needs no visible window, so it also works
    /// while the Mac is locked or the display sleeps.
    final class StallWatch: @unchecked Sendable {
        private let lock = NSLock()
        private var stalls: [(at: CFTimeInterval, ms: Double)] = []
        private var stopped = false
        func start() {
            Thread.detachNewThread { [self] in
                while true {
                    lock.lock(); let done = stopped; lock.unlock()
                    if done { return }
                    let t0 = CACurrentMediaTime()
                    DispatchQueue.main.sync {}
                    let ms = (CACurrentMediaTime() - t0) * 1000
                    if ms > 4 { lock.lock(); stalls.append((t0, ms)); lock.unlock() }
                    usleep(1000)
                }
            }
        }
        func stop() -> [(at: CFTimeInterval, ms: Double)] {
            lock.lock(); stopped = true; let s = stalls; lock.unlock(); return s
        }
    }

    func runStall() async {
        let coordinator = makeIsland()
        sendAgents(coordinator, advance: true)
        try? await Task.sleep(for: .seconds(3))
        for round in 1 ... rounds {
            let watch = StallWatch()
            watch.start()
            var opens: [CFTimeInterval] = [], closes: [CFTimeInterval] = []
            let a = Usage.now()
            let cycles = Int(phaseSeconds / 3)
            for _ in 0 ..< cycles {
                opens.append(CACurrentMediaTime()); coordinator.toggleExpanded()
                try? await Task.sleep(for: .seconds(1.5))
                closes.append(CACurrentMediaTime()); coordinator.toggleExpanded()
                try? await Task.sleep(for: .seconds(1.5))
            }
            let b = Usage.now()
            let stalls = watch.stop()
            func worst(after times: [CFTimeInterval]) -> [Double] {
                times.map { t in stalls.filter { $0.at >= t - 0.002 && $0.at < t + 0.4 }.map(\.ms).max() ?? 0 }
            }
            func line(_ label: String, _ values: [Double]) -> String {
                let sorted = values.sorted()
                let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
                return String(format: "%@ longest wait per toggle: median %.1f ms, max %.1f ms, over 16.7 ms in %d of %d",
                              label as NSString, median, sorted.last ?? 0, values.filter { $0 > 16.7 }.count, values.count)
            }
            print("round \(round) " + line("open ", worst(after: opens)))
            print("round \(round) " + line("close", worst(after: closes)))
            print(String(format: "round %d %.1f M instructions per cycle, visible=%@", round,
                         Double(b.instructions - a.instructions) / Double(cycles) / 1e6, allVisible ? "yes" : "NO"))
        }
    }

    func run() async {
        switch mode {
        case "progress": await runProgress()
        case "rim": await runRim()
        case "openclose": await runOpenClose()
        case "pacing": await runPacing()
        case "stall": await runStall()
        case "scroll": await runScroll()
        case "soak": await runSoak()
        case "hold":
            let coordinator = makeIsland()
            sendAgents(coordinator, advance: true)
            try? await Task.sleep(for: .seconds(2))
            coordinator.toggleExpanded()
            print("expanded; holding")
            try? await Task.sleep(for: .seconds(phaseSeconds))
        default: print("unknown mode \(mode)")
        }
    }
}

let arguments = CommandLine.arguments
let mode = arguments.count > 1 ? arguments[1] : "progress"
let phaseSeconds = arguments.count > 2 ? Double(arguments[2]) ?? 15 : 15
let rounds = arguments.count > 3 ? Int(arguments[3]) ?? 3 : 3
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
MainActor.assumeIsolated {
    let probe = Probe(mode: mode, phaseSeconds: phaseSeconds, rounds: rounds)
    Task { @MainActor in
        await probe.run()
        exit(0)
    }
}
app.run()
