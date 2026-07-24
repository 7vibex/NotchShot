import AppKit
import NotchShotKit

// NotchShot runs as an accessory app: no Dock icon by default, a menu-bar item,
// and a nonactivating panel pinned to the notch. `NSApplicationMain` is avoided
// so the delegate is installed before the first `applicationDidFinishLaunching`.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
