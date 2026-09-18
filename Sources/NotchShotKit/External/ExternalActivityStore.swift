import Foundation
import NotchShotAIReporterSupport
import Observation

/// Main-actor owner of externally published Live Activities.
///
/// The registry enforces every bound; this class only runs the socket, keeps
/// one expiry wake-up scheduled, and coalesces change notifications. History
/// is memory-only by design: external titles can name private projects, and
/// the Recent list is not worth writing them to disk.
@MainActor
@Observable
public final class ExternalActivityStore {
    public static let shared = ExternalActivityStore()

    public private(set) var registry = ExternalActivityRegistry()
    public private(set) var isListening = false
    public var onChange: (() -> Void)?
    /// Fired when an activity completes or fails, for the island's burst.
    public var onOutcome: ((ExternalLiveActivity) -> Void)?

    public var live: [ExternalLiveActivity] { registry.live }
    public var history: [ExternalLiveActivity] { registry.history }

    @ObservationIgnored private let server: LiveActivitySocketServer
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    /// The deadline the currently armed expiry task was created for. While it
    /// matches `registry.nextDeadline` there is nothing to reschedule.
    @ObservationIgnored private var scheduledDeadline: Date?
    /// Test seam: incremented every time an expiry task is actually created.
    @ObservationIgnored private(set) var expiryTaskGeneration: UInt64 = 0
    @ObservationIgnored private var publishTask: Task<Void, Never>?
    @ObservationIgnored private var lastPublish = Date.distantPast
    static let minimumPublishInterval: TimeInterval = 0.1

    public init() {
        server = LiveActivitySocketServer()
    }

    /// Test seam: uses a disposable socket path so scheduling can be exercised
    /// without touching the app's real socket.
    init(socketPath: String) {
        server = LiveActivitySocketServer(socketPath: socketPath)
    }

    /// Test seam: the deadline of the currently armed expiry task, if any.
    var scheduledDeadlineForTesting: Date? { scheduledDeadline }

    public func start() {
        guard !isListening else { return }
        isListening = true
        server.start { [weak self] update in
            await self?.receive(update)
        }
        scheduleExpiry()
    }

    public func stop() {
        guard isListening else { return }
        isListening = false
        server.stop()
        expiryTask?.cancel()
        expiryTask = nil
        scheduledDeadline = nil
        publishTask?.cancel()
        registry.removeAll()
        onChange?()
    }

    /// Applies an update as if it came from the socket. Internal so tests and
    /// the socket share one path.
    func receive(_ update: LiveActivityUpdate, now: Date = Date()) -> LiveActivityValidationError? {
        guard isListening else { return .init("live activities are disabled") }
        let before = registry.live
        if let error = registry.apply(update, now: now) { return error }
        if update.command == .finish || update.command == .fail,
           let outcome = registry.live.first(where: { $0.id == update.id })
            ?? registry.history.first(where: { $0.id == update.id }) {
            onOutcome?(outcome)
        }
        // Structural changes publish immediately; progress-only updates are
        // coalesced so a chatty reporter cannot drive the UI at its own rate.
        let structural = before.map(\.id) != registry.live.map(\.id)
            || before.map(\.lifecycle) != registry.live.map(\.lifecycle)
        schedulePublish(immediately: structural)
        scheduleExpiry()
        return nil
    }

    public func dismiss(id: String) {
        registry.dismiss(id: id)
        schedulePublish(immediately: true)
        scheduleExpiry()
    }

    public func clearHistory() {
        registry.clearHistory()
    }

    private func schedulePublish(immediately: Bool) {
        let now = Date()
        if immediately || now.timeIntervalSince(lastPublish) >= Self.minimumPublishInterval {
            publishTask?.cancel()
            publishTask = nil
            lastPublish = now
            onChange?()
            return
        }
        guard publishTask == nil else { return }
        let delay = Self.minimumPublishInterval - now.timeIntervalSince(lastPublish)
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.01, delay)))
            guard !Task.isCancelled, let self else { return }
            self.publishTask = nil
            self.lastPublish = Date()
            self.onChange?()
        }
    }

    private func scheduleExpiry() {
        let deadline = registry.nextDeadline
        if deadline == scheduledDeadline, expiryTask != nil { return }
        expiryTask?.cancel()
        expiryTask = nil
        scheduledDeadline = deadline
        guard let deadline else { return }
        expiryTaskGeneration &+= 1
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.05, deadline.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            // The task that fired is no longer the scheduled one; clear before
            // rescheduling so the deadline comparison sees fresh state.
            self.expiryTask = nil
            self.scheduledDeadline = nil
            if self.registry.expire(now: Date()) {
                self.schedulePublish(immediately: true)
            }
            self.scheduleExpiry()
        }
    }
}
