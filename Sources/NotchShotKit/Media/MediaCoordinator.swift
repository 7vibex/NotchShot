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

    public private(set) var snapshot = MediaSnapshot.empty {
        didSet { syncLiveAudioMeter() }
    }
    public private(set) var activeSource: MediaSourceKind = .none
    /// Decoded only when artwork bytes change. Rebuilding an `NSImage` from the
    /// same data on every two-second position tick needlessly decodes on the UI
    /// thread and can make the notch animation hitch.
    public private(set) var artwork: NSImage?
    /// Readable cover-derived accent cached alongside `artwork`, for the compact
    /// playback indicator. White is retained when artwork is absent or neutral.
    public private(set) var artworkAccentColor: NSColor = ArtworkAccentColor.fallback
    /// Icon of the app that owns playback, resolved from the running system so
    /// no third-party artwork is bundled. Cached alongside the snapshot because
    /// `NSWorkspace` icon lookups hit the disk and the artwork badge would
    /// otherwise repeat one on every position tick.
    public private(set) var sourceApplicationIcon: NSImage?
    @ObservationIgnored private var artworkLoad: Task<Void, Never>?
    /// Session and display state let the notch remove interaction at the lock
    /// window and stop decorative animation while the screens are asleep.
    public private(set) var isSessionActive = true
    /// True only while the secure Lock Screen is raised (`com.apple.screenIsLocked`).
    ///
    /// Deliberately narrower than `isSessionActive`, which also goes dark for
    /// a Fast User Switch. Only the lock state may drive a Lock Screen
    /// notification: posting one for a switched-away session would put a
    /// stale song card in front of the user who returns.
    public private(set) var isScreenLocked = false
    public private(set) var areScreensAwake = true {
        didSet { syncLiveAudioMeter() }
    }

    /// Tells the live meter which app to listen to, and whether to at all.
    private func syncLiveAudioMeter() {
        LiveAudioMeter.shared.updateSource(
            bundleID: snapshot.applicationBundleID,
            isPlaying: snapshot.isPlaying,
            screensAwake: areScreensAwake
        )
    }
    /// Set when every backend failed, for the settings UI to explain.
    public private(set) var lastFailureReason: String?
    /// The last skip asked for from NotchShot, so the next cover can slide
    /// in from that side. A hardware media key skips without passing through
    /// here, and its cover crossfades as before.
    public private(set) var lastSkip: MediaSkip?

    private var source: (any MediaSource)?
    private var streamTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var selectionGeneration: UInt = 0
    private var lastSelection: Date?
    private let reselectCooldown: TimeInterval = 8
    /// Retries after a running player didn't answer, and the task waiting on
    /// the next one. Bounded so a player that never answers can't keep
    /// spending a two-second script timeout.
    private var fallbackRetries = 0
    private let fallbackRetryLimit = 3
    private var fallbackRetryTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []

    public init() {}

    // MARK: Lifecycle

    public func start() {
        guard Preferences.shared.mediaIntegrationEnabled else {
            activeSource = .none
            snapshot = .empty
            return
        }
        // Seeded only where the observers that end it are installed: unlock
        // still runs `setSessionActive(true)` and its fresh selection.
        let session = ScreenLockSignal.current()
        isScreenLocked = session.screenIsLocked
        isSessionActive = session.sessionIsActive
        scheduleSelection()
        installObservers()
    }

    public func stop() {
        let current = detachSource()
        Task { await current?.stop() }
    }

    /// Quit uses the awaited form so a stubborn external adapter is reaped
    /// before AppKit lets the process exit.
    public func stopAndWait() async {
        let current = detachSource()
        await current?.stop()
    }

    private func detachSource() -> (any MediaSource)? {
        selectionGeneration &+= 1
        selectionTask?.cancel()
        selectionTask = nil
        fallbackRetryTask?.cancel()
        fallbackRetryTask = nil
        streamTask?.cancel()
        streamTask = nil
        let current = source
        source = nil
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        for observer in distributedObservers {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        distributedObservers.removeAll()
        snapshot = .empty
        artworkLoad?.cancel()
        artwork = nil
        artworkAccentColor = ArtworkAccentColor.fallback
        sourceApplicationIcon = nil
        activeSource = .none
        return current
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
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.areScreensAwake = true
                self?.reselectIfAllowed()
            }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.areScreensAwake = false }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.areScreensAwake = true }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setSessionActive(false) }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.setSessionActive(true)
            }
        })

        // Opening Spotify or Music after the last selection found nothing to
        // follow. Nothing else re-selects until a wake, so music stayed off
        // for a whole session when the player started after NotchShot.
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let bundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, let bundleID,
                      AppleEventsMediaSource.playerBundleIdentifiers.contains(bundleID),
                      Preferences.shared.appleEventsFallbackEnabled,
                      self.activeSource == .none else { return }
                self.fallbackRetries = 0
                self.lastSelection = nil
                self.scheduleSelection()
            }
        })

        let distributed = DistributedNotificationCenter.default()
        for name in [ScreenLockSignal.lockedNotification, ScreenLockSignal.unlockedNotification] {
            distributedObservers.append(distributed.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let name = notification.name
                MainActor.assumeIsolated {
                    guard let active = ScreenLockSignal.sessionIsActive(for: name) else {
                        return
                    }
                    self?.setScreenLocked(!active)
                }
            })
        }
    }

    private func setSessionActive(_ active: Bool) {
        guard active != isSessionActive else { return }
        isSessionActive = active
        Log.media.notice("Screen session is now \(active ? "unlocked" : "locked")")
        guard active else { return }
        // Locking can leave either bridge connected but stale. An
        // unconditional fresh selection restores the current track as soon as
        // the user unlocks without ever controlling playback.
        lastSelection = nil
        scheduleSelection()
    }

    private func setScreenLocked(_ locked: Bool) {
        guard locked != isScreenLocked else { return }
        isScreenLocked = locked
        setSessionActive(!locked)
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
                fallbackRetries = 0
                await attach(appleEvents, generation: generation)
                return
            }
            if PermissionCenter.shared.pendingRemediation == .automation {
                lastFailureReason = "Music and Spotify access is denied. Allow Automation in System Settings."
            } else {
                retryFallbackLater(generation: generation)
            }
        }

        await attach(DisabledMediaSource(), generation: generation)
    }

    /// A running player that didn't answer may only be busy: still
    /// launching, or held by macOS's first "control Spotify?" prompt, which
    /// outlasts the check's timeout. Without a retry, music stayed off until
    /// the next relaunch even after the user clicked Allow.
    private func retryFallbackLater(generation: UInt) {
        guard fallbackRetries < fallbackRetryLimit else { return }
        let playerIsRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier.map(AppleEventsMediaSource.playerBundleIdentifiers.contains) ?? false
        }
        guard playerIsRunning else { return }
        fallbackRetries += 1
        fallbackRetryTask?.cancel()
        fallbackRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, !Task.isCancelled, self.selectionGeneration == generation else { return }
            self.fallbackRetryTask = nil
            self.scheduleSelection()
        }
    }

    private func attach(_ newSource: any MediaSource, generation: UInt) async {
        guard isCurrentSelection(generation) else {
            await newSource.stop()
            return
        }
        source = newSource
        activeSource = newSource.kind
        // Public: which bridge is live is the first question when music
        // doesn't show, and the name says nothing about the user.
        Log.media.info("Media source: \(newSource.kind.rawValue, privacy: .public)")

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
        guard LockedMediaSnapshotPolicy.shouldClearAfterStreamEnds(
            sessionIsActive: isSessionActive
        ) else {
            // loginwindow can interrupt either bridge. Keep the last confirmed
            // track for the opted-in display-only card; unlock always performs
            // a fresh source selection.
            Log.media.notice("\(kind.rawValue) stream ended while locked; preserving the last track")
            return
        }
        Log.media.notice("\(kind.rawValue) stream ended; re-selecting")
        snapshot = .empty
        artworkLoad?.cancel()
        artwork = nil
        artworkAccentColor = ArtworkAccentColor.fallback
        sourceApplicationIcon = nil
        reselectIfAllowed()
    }

    private func apply(_ update: MediaSnapshot) {
        guard let update = LockedMediaSnapshotPolicy.acceptedUpdate(
            current: snapshot,
            proposed: update,
            sessionIsActive: isSessionActive
        ) else { return }

        // De-duplicate: position-only ticks update the model but shouldn't be
        // treated as a track change by anything downstream.
        if snapshot.isMateriallyEqual(to: update) {
            snapshot.position = update.position
            snapshot.positionTimestamp = update.positionTimestamp
            snapshot.isPlaying = update.isPlaying
            return
        }
        if snapshot.artworkData != update.artworkData {
            loadArtwork(from: update.artworkData)
        }
        if snapshot.applicationBundleID != update.applicationBundleID {
            sourceApplicationIcon = Self.applicationIcon(for: update.applicationBundleID)
        }
        snapshot = update
    }

    /// Decodes cover art off the main thread, at the size the notch draws it.
    ///
    /// Players hand over covers up to 1000+ px. Decoding that on the main
    /// thread hitched the notch on every track change, and drawing it into a
    /// 20–56 pt tile made the GPU minify a huge texture every frame, which is
    /// what made the cover shimmer while it moved. The previous cover stays up
    /// until the new one is ready, so a track change never flashes the
    /// placeholder.
    private func loadArtwork(from data: Data?) {
        artworkLoad?.cancel()
        guard let data else {
            artworkLoad = nil
            artwork = nil
            artworkAccentColor = ArtworkAccentColor.fallback
            return
        }
        artworkLoad = Task { [weak self] in
            let thumbnail = await Task.detached(priority: .userInitiated) {
                ArtworkThumbnail.make(from: data)
            }.value
            guard !Task.isCancelled, let self else { return }
            let image = thumbnail.map(ArtworkThumbnail.image(from:))
            self.artwork = image
            self.artworkAccentColor = ArtworkAccentColor.extract(from: image)
        }
    }

    // MARK: Commands

    public func send(_ command: MediaCommand) {
        guard let source else { return }
        switch command {
        case .nextTrack: lastSkip = MediaSkip(isForward: true, date: Date())
        case .previousTrack: lastSkip = MediaSkip(isForward: false, date: Date())
        default: break
        }
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

    private static func applicationIcon(for bundleID: String?) -> NSImage? {
        guard
            let bundleID,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 32, height: 32)
        return icon
    }
}
