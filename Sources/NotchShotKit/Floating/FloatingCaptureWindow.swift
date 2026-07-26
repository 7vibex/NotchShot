import AppKit
import SwiftUI

/// A pinned, always-on-top copy of a capture.
///
/// Deliberately a plain `NSPanel` rather than a SwiftUI window: it needs live
/// resizing with an aspect lock, per-window opacity, and a click-through
/// "locked" mode, none of which SwiftUI window management exposes.
public final class FloatingCaptureWindow: NSPanel {

    public let asset: CaptureAsset
    private let imageView = NSImageView()
    private var isLocked = false
    private var currentOpacity: CGFloat = 1

    public init(asset: CaptureAsset, image: NSImage, at origin: CGPoint?) {
        self.asset = asset

        // Open at a comfortable size: never wider than 40% of the screen, and
        // never so small the content is unreadable.
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let maximumWidth = screen.visibleFrame.width * 0.4
        let maximumHeight = screen.visibleFrame.height * 0.6
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1
        var width = min(image.size.width, maximumWidth)
        var height = width / aspect
        if height > maximumHeight {
            height = maximumHeight
            width = height * aspect
        }
        width = max(width, 160)
        height = max(height, 120)

        let frame = CGRect(
            x: origin?.x ?? (screen.visibleFrame.maxX - width - 40),
            y: origin?.y ?? (screen.visibleFrame.maxY - height - 40),
            width: width,
            height: height
        )

        super.init(
            contentRect: frame,
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .managed]
        isMovableByWindowBackground = true
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        // Keeps its own aspect ratio while the user drags a corner.
        aspectRatio = CGSize(width: width, height: height)
        minSize = CGSize(width: 120, height: 90)

        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = CGRect(origin: .zero, size: frame.size)
        imageView.autoresizingMask = [.width, .height]
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 10
        imageView.layer?.masksToBounds = true
        imageView.layer?.borderWidth = 1
        imageView.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        let container = NSView(frame: CGRect(origin: .zero, size: frame.size))
        container.autoresizingMask = [.width, .height]
        container.addSubview(imageView)
        contentView = container

        setAccessibilityLabel("Pinned capture: \(asset.displayName)")
    }

    public override var canBecomeKey: Bool { !isLocked }

    // MARK: Controls

    public func setOpacity(_ value: CGFloat) {
        currentOpacity = min(max(value, 0.15), 1)
        alphaValue = currentOpacity
    }

    public var opacity: CGFloat { currentOpacity }

    /// Locking makes the window click-through so it can sit over a workspace
    /// as a reference without intercepting anything.
    public func setLocked(_ locked: Bool) {
        isLocked = locked
        ignoresMouseEvents = locked
        isMovableByWindowBackground = !locked
        styleMask = locked
            ? [.borderless, .nonactivatingPanel]
            : [.borderless, .resizable, .nonactivatingPanel]
        imageView.layer?.borderColor = locked
            ? NSColor.systemYellow.withAlphaComponent(0.7).cgColor
            : NSColor.white.withAlphaComponent(0.18).cgColor
    }

    public var locked: Bool { isLocked }

    public override func rightMouseDown(with event: NSEvent) {
        guard !isLocked else { return }
        let menu = NSMenu()

        menu.addItem(withTitle: "Copy", action: #selector(copyImage), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reveal in Finder", action: #selector(reveal), keyEquivalent: "").target = self
        menu.addItem(.separator())

        let opacityItem = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu()
        for value in [1.0, 0.8, 0.6, 0.4, 0.25] {
            let item = NSMenuItem(
                title: "\(Int(value * 100))%",
                action: #selector(changeOpacity(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = value
            item.state = abs(currentOpacity - value) < 0.01 ? .on : .off
            opacityMenu.addItem(item)
        }
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)

        let lockItem = NSMenuItem(title: "Lock", action: #selector(toggleLock), keyEquivalent: "")
        lockItem.target = self
        lockItem.state = isLocked ? .on : .off
        menu.addItem(lockItem)

        let includeItem = NSMenuItem(
            title: "Include in Future Captures",
            action: #selector(toggleIncludeInCaptures),
            keyEquivalent: ""
        )
        includeItem.target = self
        includeItem.state = MainActor.assumeIsolated {
            WindowExclusionRegistry.shared.isIncludedInCaptures(self) ? .on : .off
        }
        menu.addItem(includeItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Close", action: #selector(closePin), keyEquivalent: "").target = self

        NSMenu.popUpContextMenu(menu, with: event, for: contentView ?? NSView())
    }

    @objc private func copyImage() {
        MainActor.assumeIsolated {
            if let image = imageView.image,
               let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                ImageExport.copyToPasteboard(cgImage)
            }
        }
    }

    @objc private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([asset.url])
    }

    @objc private func changeOpacity(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        setOpacity(value)
    }

    @objc private func toggleLock() {
        setLocked(!isLocked)
    }

    @objc private func toggleIncludeInCaptures() {
        MainActor.assumeIsolated {
            let registry = WindowExclusionRegistry.shared
            registry.setIncludedInCaptures(!registry.isIncludedInCaptures(self), for: self)
        }
    }

    @objc private func closePin() {
        MainActor.assumeIsolated {
            FloatingCaptureManager.shared.close(self)
        }
    }
}

/// Owns every pinned capture and keeps them from piling up unbounded.
@MainActor
public final class FloatingCaptureManager {
    public static let shared = FloatingCaptureManager()

    private(set) var windows: [FloatingCaptureWindow] = []
    /// Beyond this, the oldest pin is closed — a screen full of forgotten pins
    /// is a support problem, not a feature.
    private let maximumPins = 12

    public init() {}

    public var pinCount: Int { windows.count }

    @discardableResult
    public func pin(asset: CaptureAsset, image: NSImage) -> FloatingCaptureWindow {
        // Cascade so consecutive pins don't stack exactly on top of each other.
        let offset = CGFloat(windows.count % 6) * 26
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let origin = CGPoint(
            x: screen.visibleFrame.maxX - 420 - offset,
            y: screen.visibleFrame.maxY - 320 - offset
        )

        let window = FloatingCaptureWindow(asset: asset, image: image, at: origin)
        WindowExclusionRegistry.shared.register(window)
        window.orderFrontRegardless()
        windows.append(window)

        while windows.count > maximumPins {
            close(windows[0])
        }
        return window
    }

    public func close(_ window: FloatingCaptureWindow) {
        WindowExclusionRegistry.shared.unregister(window)
        window.orderOut(nil)
        windows.removeAll { $0 === window }
    }

    public func closeAll() {
        for window in windows {
            WindowExclusionRegistry.shared.unregister(window)
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    /// Locked pins intentionally ignore all pointer events, so the menu-bar
    /// app must always provide an out-of-band way to make them interactive.
    public func unlockAll() {
        for window in windows where window.locked {
            window.setLocked(false)
        }
    }
}
