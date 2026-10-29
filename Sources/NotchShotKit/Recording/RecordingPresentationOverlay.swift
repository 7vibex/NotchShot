import AVFoundation
import AppKit
import Foundation

public struct RecordingPresentationOptions: Sendable, Equatable {
    public var showsCamera: Bool
    public var showsKeystrokes: Bool

    public init(showsCamera: Bool = false, showsKeystrokes: Bool = false) {
        self.showsCamera = showsCamera
        self.showsKeystrokes = showsKeystrokes
    }

    public var isEmpty: Bool { !showsCamera && !showsKeystrokes }
}

/// What the presenter panel shows at a given moment.
///
/// The panel is deliberately part of the recording, so anything it draws ends
/// up in the video. Between shortcuts the keystroke area draws nothing at all,
/// and a panel with no camera bubble has nothing left to show.
struct RecordingPresenterVisibility: Equatable {
    var showsCamera: Bool
    var isShowingShortcut: Bool

    var isKeyAreaVisible: Bool { isShowingShortcut }
    var isPanelVisible: Bool { showsCamera || isShowingShortcut }
}

/// The narrow surface recording paths depend on for the presenter overlay.
///
/// Injected on `AppCoordinator` so terminal cleanup can be pinned without
/// starting a camera or installing event monitors in a test process.
@MainActor
public protocol RecordingPresentationControlling: AnyObject {
    @discardableResult
    func start(
        options: RecordingPresentationOptions,
        displayID: CGDirectDisplayID?,
        captureFrame: CGRect?
    ) async -> Bool
    func stop()
}

extension RecordingPresentationOverlayController: RecordingPresentationControlling {}

/// A visible, capture-included presenter overlay. It never owns the screen
/// recording writer, so camera or event-monitor failure cannot damage the MP4.
@MainActor
public final class RecordingPresentationOverlayController {
    public static let shared = RecordingPresentationOverlayController()

    private var panel: NSPanel?
    private var cameraView: RecordingCameraPreviewView?
    private var keyArea: NSView?
    private var keyLabel: NSTextField?
    private var monitors: [Any] = []
    private var hideKeyTask: Task<Void, Never>?
    private var showsCamera = false
    private var isShowingShortcut = false
    /// Bumped on every show or hide of the keystroke area, so a fade-out that
    /// finishes after the next shortcut arrived does not hide it.
    private var keyAreaGeneration = 0

    public var isVisible: Bool { panel?.isVisible == true }

    public func start(
        options: RecordingPresentationOptions,
        displayID: CGDirectDisplayID?,
        captureFrame: CGRect? = nil
    ) async -> Bool {
        stop()
        guard !options.isEmpty else { return true }

        let screen = displayID.flatMap(ScreenLookup.screen(for:)) ?? NSScreen.main
        guard let screen else { return false }
        let availableFrame = (captureFrame?.intersection(screen.frame)).flatMap {
            $0.isNull || $0.isEmpty ? nil : $0
        } ?? screen.visibleFrame
        let preferredWidth: CGFloat = options.showsCamera ? 270 : 220
        let preferredHeight: CGFloat = options.showsCamera
            ? (options.showsKeystrokes ? 230 : 190) : 58
        let width = min(preferredWidth, availableFrame.width - 24)
        let height = min(preferredHeight, availableFrame.height - 24)
        let minimumHeight: CGFloat = options.showsCamera
            ? (options.showsKeystrokes ? 150 : 100) : 48
        guard width >= 120, height >= minimumHeight else { return false }
        let frame = CGRect(
            x: availableFrame.maxX - width - 12,
            y: availableFrame.minY + 12,
            width: width,
            height: height
        )
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        // A clear root with the camera bubble and the keystroke area as separate
        // surfaces, so the keystroke area can be absent from the recording
        // without leaving an empty box under the camera.
        let root = NSView(frame: CGRect(origin: .zero, size: frame.size))
        root.wantsLayer = true
        panel.contentView = root
        let visibility = RecordingPresenterVisibility(
            showsCamera: options.showsCamera,
            isShowingShortcut: false
        )
        showsCamera = options.showsCamera
        isShowingShortcut = false

        var cameraBottom: CGFloat = 0
        if options.showsKeystrokes {
            let areaHeight: CGFloat = options.showsCamera ? 40 : height
            let area = Self.makeSurface(frame: CGRect(x: 0, y: 0, width: width, height: areaHeight))
            let label = NSTextField(labelWithString: "")
            label.alignment = .center
            label.font = .monospacedSystemFont(ofSize: 14, weight: .semibold)
            label.textColor = .white
            label.lineBreakMode = .byTruncatingMiddle
            let labelHeight = ceil(label.fittingSize.height)
            label.frame = CGRect(
                x: 12,
                y: ((areaHeight - labelHeight) / 2).rounded(),
                width: width - 24,
                height: labelHeight
            )
            area.addSubview(label)
            root.addSubview(area)
            keyArea = area
            keyLabel = label
            cameraBottom = areaHeight + 8
            if options.showsCamera {
                // Absent until the first shortcut; the camera bubble stays.
                area.alphaValue = 0
                area.isHidden = true
            }
            installKeyMonitors()
        }

        if options.showsCamera {
            let bubble = Self.makeSurface(frame: CGRect(
                x: 0,
                y: cameraBottom,
                width: width,
                height: height - cameraBottom
            ))
            let camera = RecordingCameraPreviewView(frame: bubble.bounds.insetBy(dx: 10, dy: 10))
            camera.wantsLayer = true
            camera.layer?.cornerRadius = 14
            camera.layer?.masksToBounds = true
            bubble.addSubview(camera)
            root.addSubview(bubble)
            cameraView = camera
            await camera.start()
        }

        // Without a camera the keystroke area is the whole panel, so the
        // window itself stays invisible, and out of the pointer's way, until
        // the first shortcut.
        panel.alphaValue = visibility.isPanelVisible ? 1 : 0
        panel.ignoresMouseEvents = !visibility.isPanelVisible

        self.panel = panel
        WindowExclusionRegistry.shared.register(panel)
        WindowExclusionRegistry.shared.setIncludedInCaptures(true, for: panel)
        panel.orderFrontRegardless()
        return true
    }

    /// The overlay's HUD surface: the camera bubble, or the keystroke area.
    private static func makeSurface(frame: CGRect) -> NSView {
        let surface = NSVisualEffectView(frame: frame)
        surface.material = .hudWindow
        surface.blendingMode = .behindWindow
        surface.state = .active
        surface.wantsLayer = true
        surface.layer?.cornerRadius = min(18, frame.height / 2)
        surface.layer?.masksToBounds = true
        surface.layer?.borderWidth = 1
        surface.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        return surface
    }

    public func stop() {
        hideKeyTask?.cancel()
        hideKeyTask = nil
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        cameraView?.stop()
        cameraView = nil
        keyArea = nil
        keyLabel = nil
        showsCamera = false
        isShowingShortcut = false
        keyAreaGeneration &+= 1
        if let panel {
            WindowExclusionRegistry.shared.unregister(panel)
            panel.orderOut(nil)
            panel.close()
        }
        panel = nil
    }

    private func installKeyMonitors() {
        let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.show(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.show(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func show(_ event: NSEvent) {
        guard event.type == .keyDown, let description = Self.safeDescription(for: event) else { return }
        keyLabel?.stringValue = description
        setShortcutVisible(true)
        hideKeyTask?.cancel()
        hideKeyTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            self?.setShortcutVisible(false)
        }
    }

    /// Fades the keystroke area in or out. The keys stay in the label while it
    /// fades, so the recording never shows an empty box.
    private func setShortcutVisible(_ visible: Bool) {
        guard let panel, let keyArea, visible != isShowingShortcut else { return }
        isShowingShortcut = visible
        keyAreaGeneration &+= 1
        let generation = keyAreaGeneration
        let visibility = RecordingPresenterVisibility(
            showsCamera: showsCamera,
            isShowingShortcut: visible
        )
        let fadesWindow = !showsCamera
        panel.ignoresMouseEvents = !visibility.isPanelVisible
        if visible { keyArea.isHidden = false }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = visible ? 0.12 : 0.24
            context.timingFunction = CAMediaTimingFunction(name: visible ? .easeOut : .easeIn)
            if fadesWindow {
                // The area is the whole panel: fading the window takes its
                // shadow along with it.
                panel.animator().alphaValue = visibility.isPanelVisible ? 1 : 0
            } else {
                keyArea.animator().alphaValue = visibility.isKeyAreaVisible ? 1 : 0
            }
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.keyAreaGeneration == generation, let panel = self.panel else { return }
                // Hidden as well, so nothing of it is drawn between shortcuts
                // even if the blur behind it does not follow the view's opacity.
                if !fadesWindow, !visible { self.keyArea?.isHidden = true }
                // The window shadow is traced from the content once, not on
                // every frame, so it has to be told the shape changed.
                panel.invalidateShadow()
            }
        })
    }

    /// Ordinary characters are intentionally omitted. A presenter overlay is
    /// useful for shortcuts; it must not become a password recorder.
    nonisolated static func safeDescription(for event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasShortcutModifier = !flags.intersection([.command, .control, .option]).isEmpty
        let special: String? = switch event.keyCode {
        case 36: "↩"
        case 48: "⇥"
        case 51: "⌫"
        case 53: "⎋"
        case 115: "↖"
        case 116: "⇞"
        case 117: "⌦"
        case 119: "↘"
        case 121: "⇟"
        case 123: "←"
        case 124: "→"
        case 125: "↓"
        case 126: "↑"
        default: nil
        }
        guard hasShortcutModifier || special != nil else { return nil }
        var parts: [String] = []
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        let key = special ?? event.charactersIgnoringModifiers?.uppercased()
        guard let key, !key.isEmpty else { return nil }
        parts.append(key)
        return parts.joined()
    }
}

@MainActor
private final class RecordingCameraPreviewView: NSView {
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private final class SessionBox: @unchecked Sendable {
        let value = AVCaptureSession()
    }
    private let sessionBox = SessionBox()
    private let queue = DispatchQueue(label: "com.notchshot.recording-presenter-camera")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.session = sessionBox.value
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }

    func start() async {
        let granted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: granted = true
        case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .video)
        default: granted = false
        }
        guard granted else {
            showMessage("Camera permission is off")
            return
        }
        let box = sessionBox
        queue.async {
            let session = box.value
            session.beginConfiguration()
            session.sessionPreset = .high
            guard let camera = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: camera),
                  session.canAddInput(input) else {
                session.commitConfiguration()
                return
            }
            session.addInput(input)
            session.commitConfiguration()
            session.startRunning()
        }
    }

    func stop() {
        let box = sessionBox
        queue.async {
            let session = box.value
            if session.isRunning { session.stopRunning() }
        }
    }

    private func showMessage(_ text: String) {
        let label = NSTextField(labelWithString: text)
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.frame = bounds.insetBy(dx: 12, dy: 12)
        label.autoresizingMask = [.width, .height]
        addSubview(label)
    }
}
