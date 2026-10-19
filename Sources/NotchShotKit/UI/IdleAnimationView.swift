import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The user's own GIF or picture for the idle notch's hover bar.
///
/// The file is copied into Application Support, so moving or deleting the
/// original never breaks it, and only one copy is kept at a time.
@MainActor
public enum IdleAnimationStore {
    public static let maximumBytes = 20 * 1_024 * 1_024
    static var directory: URL { AppPaths.support.appendingPathComponent("idle-animation", isDirectory: true) }

    public static let allowedTypes: [UTType] = [.gif, .png, .jpeg, .heic, .webP]

    /// The installed file, or nil when none is set or it has gone missing.
    public static var currentURL: URL? {
        guard let name = ExtrasPreferences.shared.idleAnimationFileName else { return nil }
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public static func install(from source: URL) throws {
        guard let type = UTType(filenameExtension: source.pathExtension.lowercased()),
              allowedTypes.contains(where: { type.conforms(to: $0) }) else {
            throw NotchShotError.exportFailed("Choose a GIF, PNG, JPEG, HEIC or WebP image")
        }
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size <= maximumBytes else {
            throw NotchShotError.exportFailed("Choose an image under 20 MB")
        }
        guard NSImage(contentsOf: source) != nil else {
            throw NotchShotError.exportFailed("That image couldn't be read")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "idle-\(UUID().uuidString.prefix(8)).\(source.pathExtension.lowercased())"
        let destination = directory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: destination)
        let previous = currentURL
        ExtrasPreferences.shared.idleAnimationFileName = name
        if let previous, previous != destination { try? FileManager.default.removeItem(at: previous) }
    }

    public static func remove() {
        if let url = currentURL { try? FileManager.default.removeItem(at: url) }
        ExtrasPreferences.shared.idleAnimationFileName = nil
    }
}

/// Plays a GIF (or shows a still) at a fixed size. `NSImageView` animates
/// GIFs itself, off SwiftUI's render loop.
struct IdleAnimationView: NSViewRepresentable {
    var url: URL
    var animates = true

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageFrameStyle = .none
        view.isEditable = false
        view.wantsLayer = true
        view.layer?.cornerRadius = 5
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        if context.coordinator.url != url {
            context.coordinator.url = url
            view.image = NSImage(contentsOf: url)
        }
        view.animates = animates
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var url: URL?
    }
}
