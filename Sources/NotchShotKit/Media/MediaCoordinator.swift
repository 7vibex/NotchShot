import AppKit
import Foundation
import Observation

/// Chooses a working `MediaSource`, keeps the current snapshot, and routes
/// playback commands.
///
/// The fallback chain is: MediaRemote adapter → Apple Events → disabled. It
/// re-evaluates when the adapter dies, when the user changes the setting, and
/// after a wake, but never more often than `reselectCooldown` so a permanently
/// broken adapter can't spin.
@MainActor
@Observable
public final class MediaCoordinator {
    public static let shared = MediaCoordinator()

    public private(set) var snapshot = MediaSnapshot.empty
    public private(set) var activeSource: MediaSourceKind = .none
    /// Set when every backend failed, for the settings UI to explain.
    public private(set) var lastFailureReason: String?

    public var artwork: NSImage? {
        guard let data = snapshot.artworkData else { return nil }
        return NSImage(data: data)
    }

    private var source: (any MediaSource)?
    private var streamTask: Task<Void, Never>?
    private var lastSelection: Date?
    private let reselectCooldown: TimeInterval = 8
    private var observers: [NSObjectProtocol] = []

    public init() {}

    // MARK: Lifecycle

    public func start() {
        guard Preferences.shared.mediaIntegrationEnabled else {
            activeSource = .none
            snapshot = .empty
            return
        }
        Task { await selectSource() }
        installObservers()
    }

    public func stop() {
        streamTask?.cancel()
        streamTask = nil
        let current = source
        source = nil
        Task { await current?.stop() }
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        snapshot = .empty
        activeSource = .none
    }

    /// Called when the user changes media settings.
    public func restart() {
        stop()
        lastSelection = nil
        start()
    }

    private func installObservers() {
        let center = NSWorkspace.shared.notificationCenter
        // After a wake the adapter's connection to the system service is often
        // stale; re-selecting is cheaper than trying to detect that.
        observers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reselectIfAllowed() }
        })
    }

    // MARK: Source selection

    private func reselectIfAllowed() {
        if let lastSelection, Date().timeIntervalSince(lastSelection) < reselectCooldown { return }
        Task { await selectSource() }
    }

    private func selectSource() async {
        lastSelection = Date()
        streamTask?.cancel()
        let previous = source
        source = nil
        await previous?.stop()

        lastFailureReason = nil

        if let adapter = MediaRemoteAdapterSource.configured() {
            let healthy = await adapter.healthCheck()
            if healthy {
                AdapterCompatibility.recordSuccessfulCheck()
                await attach(adapter)
                return
            }
            AdapterCompatibility.recordFailedCheck()
            lastFailureReason = "The Now Playing adapter didn't respond on this macOS build."
            Log.media.notice("Adapter failed its health check; falling back to Apple Events")
        } else if Preferences.shared.mediaRemoteAdapterPath?.isEmpty == false {
            lastFailureReason = "The configured adapter is missing or isn't executable."
        }

        if Preferences.shared.appleEventsFallbackEnabled {
            let appleEvents = AppleEventsMediaSource()
            if await appleEvents.healthCheck() {
                await attach(appleEvents)
                return
            }
        }

        await attach(DisabledMediaSource())
    }

    private func attach(_ newSource: any MediaSource) async {
        source = newSource
        activeSource = newSource.kind
        Log.media.info("Media source: \(newSource.kind.rawValue)")

        let stream = await newSource.updates()
        streamTask = Task { [weak self] in
            for await update in stream {
                guard !Task.isCancelled else { break }
                await MainActor.run { self?.apply(update) }
            }
            // The stream ending means the backend gave up; try the next one
            // down the chain rather than sitting on stale metadata.
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.handleStreamEnded(kind: newSource.kind) }
        }
    }

    private func handleStreamEnded(kind: MediaSourceKind) {
        guard activeSource == kind, kind != .none else { return }
        Log.media.notice("\(kind.rawValue) stream ended; re-selecting")
        snapshot = .empty
        reselectIfAllowed()
    }

    private func apply(_ update: MediaSnapshot) {
        // De-duplicate: position-only ticks update the model but shouldn't be
        // treated as a track change by anything downstream.
        if snapshot.isMateriallyEqual(to: update) {
            snapshot.position = update.position
            snapshot.positionTimestamp = update.positionTimestamp
            snapshot.isPlaying = update.isPlaying
            return
        }
        snapshot = update
    }

    // MARK: Commands

    public func send(_ command: MediaCommand) {
        guard let source else { return }
        Task {
            do {
                try await source.send(command)
            } catch {
                Log.media.error("Media command failed: \(error.localizedDescription)")
            }
        }
    }

    public var canControlPlayback: Bool {
        activeSource != .none && snapshot.hasContent
    }

    public func supports(_ kind: MediaCommandKind) -> Bool {
        snapshot.supportedCommands.contains(kind)
    }
}
