import AppKit

/// One-way ownership transfer from the serial resolver to the main actor.
/// The resolver creates a private image copy, finishes all mutation before
/// returning, and never accesses it again. The cache and views subsequently
/// access the image only on the main actor. Keeping NSImage preserves every
/// representation instead of rasterizing it at an assumed display scale.
struct IslandAppIconResult: @unchecked Sendable {
    let image: NSImage?
}

/// Each bundle, including misses, is resolved once for the process lifetime.
/// Neither a cold LaunchServices lookup nor icon loading runs in a view body.
@MainActor
final class IslandAppIconCache {
    static let shared = IslandAppIconCache()

    private let queue: DispatchQueue
    private let resolver: @Sendable (String) -> IslandAppIconResult
    private var icons: [String: NSImage] = [:]
    private var misses: Set<String> = []
    private var inFlight: [String: Task<IslandAppIconResult, Never>] = [:]

    init(queue: DispatchQueue = DispatchQueue(label: "com.notchshot.call-icons", qos: .userInitiated),
         resolver: @escaping @Sendable (String) -> IslandAppIconResult = IslandAppIconCache.resolve) {
        self.queue = queue
        self.resolver = resolver
    }

    func cachedIcon(for bundleIdentifier: String) -> NSImage? {
        icons[bundleIdentifier]
    }

    func load(for bundleIdentifier: String) async -> NSImage? {
        if let image = icons[bundleIdentifier] { return image }
        guard !misses.contains(bundleIdentifier) else { return nil }

        let task: Task<IslandAppIconResult, Never>
        if let pending = inFlight[bundleIdentifier] {
            task = pending
        } else {
            let queue = queue
            let resolver = resolver
            task = Task {
                await withCheckedContinuation { continuation in
                    queue.async {
                        continuation.resume(returning: resolver(bundleIdentifier))
                    }
                }
            }
            inFlight[bundleIdentifier] = task
        }

        // This shared task belongs to the cache, so cancelling a disappearing
        // avatar must not cancel work another window or avatar is awaiting.
        let result = await task.value
        inFlight[bundleIdentifier] = nil
        if let image = result.image { icons[bundleIdentifier] = image }
        else { misses.insert(bundleIdentifier) }
        return result.image
    }

    nonisolated private static func resolve(_ bundleIdentifier: String) -> IslandAppIconResult {
        // Apple documents both NSWorkspace methods as safe from any thread.
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return IslandAppIconResult(image: nil)
        }
        let image = NSWorkspace.shared.icon(forFile: url.path).copy() as! NSImage
        image.size = NSSize(width: 96, height: 96)
        return IslandAppIconResult(image: image)
    }
}
