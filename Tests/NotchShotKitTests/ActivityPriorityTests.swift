import Testing
@testable import NotchShotKit

/// The product rule is: recording → capture ready → file drop → expanded →
/// media → idle, with selection and countdown above recording because they are
/// modal to the user's current action.
@Suite("Activity priority")
struct ActivityPriorityTests {

    @Test("Idle resolves when nothing is happening")
    func idle() {
        #expect(ActivityArbiter().resolve() == .idle)
    }

    @Test("Media never outranks a recording")
    func recordingBeatsMedia() {
        var arbiter = ActivityArbiter()
        arbiter.hasMedia = true
        arbiter.isRecording = true
        #expect(arbiter.resolve() == .recording)
    }

    @Test("A track change cannot interrupt a finished capture")
    func resultBeatsMedia() {
        var arbiter = ActivityArbiter()
        arbiter.hasMedia = true
        arbiter.hasResult = true
        #expect(arbiter.resolve() == .result)
    }

    @Test("Recording outranks a pending result")
    func recordingBeatsResult() {
        var arbiter = ActivityArbiter()
        arbiter.hasResult = true
        arbiter.isRecording = true
        #expect(arbiter.resolve() == .recording)
    }

    @Test("Selection outranks recording, so picking a region stays visible")
    func selectionBeatsRecording() {
        var arbiter = ActivityArbiter()
        arbiter.isRecording = true
        arbiter.selection = .area
        #expect(arbiter.resolve() == .selecting(.area))
    }

    @Test("Countdown outranks recording")
    func countdownBeatsRecording() {
        var arbiter = ActivityArbiter()
        arbiter.isRecording = true
        arbiter.countdown = (3, .display)
        #expect(arbiter.resolve() == .countdown(remaining: 3, intent: .display))
    }

    @Test("Errors take the notch over everything")
    func errorWins() {
        var arbiter = ActivityArbiter()
        arbiter.isRecording = true
        arbiter.hasResult = true
        arbiter.error = "boom"
        #expect(arbiter.resolve() == .error("boom"))
    }

    @Test("File drop outranks a deliberate expansion")
    func dropBeatsExpanded() {
        var arbiter = ActivityArbiter()
        arbiter.userExpanded = true
        arbiter.isDraggingFiles = true
        #expect(arbiter.resolve() == .expanded)
    }

    @Test("Expanded outranks media")
    func expandedBeatsMedia() {
        var arbiter = ActivityArbiter()
        arbiter.hasMedia = true
        arbiter.userExpanded = true
        #expect(arbiter.resolve() == .expanded)
    }

    @Test("Media shows only when nothing else is competing")
    func mediaWhenQuiet() {
        var arbiter = ActivityArbiter()
        arbiter.hasMedia = true
        #expect(arbiter.resolve() == .media)
    }

    @Test("Declared priorities agree with the documented ordering")
    func priorityOrdering() {
        #expect(NotchActivity.error("x").priority > NotchActivity.selecting(.area).priority)
        #expect(NotchActivity.selecting(.area).priority > NotchActivity.recording.priority)
        #expect(NotchActivity.recording.priority > NotchActivity.result.priority)
        #expect(NotchActivity.result.priority > NotchActivity.expanded.priority)
        #expect(NotchActivity.expanded.priority > NotchActivity.media.priority)
        #expect(NotchActivity.media.priority > NotchActivity.idle.priority)
    }

    @Test("User-driven activities are marked interactive so timers don't fire")
    func interactiveFlags() {
        #expect(NotchActivity.recording.isInteractive)
        #expect(NotchActivity.selecting(.area).isInteractive)
        #expect(NotchActivity.processing("x").isInteractive)
        #expect(!NotchActivity.media.isInteractive)
        #expect(!NotchActivity.idle.isInteractive)
    }
}
