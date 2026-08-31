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

/// A visible, capture-included presenter overlay. It never owns the screen
/// recording writer, so camera or event-monitor failure cannot damage the MP4.
@MainActor
public final class RecordingPresentationOverlayController {
    public static let shared = RecordingPresentationOverlayController()

    private var panel: NSPanel?
    private var cameraView: RecordingCameraPreviewView?
    private var keyLabel: NSTextField?
    private var monitors: [Any] = []
    private var hideKeyTask: Task<Void, Never>?

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

        let root = NSVisualEffectView(frame: CGRect(origin: .zero, size: frame.size))
        root.material = .hudWindow
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 18
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        panel.contentView = root

        var bottom: CGFloat = 10
        if options.showsKeystrokes {
            let label = NSTextField(labelWithString: "Shortcuts appear here")
            label.alignment = .center
            label.font = .monospacedSystemFont(ofSize: 14, weight: .semibold)
            label.textColor = .white
            label.lineBreakMode = .byTruncatingMiddle
            label.frame = CGRect(x: 12, y: 10, width: width - 24, height: 28)
            root.addSubview(label)
            keyLabel = label
            bottom = 48
            installKeyMonitors()
        }

        if options.showsCamera {
            let camera = RecordingCameraPreviewView(
                frame: CGRect(x: 10, y: bottom, width: width - 20, height: height - bottom - 10)
            )
            camera.wantsLayer = true
            camera.layer?.cornerRadius = 14
            camera.layer?.masksToBounds = true
            root.addSubview(camera)
            cameraView = camera
            await camera.start()
        }

        self.panel = panel
        WindowExclusionRegistry.shared.register(panel)
        WindowExclusionRegistry.shared.setIncludedInCaptures(true, for: panel)
        panel.orderFrontRegardless()
        return true
    }

    public func stop() {
        hideKeyTask?.cancel()
        hideKeyTask = nil
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        cameraView?.stop()
        cameraView = nil
        keyLabel = nil
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
        hideKeyTask?.cancel()
        hideKeyTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            self?.keyLabel?.stringValue = ""
        }
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
