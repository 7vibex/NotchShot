import Foundation
import Testing
@testable import NotchShotKit

/// The product rule is: recording → file drop → capture ready → expanded →
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
        #expect(arbiter.resolve() == .fileDrop)
    }

    @Test("An active file drag temporarily replaces an existing shelf")
    func dropBeatsResult() {
        var arbiter = ActivityArbiter()
        arbiter.hasResult = true
        arbiter.isDraggingFiles = true
        #expect(arbiter.resolve() == .fileDrop)
    }

    @Test("Expanded outranks media")
    func expandedBeatsMedia() {
        var arbiter = ActivityArbiter()
        arbiter.hasMedia = true
        arbiter.userExpanded = true
        #expect(arbiter.resolve() == .expanded)
    }

    @Test("A visible system notification waits for deliberate and active work but outranks media")
    func systemNotificationPriority() {
        let notification = SystemNotificationSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            sourceName: "Messages",
            title: "New message",
            body: "Hello",
            receivedAt: Date(timeIntervalSince1970: 1)
        )
        var arbiter = ActivityArbiter()
        arbiter.hasMedia = true
        arbiter.systemNotification = notification
        #expect(arbiter.resolve() == .systemNotification(notification))

        arbiter.userExpanded = true
        #expect(arbiter.resolve() == .expanded)
        arbiter.userExpanded = false
        arbiter.isRecording = true
        #expect(arbiter.resolve() == .recording)
    }

    @Test("Media shows only when nothing else is competing")
    func mediaWhenQuiet() {
        var arbiter = ActivityArbiter()
        arbiter.hasMedia = true
        #expect(arbiter.resolve() == .media)
    }

    @Test("Transient context can appear above media while passive calendar waits")
    func contextualPriority() {
        var arbiter = ActivityArbiter()
        arbiter.hasMedia = true
        arbiter.context = ContextSnapshot(
            kind: .calendar,
            title: "Next",
            mayInterruptMedia: false
        )
        #expect(arbiter.resolve() == .media)

        let power = ContextSnapshot(
            kind: .power,
            title: "Charging",
            mayInterruptMedia: true
        )
        arbiter.context = power
        #expect(arbiter.resolve() == .context(power))
        arbiter.hasResult = true
        #expect(arbiter.resolve() == .result)
    }

    /// Walks the documented ordering top-down against the arbiter itself.
    /// Every source is live at once, and removing the winner must reveal
    /// exactly the next rung — so a reordering cannot pass by agreeing with a
    /// second, parallel declaration of the rule.
    @Test("The arbiter resolves the whole documented ordering, rung by rung")
    func fullOrdering() {
        let context = ContextSnapshot(kind: .power, title: "Charging", mayInterruptMedia: true)
        let level = SystemLevel(kind: .volume, value: 0.5, isMuted: false)
        let notification = SystemNotificationSnapshot(
            sourceName: "Mail",
            title: "New mail",
            body: "Review",
            receivedAt: Date(timeIntervalSince1970: 1)
        )
        var arbiter = ActivityArbiter()
        arbiter.error = "boom"
        arbiter.selection = .area
        arbiter.countdown = (remaining: 3, intent: .area)
        arbiter.isRecording = true
        arbiter.isProcessing = "Stitching"
        arbiter.hasResult = true
        arbiter.isDraggingFiles = true
        arbiter.userExpanded = true
        arbiter.systemNotification = notification
        arbiter.systemLevel = level
        arbiter.context = context
        arbiter.hasMedia = true

        #expect(arbiter.resolve() == .error("boom"))
        arbiter.error = nil
        #expect(arbiter.resolve() == .selecting(.area))
        arbiter.selection = nil
        #expect(arbiter.resolve() == .countdown(remaining: 3, intent: .area))
        arbiter.countdown = nil
        #expect(arbiter.resolve() == .recording)
        arbiter.isRecording = false
        #expect(arbiter.resolve() == .processing("Stitching"))
        arbiter.isProcessing = nil
        #expect(arbiter.resolve() == .fileDrop)
        arbiter.isDraggingFiles = false
        #expect(arbiter.resolve() == .result)
        arbiter.hasResult = false
        #expect(arbiter.resolve() == .expanded)
        arbiter.userExpanded = false
        #expect(arbiter.resolve() == .systemNotification(notification))
        arbiter.systemNotification = nil
        #expect(arbiter.resolve() == .systemLevel(level))
        arbiter.systemLevel = nil
        #expect(arbiter.resolve() == .context(context))
        arbiter.context = nil
        #expect(arbiter.resolve() == .media)
        arbiter.hasMedia = false
        #expect(arbiter.resolve() == .idle)
    }

    @Test("A passive context waits for media but still beats idle")
    func passiveContextRanksBelowMedia() {
        let passive = ContextSnapshot(
            kind: .power,
            title: "Charging",
            mayInterruptMedia: false
        )
        var arbiter = ActivityArbiter()
        arbiter.context = passive
        arbiter.hasMedia = true
        #expect(arbiter.resolve() == .media)
        arbiter.hasMedia = false
        #expect(arbiter.resolve() == .context(passive))
    }

    @Test("User-driven activities are marked interactive so timers don't fire")
    func interactiveFlags() {
        #expect(NotchActivity.fileDrop.isInteractive)
        #expect(NotchActivity.recording.isInteractive)
        #expect(NotchActivity.selecting(.area).isInteractive)
        #expect(NotchActivity.processing("x").isInteractive)
        #expect(!NotchActivity.media.isInteractive)
        #expect(!NotchActivity.systemNotification(SystemNotificationSnapshot(
            sourceName: "Mail",
            title: "Message",
            body: ""
        )).isInteractive)
        #expect(!NotchActivity.idle.isInteractive)
    }
}
