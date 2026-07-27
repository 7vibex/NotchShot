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
        AppPaths.ensureDirectories()
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

if CommandLine.arguments.contains("--self-test") {
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
