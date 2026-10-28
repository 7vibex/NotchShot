import AppKit

@MainActor
enum AppCommandMenu {
    static func make(target: AnyObject, settings: Selector, quit: Selector) -> NSMenu {
        let menu = NSMenu()
        let application = NSMenuItem(title: "NotchShot", action: nil, keyEquivalent: "")
        let commands = NSMenu(title: "NotchShot")
        let settingsItem = NSMenuItem(title: "Settings…", action: settings, keyEquivalent: ",")
        settingsItem.target = target
        commands.addItem(settingsItem)
        commands.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit NotchShot", action: quit, keyEquivalent: "q")
        quitItem.target = target
        commands.addItem(quitItem)
        application.submenu = commands
        menu.addItem(application)

        // Use the responder chain so Command-W closes the current auxiliary
        // window, while nonclosable notch panels keep their own lifecycle.
        let file = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileCommands = NSMenu(title: "File")
        fileCommands.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        file.submenu = fileCommands
        menu.addItem(file)
        return menu
    }
}
