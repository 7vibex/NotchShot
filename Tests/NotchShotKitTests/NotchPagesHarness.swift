import AppKit
import SwiftUI
import Testing
@testable import NotchShotKit

/// Temporary: renders the whole notch in each state to PNG. Not committed.
@MainActor
@Suite("Notch pages render harness")
struct NotchPagesHarness {
    @Test("render pages")
    func render() async throws {
        guard let out = ProcessInfo.processInfo.environment["PAGES_OUT"] else { return }
        let coordinator = AppCoordinator()
        coordinator.rendersAsActiveDisplay = true
        let metrics = NotchMetrics(
            screenFrame: CGRect(x: 0, y: 0, width: 1470, height: 956),
            hasPhysicalNotch: true,
            notchSize: CGSize(width: 185, height: 32),
            menuBarHeight: 37
        )
        let context = NotchDisplayContext(displayID: 1, metrics: metrics, isPrimary: true, isBuiltIn: true)

        let states: [(String, NotchActivity)] = [
            ("01-capture-menu", .expanded),
            ("02-volume", .systemLevel(SystemLevel(kind: .volume, value: 0.62, isMuted: false))),
            ("03-brightness", .systemLevel(SystemLevel(kind: .brightness, value: 0.35, isMuted: false))),
            ("04-countdown", .countdown(remaining: 3, intent: .area)),
            ("05-recording", .recording),
            ("06-processing", .processing("Saving recording")),
            ("07-error", .error("Couldn't save the capture: the disk is full")),
            ("08-notification", .systemNotification(SystemNotificationSnapshot(
                sourceName: "Messages", title: "Mia Chen", body: "Are we still on for 6? I booked the table."
            ))),
            ("09-power", .context(ContextSnapshot(
                kind: .power, title: "Charging", subtitle: "Full in 1 h 20 min", metric: "64%", accentHex: "#30D158", presentation: .expanded
            ))),
            ("10-calendar", .context(ContextSnapshot(
                kind: .calendar, title: "Design review", subtitle: "In 5 min · Room 4", accentHex: "#FF9F0A", presentation: .expanded
            ))),
            ("11-network", .context(ContextSnapshot(
                kind: .network, title: "Offline", subtitle: "Wi-Fi disconnected", accentHex: "#FF453A", presentation: .expanded
            ))),
            ("12-audio-route", .context(ContextSnapshot(
                kind: .audioRoute, title: "AirPods Pro", subtitle: "Connected", accentHex: "#0A84FF", presentation: .expanded
            ))),
            ("13-file-drop", .fileDrop),
            ("14-result", .result),
        ]
        for (name, activity) in states {
            coordinator.activity = activity
            try await snap(NotchRootView(coordinator: coordinator, context: context), name: name, out: out)
        }
    }

    private func snap(_ view: some View, name: String, out: String) async throws {
        let size = CGSize(width: 820, height: 380)
        let root = view
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(LinearGradient(
                colors: [Color(red: 0.16, green: 0.22, blue: 0.42), Color(red: 0.55, green: 0.42, blue: 0.62)],
                startPoint: .top, endPoint: .bottom
            ))
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: size.width, height: size.height), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(900))
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: out).appendingPathComponent(name + ".png"))
        window.orderOut(nil)
    }
}
