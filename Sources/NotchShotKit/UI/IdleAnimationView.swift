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

    /// The file this launch has already found on disk. `currentURL` is read in
    /// the body of the hover bar, so it asks the disk once per file.
    private static var verifiedURL: URL?

    /// The hover bar's image, kept between hovers. That view is rebuilt on
    /// every hover, and each rebuild used to read up to 20 MB on the main
    /// thread as the bar started to open. Holds one file at most.
    private static var sharedImage: (url: URL, image: NSImage)?

    /// The installed file, or nil when none is set or it has gone missing.
    public static var currentURL: URL? {
        guard let name = ExtrasPreferences.shared.idleAnimationFileName else { return nil }
        let url = directory.appendingPathComponent(name)
        if url == verifiedURL { return url }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        verifiedURL = url
        return url
    }

    static func cachedImage(at url: URL) -> NSImage? {
        sharedImage?.url == url ? sharedImage?.image : nil
    }

    /// Reads the file off the main thread. With `sharesImage`, keeps the result
    /// for the next hover if `url` is still the installed file.
    static func loadImage(at url: URL, sharesImage: Bool) async -> NSImage? {
        if sharesImage, let cached = cachedImage(at: url) { return cached }
        let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
        if sharesImage, let cached = cachedImage(at: url) { return cached }
        guard let data, let image = NSImage(data: data) else {
            if url == verifiedURL { verifiedURL = nil }
            return nil
        }
        if sharesImage, url == verifiedURL { sharedImage = (url, image) }
        return image
    }

    /// Fills the cache ahead of the first hover, so the bar never opens with
    /// an empty slot.
    static func preloadImage() {
        guard let url = currentURL else { return }
        Task { _ = await loadImage(at: url, sharesImage: true) }
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
        forgetLoadedFile()
        preloadImage()
    }

    public static func remove() {
        if let url = currentURL { try? FileManager.default.removeItem(at: url) }
        ExtrasPreferences.shared.idleAnimationFileName = nil
        forgetLoadedFile()
    }

    private static func forgetLoadedFile() {
        verifiedURL = nil
        sharedImage = nil
    }
}

/// Plays a GIF (or shows a still) at a fixed size. `NSImageView` animates
/// GIFs itself, off SwiftUI's render loop.
struct IdleAnimationView: NSViewRepresentable {
    var url: URL
    var animates = true
    /// Use the store's kept image. Two views animating one image step it twice
    /// as fast, so only the hover bar does; only one display peeks at a time.
    var sharesImage = false

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
            context.coordinator.show(url, in: view, sharesImage: sharesImage)
        }
        view.animates = animates
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private(set) var url: URL?

        func show(_ url: URL, in view: NSImageView, sharesImage: Bool) {
            self.url = url
            if sharesImage, let cached = IdleAnimationStore.cachedImage(at: url) {
                view.image = cached
                return
            }
            view.image = nil
            Task { [weak self, weak view] in
                let image = await IdleAnimationStore.loadImage(at: url, sharesImage: sharesImage)
                guard let self, self.url == url else { return }
                view?.image = image
            }
        }
    }
}
