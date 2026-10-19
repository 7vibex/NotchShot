import Foundation
import Testing
@testable import NotchShotKit

/// Only accessed on the serial worker queue, except for the explicitly
/// thread-safe blocking semaphore used by the main-actor isolation control.
private final class PrivacyTestBackend: PrivacyIndicatorBackend, @unchecked Sendable {
    struct Registration {
        var id: Int
        var property: PrivacyIndicatorProperty
        var queue: DispatchQueue
        var handler: @Sendable () -> Void
    }
    var registrations: [Registration] = []
    var removals: [Int] = []
    var queryOnMain: [Bool] = []
    var recording = false
    var camera = false
    var blockNextQuery: (@Sendable () -> Void)?
    var failedProperty: PrivacyIndicatorProperty?
    var audioQueries = 0

    func addListener(_ property: PrivacyIndicatorProperty, queue: DispatchQueue,
                     handler: @escaping @Sendable () -> Void) -> PrivacyIndicatorListener? {
        queryOnMain.append(Thread.isMainThread)
        if property == failedProperty { return nil }
        let id = registrations.count
        registrations.append(Registration(id: id, property: property, queue: queue, handler: handler))
        return PrivacyIndicatorListener { [weak self] in self?.removals.append(id) }
    }
    func otherAudioProcesses() -> [UInt32] {
        queryOnMain.append(Thread.isMainThread)
        audioQueries += 1
        return [30, 10, 20]
    }
    func cameraDeviceIDs() -> [UInt32] { queryOnMain.append(Thread.isMainThread); return [40] }
    func isRecording(_ process: UInt32) -> Bool {
        queryOnMain.append(Thread.isMainThread)
        if let block = blockNextQuery { blockNextQuery = nil; block() }
        return recording
    }
    func isCameraRunning(_ device: UInt32) -> Bool { queryOnMain.append(Thread.isMainThread); return camera }
    func client(for process: UInt32) -> MicrophoneClient? {
        queryOnMain.append(Thread.isMainThread)
        // Duplicate identities are collapsed in source-list order, as before.
        let id = process == 20 ? "app-30" : "app-\(process)"
        return MicrophoneClient(bundleIdentifier: id, name: id, applicationURL: nil)
    }
}

private final class PrivacySnapshotCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Duration, Bool, Int), Never>?
    init(_ continuation: CheckedContinuation<(Duration, Bool, Int), Never>) { self.continuation = continuation }
    func finish(_ measurement: (Duration, Bool, Int)) {
        let pending = lock.withLock { let pending = continuation; continuation = nil; return pending }
        pending?.resume(returning: measurement)
    }
}

@Suite("Privacy indicator worker", .serialized)
@MainActor
struct PrivacyIndicatorWorkerTests {
    private func drain(_ queue: DispatchQueue) async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    private func verifyMainWhileQueryBlocked(_ queryFinished: DispatchSemaphore) {
        #expect(queryFinished.wait(timeout: .now()) == .timedOut,
                "query must still be blocked during the main heartbeat")
        #expect(Thread.isMainThread)
    }

    private func verifyQueryReleasedNormally(_ releasedNormally: DispatchSemaphore) {
        #expect(releasedNormally.wait(timeout: .now()) == .success,
                "the explicit main-actor release must unblock the query before its fallback timeout")
    }

    @Test("A blocked OS query does not block main, and stop/restart rejects its old snapshot")
    func blockedQueryLeavesMainAvailable() async {
        let queue = DispatchQueue(label: "privacy-test-blocked")
        let backend = PrivacyTestBackend()
        let release = DispatchSemaphore(value: 0)
        let queryFinished = DispatchSemaphore(value: 0)
        let releasedNormally = DispatchSemaphore(value: 0)
        let monitor = PrivacyIndicatorMonitor(backend: backend, queue: queue)
        var changes: [Bool] = []
        monitor.onChange = { [weak monitor] in changes.append(monitor?.microphoneInUse ?? false) }
        // The continuation proves the worker has entered the blocking OS seam
        // before the heartbeat assertion runs on main. A main-thread backend
        // would deadlock here until the bounded fallback timeout. This checks
        // causality rather than elapsed time: other suites may contend for main.
        await withCheckedContinuation { entered in
            backend.recording = true
            backend.blockNextQuery = {
                entered.resume()
                if release.wait(timeout: .now() + 30) == .success { releasedNormally.signal() }
                queryFinished.signal()
            }
            monitor.start()
        }
        verifyMainWhileQueryBlocked(queryFinished)
        monitor.stop()
        #expect(!monitor.isActive)
        #expect(monitor.microphoneClients.isEmpty)
        monitor.start()
        release.signal()
        await drain(queue)
        #expect(monitor.microphoneInUse)
        #expect(changes == [true], "only the new generation may publish")
        #expect(!backend.queryOnMain.contains(true))
        verifyQueryReleasedNormally(releasedNormally)
        monitor.stop()
        await drain(queue)
        #expect(backend.removals.sorted() == backend.registrations.map(\.id).sorted())
    }

    @Test("Every running event publishes in order and preserves client deduplication order")
    func eventsAreFIFO() async {
        let queue = DispatchQueue(label: "privacy-test-fifo")
        let backend = PrivacyTestBackend()
        let monitor = PrivacyIndicatorMonitor(backend: backend, queue: queue)
        var changes: [Bool] = []
        monitor.onChange = { [weak monitor] in changes.append(monitor?.microphoneInUse ?? false) }
        monitor.start()
        await drain(queue)
        await withCheckedContinuation { continuation in
            queue.async {
                let handler = backend.registrations.first { $0.property == .audioRunning(30) }!.handler
                backend.recording = true; handler()
                backend.recording = false; handler()
                backend.recording = true; handler()
                continuation.resume()
            }
        }
        await drain(queue)
        #expect(changes == [true, false, true])
        #expect(monitor.microphoneClients.map(\.bundleIdentifier) == ["app-30", "app-10"])
        #expect(!backend.queryOnMain.contains(true))
        monitor.stop()
        #expect(!monitor.isActive)
        #expect(monitor.microphoneClients.isEmpty)
        await drain(queue)
        #expect(backend.removals.sorted() == backend.registrations.map(\.id).sorted())
    }

    @Test("Old list and running callbacks cannot query or publish after restart; repeated starts are idempotent")
    func staleCallbacksAreIgnored() async {
        let queue = DispatchQueue(label: "privacy-test-stale")
        let backend = PrivacyTestBackend()
        let monitor = PrivacyIndicatorMonitor(backend: backend, queue: queue)
        monitor.start(); monitor.start()
        await drain(queue)
        #expect(backend.audioQueries == 1)
        let old = backend.registrations
        monitor.stop(); monitor.start()
        await drain(queue)
        let queries = backend.queryOnMain.count
        await withCheckedContinuation { continuation in
            queue.async {
                backend.recording = true
                for registration in old { registration.handler() }
                continuation.resume()
            }
        }
        await drain(queue)
        #expect(backend.queryOnMain.count == queries)
        #expect(!monitor.isActive)
        monitor.stop(); monitor.stop()
        await drain(queue)
        #expect(backend.removals.sorted() == backend.registrations.map(\.id).sorted())
    }

    @Test("Rebuild removes each successful registration once, and deinitialization tears down without retention")
    func rebuildAndDeinitRemoveListeners() async {
        let queue = DispatchQueue(label: "privacy-test-cleanup")
        let backend = PrivacyTestBackend()
        backend.failedProperty = .cameraRunning(40)
        var monitor: PrivacyIndicatorMonitor? = PrivacyIndicatorMonitor(backend: backend, queue: queue)
        weak var weakMonitor = monitor
        monitor?.start()
        await drain(queue)
        await withCheckedContinuation { continuation in
            queue.async {
                backend.camera = true
                backend.registrations.first { $0.property == .cameraDevices }!.handler()
                continuation.resume()
            }
        }
        await drain(queue)
        #expect(monitor?.cameraInUse == true)
        #expect(backend.audioQueries == 2)
        monitor = nil
        await drain(queue)
        #expect(weakMonitor == nil)
        #expect(backend.removals.sorted() == backend.registrations.map(\.id).sorted())
        #expect(backend.removals.count == Set(backend.removals).count)
        #expect(backend.registrations.allSatisfy { $0.queue === queue })
    }

    @Test("Actual OS initial snapshot completes on the dedicated queue")
    func liveInitialSnapshot() async {
        let worker = PrivacyIndicatorWorker(backend: LivePrivacyIndicatorBackend())
        let started = ContinuousClock.now
        let measurement: (Duration, Bool, Int) = await withCheckedContinuation { continuation in
            let completion = PrivacySnapshotCompletion(continuation)
            worker.start(generation: 1) { snapshot in
                completion.finish((started.duration(to: .now), Thread.isMainThread, snapshot.clients.count))
            }
        }
        #expect(!measurement.1)
        print("Privacy actual OS initial snapshot: \(measurement.0); main thread: \(measurement.1); microphone client count: \(measurement.2)")
        worker.stop()
    }
}
