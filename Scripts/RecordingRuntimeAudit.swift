// Compile against the debug package with @testable access; never shipped in the app.
import AppKit
import AVFoundation
import Foundation
import QuartzCore
@testable import NotchShotKit

@MainActor
func runAudit() async -> Int32 {
    do {
        guard CommandLine.arguments.count == 4,
              ["capture", "recover"].contains(CommandLine.arguments[1]),
              let duration = Double(CommandLine.arguments[3]), duration >= 1, duration <= 7_200 else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        let mode = CommandLine.arguments[1]
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true).resolvingSymlinksInPath()
        let scratch = root.appendingPathComponent("InProgress", isDirectory: true)
        func write(_ value: [String: Any], _ name: String) throws {
            try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent(name), options: .atomic)
        }
        if mode == "recover" {
            let files = try FileManager.default.contentsOfDirectory(at: scratch, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "mp4" }
            guard files.count == 1, let source = files.first else { throw CocoaError(.fileReadUnknown) }
            let destination = root.appendingPathComponent("recovered.mp4")
            let asset = try await RecordingService().recover(source, inProgress: scratch, destination: { destination })
            try write(["duration": asset.duration ?? 0, "playable": try await AVURLAsset(url: asset.url).load(.isPlayable),
                       "destination": asset.url.path], "recovery.json")
            return 0
        }
        func desktopAvailable() -> Bool {
            guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
                  session[kCGSessionOnConsoleKey as String] as? Bool == true else { return false }
            return session["CGSSessionScreenIsLocked"] as? Bool != true
        }
        guard desktopAvailable() else {
            print("BLOCKED: desktop is locked or unavailable; unlock it before the capture control")
            return 3
        }
        guard CGPreflightScreenCaptureAccess() else {
            print("BLOCKED: this signed process has no Screen Recording grant")
            return 2
        }
        // The controller creates a unique owner-only root. Refuse reused scratch data.
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1280, height: 720),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "NotchShot isolated recording audit"
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.darkGray.cgColor
        let label = CATextLayer()
        label.frame = CGRect(x: 40, y: 550, width: 1180, height: 90)
        label.string = "ISOLATED SCREENCAPTUREKIT AUDIT"
        label.fontSize = 38
        label.foregroundColor = NSColor.white.cgColor
        view.layer?.addSublayer(label)
        let marker = CALayer()
        marker.frame = CGRect(x: 500, y: 250, width: 220, height: 220)
        marker.backgroundColor = NSColor.systemCyan.cgColor
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = 2 * Double.pi
        animation.duration = 2
        animation.repeatCount = .infinity
        marker.add(animation, forKey: "audit-motion")
        view.layer?.addSublayer(marker)
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.close() }
        try await Task.sleep(for: .seconds(1))
        func fixtureState() -> [String: Any] {
            ["windowVisible": window.isVisible,
             "windowOccluded": !window.occlusionState.contains(.visible),
             "applicationActive": NSApplication.shared.isActive,
             "applicationHidden": NSApplication.shared.isHidden,
             "windowKey": window.isKeyWindow,
             "windowMiniaturized": window.isMiniaturized,
             "windowOnActiveSpace": window.isOnActiveSpace,
             "animationInstalled": marker.animation(forKey: "audit-motion") != nil,
             "markerAttached": marker.superlayer != nil && marker.superlayer === view.layer]
        }
        let service = RecordingService()
        try await service.start(RecordingConfiguration(target: .window(CGWindowID(window.windowNumber)),
                                                       audioSources: [], resolution: .p720,
                                                       framesPerSecond: 30, showsCursor: false),
                                inProgress: scratch, prepareDirectory: { true })
        try write(["pid": ProcessInfo.processInfo.processIdentifier, "window": window.windowNumber,
                   "duration": duration, "startedAt": Date().timeIntervalSince1970,
                   "fixture": fixtureState()], "ready.json")
        for second in 1...Int(duration) {
            try await Task.sleep(for: .seconds(1))
            if second % 10 == 0 {
                try write(["elapsed": service.status.elapsed, "bytes": service.status.fileSizeBytes,
                           "recording": service.isRecording, "capacity": AppPaths.availableCapacity(at: root),
                           "fixture": fixtureState()],
                          "progress.json")
            }
            guard service.isRecording else { throw CocoaError(.fileWriteUnknown) }
        }
        let asset = try await service.stop(destination: root.appendingPathComponent("completed.mp4"))
        // The controller polls session state out of process during capture, so
        // this frame producer does not gain another synchronous main-thread poll.
        guard desktopAvailable() else {
            try write(["reason": "Desktop unavailable at completion; isolated movie retained"], "invalid-fixture.json")
            print("BLOCKED: desktop became unavailable; control invalid, isolated movie retained")
            return 3
        }
        try write(["duration": asset.duration ?? 0, "width": asset.pixelSize.width,
                   "height": asset.pixelSize.height, "active": service.hasActiveSession,
                   "playable": try await AVURLAsset(url: asset.url).load(.isPlayable)], "completed.json")
        return 0
    } catch {
        print("AUDIT FAILED: \(error)")
        return 1
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.finishLaunching()
Task { @MainActor in exit(await runAudit()) }
application.run()
