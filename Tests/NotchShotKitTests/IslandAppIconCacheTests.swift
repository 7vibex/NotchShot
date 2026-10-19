import AppKit
import Testing
@testable import NotchShotKit

/// Resolver state is synchronized; the optional semaphore blocks only the
/// cache's worker, allowing the test to verify main-actor progress explicitly.
private final class IconResolverProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var queries: [String] = []
    private var queriedOnMain = false
    private var timedOut = false
    let miss: Bool
    let entered: (@Sendable () -> Void)?
    let release: DispatchSemaphore?

    init(miss: Bool = false, entered: (@Sendable () -> Void)? = nil,
         release: DispatchSemaphore? = nil) {
        self.miss = miss
        self.entered = entered
        self.release = release
    }

    var snapshot: (queries: [String], queriedOnMain: Bool, timedOut: Bool) {
        lock.withLock { (queries, queriedOnMain, timedOut) }
    }

    func resolve(_ identifier: String) -> IslandAppIconResult {
        let first = lock.withLock {
            queries.append(identifier)
            queriedOnMain = queriedOnMain || Thread.isMainThread
            return queries.count == 1
        }
        if first {
            entered?()
            if let release, release.wait(timeout: .now() + 30) == .timedOut {
                lock.withLock { timedOut = true }
            }
        }
        guard !miss else { return IslandAppIconResult(image: nil) }
        let image = NSImage(size: NSSize(width: 96, height: 96))
        for pixels in [32, 128] {
            let representation = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )!
            image.addRepresentation(representation)
        }
        return IslandAppIconResult(image: image)
    }
}

@Suite("Call icon cache", .serialized)
@MainActor
struct IslandAppIconCacheTests {
    private func verifyMainHeartbeat() {
        #expect(Thread.isMainThread)
    }

    @Test("Cold lookup runs off main and cached images retain all representations")
    func coldAndCachedImage() async throws {
        let probe = IconResolverProbe()
        let cache = IslandAppIconCache(resolver: probe.resolve)
        #expect(cache.cachedIcon(for: "call.app") == nil)
        let image = try #require(await cache.load(for: "call.app"))
        let cached = await cache.load(for: "call.app")
        #expect(image === cached)
        #expect(image === cache.cachedIcon(for: "call.app"))
        #expect(image.representations.count == 2)
        #expect(probe.snapshot.queries == ["call.app"])
        #expect(!probe.snapshot.queriedOnMain)
    }

    @Test("Missing apps are cached separately by bundle identifier")
    func cachedMisses() async {
        let probe = IconResolverProbe(miss: true)
        let cache = IslandAppIconCache(resolver: probe.resolve)
        #expect(await cache.load(for: "missing.app") == nil)
        #expect(await cache.load(for: "missing.app") == nil)
        #expect(await cache.load(for: "other.app") == nil)
        #expect(probe.snapshot.queries == ["missing.app", "other.app"])
        #expect(!probe.snapshot.queriedOnMain)
    }

    @Test("Overlapping waiters share one lookup and cancellation preserves the shared result")
    func overlappingAndCancelledWaiters() async {
        let release = DispatchSemaphore(value: 0)
        var first: Task<Bool, Never>!
        var second: Task<Bool, Never>!
        var probe: IconResolverProbe!
        var cache: IslandAppIconCache!
        await withCheckedContinuation { entered in
            probe = IconResolverProbe(entered: { entered.resume() }, release: release)
            cache = IslandAppIconCache(resolver: probe.resolve)
            let ownedCache = cache!
            first = Task { await ownedCache.load(for: "call.app") != nil }
            second = Task { await ownedCache.load(for: "call.app") != nil }
        }
        // The resolver is blocked, yet both tasks and this main-actor heartbeat
        // can proceed. Cancelling one view task must not cancel the cache task.
        verifyMainHeartbeat()
        #expect(probe.snapshot.queries == ["call.app"])
        #expect(!probe.snapshot.queriedOnMain)
        first.cancel()
        release.signal()
        #expect(await first.value)
        #expect(await second.value)
        #expect(await cache.load(for: "call.app") != nil)
        #expect(probe.snapshot.queries == ["call.app"])
        #expect(!probe.snapshot.timedOut)
    }
}
