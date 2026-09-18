import AVFoundation
import AppKit
@preconcurrency import ApplicationServices
import CoreMedia
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// The application's single source of truth.
///
/// Owns the activity arbiter, drives every capture and recording flow, and
/// manages the shelf and capture stack. Services stay dumb and testable; the
/// ordering rules and user-visible behaviour live here. Stored state lives in
/// this file; behaviour is grouped by pipeline in the `AppCoordinator+*` files.
@MainActor
@Observable
public final class AppCoordinator {

    // MARK: State

    public internal(set) var arbiter = ActivityArbiter()
    public internal(set) var activity: NotchActivity = .idle
    public internal(set) var shelfItems: [ShelfItem] = []
    public internal(set) var selectedShelfIndex = 0
    public internal(set) var recordingStatus = RecordingStatus()
    public internal(set) var isRecordingPaused = false
    public internal(set) var scrollingFrameCount = 0
    /// Whether "Capture Previous Area" has something to repeat this launch.
    /// Kept in sync when a selection-based capture lands and at startup.
    public internal(set) var hasPreviousArea = false
    /// True from the moment a scrolling session starts until its terminal
    /// event, including the stitching phase. The notch HUD uses this state
    /// instead of sniffing its own message text for the finish/cancel controls.
    public var isScrollingCaptureActive: Bool { scrollingSession != nil }

    /// True while the pointer is over the island. Peeking never expands the
    /// full interface on its own — that needs a click or a shortcut.
    public var isPeeking = false

    /// Which list the expanded player has open, and how many rows it holds.
    /// The island's height is derived from the activity rather than measured
    /// from its content, so a list has to declare its size before it draws.
    public internal(set) var mediaPanel: MediaPanelKind = .none
    public internal(set) var mediaPanelRowCount = 0

    public let media = MediaCoordinator.shared
    public let context = ContextCoordinator.shared
    public let history = HistoryRepository.shared
    public let clipboard = ClipboardStore.shared
    public let clipboardMonitor = ClipboardMonitor.shared
    public let notifications = ProductivityNotificationStore.shared
    public let systemNotifications = SystemNotificationMirror.shared
    public let permissions = PermissionCenter.shared
    public let systemLevels = SystemLevelMonitor.shared
    public let osd = SystemOSDSuppressor.shared
    public let stack = CaptureStack.shared
    public let dictation = DictationCoordinator.shared

    // MARK: Activity island

    /// The resolved multi-activity island. Views read activity detail from
    /// the sources; this carries placement, level and the overlay.
    public internal(set) var islandPresentation = IslandPresentation.empty
    public let islandGesture = IslandGestureState()
    public let transfers = TransferActivityStore.shared
    public let externalActivities = ExternalActivityStore.shared
    public let focusStatus = FocusStatusMonitor.shared
    @ObservationIgnored var islandEngine = IslandPresentationEngine()
    @ObservationIgnored var islandEvents = IslandTransientQueue()
    @ObservationIgnored var islandExpiryTask: Task<Void, Never>?
    @ObservationIgnored var islandExpiryDeadline: Date?
    @ObservationIgnored var islandEventTask: Task<Void, Never>?
    @ObservationIgnored var islandCollapseTask: Task<Void, Never>?
    @ObservationIgnored var islandRefreshScheduled = false
    @ObservationIgnored var mediaActivityStartedAt: Date?
    @ObservationIgnored var recordingActivityStartedAt: Date?
    @ObservationIgnored var islandGestureCoordinator: IslandGestureCoordinator?

    /// Most recent capture the user dismissed, for "restore last".
    var lastDismissed: ShelfItem?
    var shelfTimer: Timer?
    var countdownTask: Task<Void, Never>?
    var captureOperationID: UUID?
    /// The screen rectangle the active scrolling capture is reading from. The
    /// stitched result inherits its display's scale rather than the main
    /// display's, which are different numbers on a mixed-DPI desk.
    var scrollingRegion: CGRect?
    var scrollingSession: ScrollingCaptureSession?
    var scrollingSessionID: UUID?
    var errorTask: Task<Void, Never>?
    var systemLevelTask: Task<Void, Never>?
    var systemNotificationTask: Task<Void, Never>?
    var systemNotificationTaskID: UUID?
    var systemNotificationQueue = SystemNotificationQueue()
    var accessibilityLevelTask: Task<Void, Never>?
    var peekTask: Task<Void, Never>?
    var recordingStartTask: Task<Void, Never>?
    var recordingStartOperationID: UUID?
    var recordingCompletionTask: Task<Void, Never>?
    var recordingSegments: [CaptureAsset] = []
    var recordingInteractionSegments: [RecordingInteractionTimeline] = []
    var pendingRecordingInteractionTimeline: RecordingInteractionTimeline?
    var recordingUsesSmoothCursor = false
    var recordingUsesClickZoom = false
    var pausedRecordingConfiguration: RecordingConfiguration?
    var completedRecordingDuration: TimeInterval = 0
    var isPresentingRecordingCancellation = false
    var recordingStoppedForLowDisk = false
    var editorExportActions: [ObjectIdentifier: (CaptureAsset) -> Void] = [:]
    var voiceOverObservation: NSKeyValueObservation?

    public var windowController: NotchWindowController?
    public var onOpenEditor: ((AnnotationDocumentController) -> Void)?
    public var onOpenPrivacyReview: ((PrivacyReviewSession) -> Void)?
    public var onOpenBugReport: ((BugReportSession) -> Void)?
    public var onOpenComparison: ((VisualComparisonSession) -> Void)?
    public var onOpenSmartExport: ((SmartExportSession) -> Void)?
    public var onOpenRecordingExport: ((RecordingExportSession) -> Void)?
    public var onOpenVideoTrim: ((VideoTrimSession) -> Void)?
    public var onOpenInspector: ((ImageInspectionSession) -> Void)?
    public var onOpenCapturePreview: ((ShelfItem) -> Void)?
    public var onOpenDocumentSummary: ((DocumentSummarySession) -> Void)?
    public var onOpenSettings: (() -> Void)?
    public var onOpenHistory: (() -> Void)?
    public var onOpenClipboard: (() -> Void)?
    public var onOpenProductivity: (() -> Void)?

    /// Up to five results stay in the notch; older ones live in History.
    public static let maximumShelfItems = 5

    public init() {}

    // MARK: Wiring

    public func start() {
        guard AppPaths.ensureDirectories() else {
            present(error: NotchShotError.destinationUnwritable(AppPaths.support.path))
            return
        }
        Preferences.shared.refreshOutputFolderBookmarkIfStale()
        cleanScrollingCaptureStaging()
        Task { [weak self] in
            let hasPrevious = await CaptureService.shared.previousAreaRect != nil
            self?.hasPreviousArea = hasPrevious
        }
        media.start()
        notifications.onChange = { [weak self] in
            self?.refreshActivity()
        }
        systemNotifications.onNotification = { [weak self] snapshot in
            self?.receiveSystemNotification(snapshot)
        }
        systemNotifications.setSessionActive(media.isSessionActive)
        systemNotifications.setEnabled(Preferences.shared.mirrorsSystemNotificationBanners)
        context.onSnapshotChange = { [weak self] snapshot in
            guard let self else { return }
            self.arbiter.context = snapshot
            self.refreshActivity()
            if let snapshot, snapshot.mayInterruptMedia {
                self.announceForAccessibility(
                    snapshot.title + " " + (snapshot.metric ?? ""),
                    priority: .medium
                )
            }
        }
        context.start()
        if history.loadOutcome.permitsManagedCleanup {
            history.applyRetention()
            history.removeUntrackedManagedFiles()
        } else if let message = history.loadRecoveryMessage {
            present(error: NotchShotError.exportFailed(message))
        }
        clipboard.applyRetention()
        clipboard.removeOrphanedImages()
        clipboardMonitor.reconcile()
        history.refreshSpotlightIndex()

        RecordingService.shared.onStatusChange = { [weak self] status in
            guard let self else { return }
            var adjusted = status
            adjusted.elapsed += self.completedRecordingDuration
            self.recordingStatus = adjusted
        }
        RecordingService.shared.onUnexpectedStop = { [weak self] error, recoveryURL in
            Task { await self?.finishRecordingAfterFailure(error, recoveryURL: recoveryURL) }
        }
        RecordingService.shared.onLowDiskThresholdReached = { [weak self] in
            self?.recordingStoppedForLowDisk = true
            self?.stopRecording()
        }

        systemLevels.onChange = { [weak self] level in
            self?.showSystemLevel(level)
        }
        osd.onSystemMediaKey = { [weak self] action in
            self?.systemLevels.applyInterceptedKey(action) ?? false
        }
        FloatingBasketManager.shared.start(coordinator: self)
        // One-time migration: older builds could leave the native helper
        // suspended without a watchdog. Later launches resume only PIDs owned
        // by this process, so one app can never cancel another app's lease.
        if Preferences.shared.hasCompletedFirstRun,
           !Preferences.shared.hasRecoveredLegacySystemOSD,
           osd.hasStoppedSystemOSD {
            presentLegacyOSDRecoveryPrompt()
        }
        // A new install has no legacy suspension to heal. Marking it complete
        // without signalling prevents us from resuming an OSD another utility
        // deliberately paused.
        Preferences.shared.hasRecoveredLegacySystemOSD = true
        osd.stop()
        installVoiceOverObservationIfNeeded()
        // A persisted replacement preference is already explicit opt-in. On
        // macOS 26.5 the replacement also needs Input Monitoring to consume
        // only the media keys before Control Center draws its duplicate OSD.
        reconcileSystemLevelIntegration(
            requestInputAccess: Preferences.shared.suppressesSystemOSD
        )

        // Media presence feeds the arbiter but can never outrank a capture.
        // `observeMedia` re-arms its own tracker, so it must be started exactly
        // once — arming it here as well doubled the trackers on every change.
        // Remove a song notification left by a build that offered this feature.
        LockedMediaNotificationController.shared.clear()
        observeMedia()
        observeDictation()
        startIsland()
        refreshActivity()
    }

    func presentLegacyOSDRecoveryPrompt() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Apple’s system overlay is already paused"
        alert.informativeText = "An older NotchShot build or another utility may own that paused state. Restore it only if brightness and volume overlays stayed missing after the owning app quit."
        alert.addButton(withTitle: "Leave It Alone")
        alert.addButton(withTitle: "Restore Apple Overlay")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            osd.recoverLegacySuspension()
        }
    }

    func observeMedia() {
        arbiter.hasMedia = media.snapshot.hasContent
        systemNotifications.setSessionActive(media.isSessionActive)
        if !media.isSessionActive {
            clearSystemNotifications()
        }
        refreshActivity()
        withObservationTracking {
            _ = media.snapshot.hasContent
            _ = media.snapshot.title
            _ = media.snapshot.artist
            _ = media.snapshot.applicationName
            _ = media.snapshot.isPlaying
            _ = media.isSessionActive
            // The workspace session can resign before loginwindow posts its
            // secure-lock signal. Keep presentation synchronized with it.
            _ = media.isScreenLocked
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeMedia() }
        }
    }

    /// Opens the pane that owns every switch this feature depends on. It is
    /// not a Privacy pane, so it is not one of `PermissionKind`'s deep links.
    public func openNotificationSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Last dictation state announced to VoiceOver, so republished snapshots
    /// (transcript updates) do not re-announce a state the user already heard.
    var lastAnnouncedDictationState: DictationState = .idle

    func observeDictation() {
        dictation.onSnapshotChange = { [weak self] snapshot in
            guard let self else { return }
            if snapshot.state == .idle {
                self.arbiter.dictation = nil
            } else {
                self.arbiter.dictation = snapshot
            }
            self.refreshActivity()
            // Announce transitions only. The snapshot is republished on every
            // transcript update, so announcing unconditionally made VoiceOver
            // repeat "Dictation listening" for the whole session.
            guard snapshot.state != self.lastAnnouncedDictationState else { return }
            self.lastAnnouncedDictationState = snapshot.state
            switch snapshot.state {
            case .listening: self.announceForAccessibility("Dictation listening", priority: .medium)
            case .finalizing: self.announceForAccessibility("Finalizing", priority: .medium)
            case .completed: self.announceForAccessibility("Inserted", priority: .medium)
            case .copied: self.announceForAccessibility("Copied", priority: .medium)
            case .cancelled: self.announceForAccessibility("Cancelled", priority: .medium)
            case .failed(let msg): self.announceForAccessibility("Dictation failed: \(msg)", priority: .high)
            default: break
            }
        }
        dictation.onRequestDisplay = { [weak self] displayID in
            guard let self, let displayID else { return }
            // Ensure dictation display is active – windowController's activeDisplayID will be coerced by hover logic,
            // but we can hint by moving pointer focus? For now just ensure arbiter dictation has display.
            self.arbiter.dictation?.displayID = displayID
            self.refreshActivity()
            // Force windowController to use this display as active for dictation duration
            // The windowController already picks hoveredDisplay or mouse location; dictation snapshot's displayID drives panel routing.
        }
        dictation.onAnnounce = { [weak self] msg in
            self?.announceForAccessibility(msg, priority: .medium)
        }
        withObservationTracking {
            _ = dictation.snapshot
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeDictation() }
        }
    }

    // MARK: Errors

    /// History is an index over already-created capture files. A persistence
    /// failure must be visible, but it must not turn a successful capture or
    /// export into a misleading claim that the underlying file was lost.
    @discardableResult
    func persistHistory() -> Bool {
        do {
            try history.save()
            return true
        } catch {
            present(error: NotchShotError.exportFailed(
                "The capture was saved, but NotchShot could not update History: \(error.localizedDescription)"
            ))
            return false
        }
    }

    func ensureScreenRecordingPermission() -> Bool {
        // The value can change while NotchShot is in the background with System
        // Settings open. Re-read the current-process preflight before deciding
        // whether to request or remediate access.
        permissions.refresh()
        if permissions.screenRecording.isUsable { return true }
        let granted = permissions.requestScreenRecordingAccess()
        guard !granted else { return true }

        // Three different situations, three different remedies. "Approved but
        // macOS still says no" is the one that used to be indistinguishable from
        // a plain refusal, which left no way forward.
        if permissions.hasUnstableSigningIdentity {
            // Reported ahead of the two TCC states because it outranks them: an
            // ad-hoc build cannot hold a grant at all, so telling the user to
            // approve or reset one sends them round a loop that cannot end.
            present(error: NotchShotError.unstableSigningIdentity)
        } else if permissions.isScreenRecordingGrantStale {
            present(error: NotchShotError.screenRecordingGrantStale)
        } else {
            present(error: permissions.requiresScreenRecordingRelaunch
                ? NotchShotError.screenRecordingPermissionPending
                : NotchShotError.screenRecordingPermissionDenied)
        }
        return false
    }

    // MARK: Processing label

    /// Claims the single processing slot and hands back the label, so the
    /// matching release can prove it is still the one being shown.
    func beginProcessing(_ label: String) -> String {
        arbiter.isProcessing = label
        refreshActivity()
        return label
    }

    /// Releases the processing slot only if this operation still owns it.
    ///
    /// There is one slot and several flows that can run at once — compress,
    /// convert, background removal, clipboard OCR. Each of them used to clear
    /// the slot unconditionally on finishing, so the first flow to end wiped
    /// the label belonging to a flow that was still working, and the notch went
    /// blank while the Mac was visibly busy.
    func endProcessing(_ label: String) {
        guard arbiter.isProcessing == label else { return }
        arbiter.isProcessing = nil
        refreshActivity()
    }

    /// Sweeps scrolling-capture staging folders a crash or force-quit left in
    /// the managed captures directory. Preserved *finished* frame folders are
    /// user-visible recovery output and are deliberately left alone.
    func cleanScrollingCaptureStaging() {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: AppPaths.captures,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }
        for url in contents {
            let name = url.lastPathComponent
            guard name.hasPrefix(".scrolling-frames-"), name.hasSuffix(".partial") else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    public func present(error: Error) {
        let message = (error as? NotchShotError)?.notchMessage
            ?? error.localizedDescription
        Log.app.error("\(message)")
        announceForAccessibility(message, priority: .high)

        errorTask?.cancel()
        arbiter.error = message
        refreshActivity()
        errorTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.arbiter.error = nil
                self?.refreshActivity()
            }
        }
    }

    public func dismissError() {
        errorTask?.cancel()
        arbiter.error = nil
        refreshActivity()
    }

    func announceForAccessibility(
        _ message: String,
        priority: NSAccessibilityPriorityLevel
    ) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: priority.rawValue,
            ]
        )
    }

    func playCaptureSound() {
        guard Preferences.shared.playsCaptureSound else { return }
        NSSound(named: "Grab")?.play()
    }
}
