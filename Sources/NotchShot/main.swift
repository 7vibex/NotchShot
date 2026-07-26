import AppKit
import Foundation
import NotchShotKit

if CommandLine.arguments.contains("--self-test") {
    _ = NSApplication.shared
    Task { @MainActor in
        exit(await runBundledSelfTest())
    }
    RunLoop.main.run()
} else {
    // NotchShot runs as an accessory app: no Dock icon by default, a menu-bar
    // item, and a nonactivating panel pinned to the notch. `NSApplicationMain`
    // is avoided so the delegate is installed before the first launch event.
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
