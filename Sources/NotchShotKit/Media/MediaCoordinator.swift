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
    private var selectionTask: Task<Void, Never>?
    private var selectionGeneration: UInt = 0
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
        scheduleSelection()
        installObservers()
    }

    public func stop() {
        selectionGeneration &+= 1
        selectionTask?.cancel()
        selectionTask = nil
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
        scheduleSelection()
    }

    private func scheduleSelection() {
        selectionGeneration &+= 1
        let generation = selectionGeneration
        selectionTask?.cancel()
        selectionTask = Task { [weak self] in
            await self?.selectSource(generation: generation)
            guard let self, self.selectionGeneration == generation else { return }
            self.selectionTask = nil
        }
    }

    private func isCurrentSelection(_ generation: UInt) -> Bool {
        !Task.isCancelled
            && selectionGeneration == generation
            && Preferences.shared.mediaIntegrationEnabled
    }

    private func selectSource(generation: UInt) async {
        guard isCurrentSelection(generation) else { return }
        lastSelection = Date()
        streamTask?.cancel()
        let previous = source
        source = nil
        await previous?.stop()
        guard isCurrentSelection(generation) else { return }

        lastFailureReason = nil

        if let adapter = MediaRemoteAdapterSource.configured() {
            let healthy = await adapter.healthCheck()
            guard isCurrentSelection(generation) else {
                await adapter.stop()
                return
            }
            if healthy {
                AdapterCompatibility.recordSuccessfulCheck()
                await attach(adapter, generation: generation)
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
            let healthy = await appleEvents.healthCheck()
            guard isCurrentSelection(generation) else {
                await appleEvents.stop()
                return
            }
            if healthy {
                await attach(appleEvents, generation: generation)
                return
            }
        }

        await attach(DisabledMediaSource(), generation: generation)
    }

    private func attach(_ newSource: any MediaSource, generation: UInt) async {
        guard isCurrentSelection(generation) else {
            await newSource.stop()
            return
        }
        source = newSource
        activeSource = newSource.kind
        Log.media.info("Media source: \(newSource.kind.rawValue)")

        let stream = await newSource.updates()
        guard isCurrentSelection(generation), source?.kind == newSource.kind else {
            await newSource.stop()
            return
        }
        streamTask = Task { [weak self] in
            for await update in stream {
                guard !Task.isCancelled else { break }
                await MainActor.run { self?.apply(update) }
            }
            // The stream ending means the backend gave up; try the next one
            // down the chain rather than sitting on stale metadata.
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self?.selectionGeneration == generation else { return }
                self?.handleStreamEnded(kind: newSource.kind)
            }
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
