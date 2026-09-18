import CoreGraphics
import Foundation
import Testing
@testable import NotchShotKit

/// The presenter overlay belongs to the recording session, not to a successful
/// file write. A narrow injectable controller pins terminal cleanup without
/// starting an AppKit camera or event monitors.
@MainActor
private final class RecordingPresentationSpy: RecordingPresentationControlling {
    var startResult = true
    var startCount = 0
    var stopCount = 0

    func start(
        options: RecordingPresentationOptions,
        displayID: CGDirectDisplayID?,
        captureFrame: CGRect?
    ) async -> Bool {
        startCount += 1
        return startResult
    }

    func stop() {
        stopCount += 1
    }
}

@Suite("Recording presentation lifecycle")
@MainActor
struct RecordingPresentationLifecycleTests {
    private func presenterConfiguration() -> RecordingConfiguration {
        RecordingConfiguration(
            target: .display(1),
            audioSources: [],
            showsPresenterCamera: true
        )
    }

    private func coordinatorWithSpy() -> (AppCoordinator, RecordingPresentationSpy) {
        let coordinator = AppCoordinator()
        let spy = RecordingPresentationSpy()
        coordinator.recordingPresentation = spy
        return (coordinator, spy)
    }

    @Test("A successful stop tears the overlay down")
    func successfulStopStopsOverlay() {
        let (coordinator, spy) = coordinatorWithSpy()
        coordinator.stopRecordingPresentationIfSessionEnded(sessionStillRecording: false)
        #expect(spy.stopCount == 1)
    }

    @Test("A failed finalization still tears the overlay down")
    func failedFinalizationStopsOverlay() {
        let (coordinator, spy) = coordinatorWithSpy()
        // The writer ended even though finalization failed, so the session is
        // terminal and the camera must not be left running.
        coordinator.stopRecordingPresentationIfSessionEnded(sessionStillRecording: false)
        #expect(spy.stopCount == 1)
    }

    @Test("A successful pause tears the overlay down")
    func successfulPauseStopsOverlay() {
        let (coordinator, spy) = coordinatorWithSpy()
        coordinator.stopRecordingPresentationIfSessionEnded(sessionStillRecording: false)
        #expect(spy.stopCount == 1)
    }

    @Test("A failed pause while still recording keeps the presenter on camera")
    func failedPauseKeepsOverlay() {
        let (coordinator, spy) = coordinatorWithSpy()
        coordinator.stopRecordingPresentationIfSessionEnded(sessionStillRecording: true)
        #expect(spy.stopCount == 0, "the live recording still contains the presenter")
    }

    @Test("Cancelling a pending start tears the overlay down")
    func cancellationStopsOverlay() async {
        let (coordinator, spy) = coordinatorWithSpy()
        coordinator.recordingStartTask = Task {}
        coordinator.cancelPendingRecordingStart()

        // The cancellation teardown hops onto the main actor.
        for _ in 0 ..< 200 where spy.stopCount == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(coordinator.recordingStartTask == nil)
        #expect(spy.stopCount == 1)
    }

    @Test("A failed resume tears the overlay down")
    func failedResumeStopsOverlay() async {
        let (coordinator, spy) = coordinatorWithSpy()
        spy.startResult = false
        coordinator.isRecordingPaused = true
        coordinator.pausedRecordingConfiguration = presenterConfiguration()

        coordinator.resumeRecording()
        await coordinator.recordingStartTask?.value

        #expect(spy.startCount == 1)
        #expect(spy.stopCount == 1, "an overlay that failed to restart must not linger")
    }

    @Test("An unexpected recording stop tears the overlay down and keeps recovery files")
    func unexpectedStopStopsOverlay() async throws {
        let (coordinator, spy) = coordinatorWithSpy()
        let recoveryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: recoveryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: recoveryDirectory) }
        let scratch = recoveryDirectory.appendingPathComponent("partial.mp4")
        try Data("partial recording".utf8).write(to: scratch)

        await coordinator.finishRecordingAfterFailure(
            .recordingFailed("ScreenCaptureKit stopped unexpectedly"),
            recoveryURL: nil
        )

        #expect(spy.stopCount == 1)
        #expect(
            FileManager.default.fileExists(atPath: scratch.path),
            "tearing down presentation must not discard recoverable footage"
        )
    }
}
