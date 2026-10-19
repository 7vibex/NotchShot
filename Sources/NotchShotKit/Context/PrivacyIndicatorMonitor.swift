import Foundation
import Observation

/// The application behind a process that is recording from a microphone.
/// Helper processes (a Discord or Chrome renderer) resolve to the app that
/// ships them, which is the one the user would recognise.
public struct MicrophoneClient: Sendable, Equatable, Hashable {
    public var bundleIdentifier: String
    public var name: String
    public var applicationURL: URL?
}

/// Whether another process is using a microphone or a camera. Listener-driven:
/// nothing is polled, and only the yes/no is kept.
///
/// The microphone comes from Core Audio's per-process "is running input", not
/// the per-device "running somewhere": an interface that both plays and
/// records runs whenever music plays through it, which would light the dot for
/// playback. The per-process view also leaves out NotchShot's own dictation
/// and voice notes, which the island already shows. Cameras come from
/// CoreMediaIO's per-device "running somewhere", which has no such ambiguity.
@MainActor
@Observable
public final class PrivacyIndicatorMonitor {
    public static let shared = PrivacyIndicatorMonitor()

    public private(set) var microphoneInUse = false
    public private(set) var cameraInUse = false
    /// The apps currently recording from a microphone, other than NotchShot.
    public private(set) var microphoneClients: [MicrophoneClient] = []
    /// Called after either flag changes, so the window controller can resize
    /// the notch's hit region along with the drawn shell.
    @ObservationIgnored public var onChange: (() -> Void)?

    public var isActive: Bool { microphoneInUse || cameraInUse }

    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private let worker: PrivacyIndicatorWorker

    public init() {
        worker = PrivacyIndicatorWorker(backend: LivePrivacyIndicatorBackend())
    }

    /// Internal seam for lifecycle and isolation tests; public construction is unchanged.
    init(backend: any PrivacyIndicatorBackend, queue: DispatchQueue) {
        worker = PrivacyIndicatorWorker(backend: backend, queue: queue)
    }

    deinit {
        worker.stop()
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        generation &+= 1
        let currentGeneration = generation
        worker.start(generation: currentGeneration) { [weak self] snapshot in
            // A serial worker submits publications to main in event order. A
            // Task per event would allow task scheduling to reorder snapshots.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.isRunning, self.generation == currentGeneration else { return }
                    self.set(microphone: snapshot.microphone, camera: snapshot.camera, clients: snapshot.clients)
                }
            }
        }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        generation &+= 1
        worker.stop()
        // Clearing is immediate even when an OS query or teardown is waiting.
        set(microphone: false, camera: false)
    }

    private func set(microphone: Bool, camera: Bool, clients: [MicrophoneClient] = []) {
        guard microphone != microphoneInUse || camera != cameraInUse || clients != microphoneClients else { return }
        microphoneInUse = microphone
        cameraInUse = camera
        microphoneClients = clients
        onChange?()
    }
}
