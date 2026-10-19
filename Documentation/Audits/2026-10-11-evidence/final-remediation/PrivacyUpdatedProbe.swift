import AppKit
import Foundation
@main struct PrivacyUpdatedProbe {
    @MainActor static func main() async {
        _ = NSApplication.shared
        let worker = PrivacyIndicatorWorker(backend: LivePrivacyIndicatorBackend(), queue: DispatchQueue(label: "privacy-os-probe", qos: .userInitiated))
        let began = ContinuousClock.now
        var enqueueDuration: Duration = .zero
        let elapsed: (Duration, Duration, Int, Bool) = await withCheckedContinuation { continuation in
            let completion = ProbeCompletion(continuation: continuation, began: began)
            worker.start(generation: 1) { snapshot in completion.finish(snapshot) }
            enqueueDuration = began.duration(to: .now)
        }
        print("updated main-actor enqueue: \(enqueueDuration); worker initial snapshot: \(elapsed.0); main publication usable completion: \(elapsed.1); client count: \(elapsed.2); query completed on main: \(elapsed.3)")
        worker.stop()
    }
}
final class ProbeCompletion: @unchecked Sendable {
    let lock = NSLock()
    var pending: CheckedContinuation<(Duration, Duration, Int, Bool), Never>?
    let began: ContinuousClock.Instant
    init(continuation: CheckedContinuation<(Duration, Duration, Int, Bool), Never>, began: ContinuousClock.Instant) { pending = continuation; self.began = began }
    func finish(_ snapshot: PrivacyIndicatorSnapshot) {
        lock.lock()
        let pending = pending; self.pending = nil
        lock.unlock()
        let workerCompletion = began.duration(to: .now)
        let workerOnMain = Thread.isMainThread
        DispatchQueue.main.async { [began] in
            pending?.resume(returning: (workerCompletion, began.duration(to: .now), snapshot.clients.count, workerOnMain))
        }
    }
}
