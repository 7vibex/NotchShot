import AppKit
import Darwin
import Foundation
import NotchShotKit

/// Launch Services normally enforces `LSMultipleInstancesProhibited`, but a
/// direct executable launch or `open -n` can bypass normal activation. A kernel
/// file lock makes the OSD lease single-owner even in those cases and is
/// released automatically on crash or SIGKILL.
private final class SingleInstanceLease {
    enum Acquisition {
        case acquired(SingleInstanceLease)
        case alreadyRunning
        case failed(Int32)
    }

    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire() -> Acquisition {
        guard AppPaths.ensureDirectories() else { return .failed(EACCES) }
        let lockURL = AppPaths.support.appendingPathComponent("gui-instance.lock")
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else { return .failed(errno) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            Darwin.close(descriptor)
            if lockError == EWOULDBLOCK || lockError == EAGAIN {
                return .alreadyRunning
            }
            return .failed(lockError)
        }
        return .acquired(SingleInstanceLease(descriptor: descriptor))
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}

/// Waits for the process that spawned it to exit, then reopens this exact
/// bundle.
///
/// A relaunch cannot overlap: `LSMultipleInstancesProhibited` makes Launch
/// Services return the *running* instance rather than starting a second one,
/// and the `flock` lease below would send a second instance straight back out
/// even if it did start. So the only correct order is quit first, launch after
/// — which needs a process that outlives the quit. This binary is that process,
/// re-entered through a flag, so nothing unsigned or unvalidated is involved.
private func relaunchAfterParentExit(arguments: [String]) -> Never {
    guard arguments.count == 2,
          let parentProcessID = pid_t(arguments[0]), parentProcessID > 1 else {
        exit(64)
    }
    // The only bundle this waiter is ever allowed to open is its own. It takes
    // a path purely so a mismatch is a hard failure rather than a silent one.
    let bundlePath = URL(fileURLWithPath: arguments[1]).standardizedFileURL.path
    guard bundlePath == Bundle.main.bundleURL.standardizedFileURL.path else { exit(77) }

    // Bounded: if the parent never exits, reopening would hand the user a
    // second instance the lease then kills, which is worse than doing nothing.
    let deadline = ProcessInfo.processInfo.systemUptime + 30
    while kill(parentProcessID, 0) == 0 || errno == EPERM {
        guard ProcessInfo.processInfo.systemUptime < deadline else { exit(75) }
        usleep(50_000)
    }

    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = [bundlePath]
    open.standardOutput = FileHandle.nullDevice
    open.standardError = FileHandle.nullDevice
    do {
        try open.run()
        open.waitUntilExit()
        exit(open.terminationStatus)
    } catch {
        exit(126)
    }
}

if let flagIndex = CommandLine.arguments.firstIndex(of: "--relaunch-after") {
    relaunchAfterParentExit(
        arguments: Array(CommandLine.arguments.dropFirst(flagIndex + 1))
    )
} else if CommandLine.arguments.contains("--self-test") {
    // Exercise ScreenCaptureKit through a fully launched AppKit application.
    // A bare run loop can be enough on older macOS releases, but macOS 26 may
    // return an empty shareable-content inventory before launch completes.
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    application.finishLaunching()
    Task { @MainActor in
        exit(await runBundledSelfTest())
    }
    application.run()
} else {
    let instanceLease: SingleInstanceLease
    switch SingleInstanceLease.acquire() {
    case .acquired(let lease):
        instanceLease = lease
    case .alreadyRunning:
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.notchshot.app")
            .first { $0.processIdentifier != getpid() }?
            .activate(options: [])
        exit(0)
    case .failed(let errorNumber):
        let message = "NotchShot could not create its single-instance safety lock: \(String(cString: strerror(errorNumber)))."
        FileHandle.standardError.write(Data((message + "\n").utf8))
        _ = NSApplication.shared
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "NotchShot couldn’t start safely"
        alert.informativeText = message
        alert.runModal()
        exit(73)
    }

    // NotchShot runs as an accessory app: no Dock icon by default, a menu-bar
    // item, and a nonactivating panel pinned to the notch. `NSApplicationMain`
    // is avoided so the delegate is installed before the first launch event.
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
    withExtendedLifetime(instanceLease) {}
}
