import Foundation
import Testing
@testable import NotchShotKit

@MainActor
private final class ManualContextClock {
    var now = Date(timeIntervalSinceReferenceDate: 900_000_000)
    var scheduled: [(Date, @MainActor () -> Void)] = []
    var timing: ContextTiming {
        ContextTiming(now: { self.now }, schedule: { deadline, action in
            // Intentionally allow cancelled callbacks to fire: generations must
            // reject stale work even when a callback has already been queued.
            self.scheduled.append((deadline, action))
            return {}
        })
    }

    func advance(to date: Date) {
        now = date
        let due = scheduled.filter { $0.0 <= date }
        scheduled.removeAll { $0.0 <= date }
        for (_, action) in due { action() }
    }
}

@Suite("Cached context timing regressions")
@MainActor
struct ContextTimingRegressionTests {
    @Test("Cached events advance through imminent, start, and end without EventKit refresh")
    func calendarBoundaries() throws {
        let clock = ManualContextClock()
        let service = CalendarGlanceService(timing: clock.timing, mayInterruptMedia: { true })
        let first = event("First", start: clock.now.addingTimeInterval(660), duration: 300)
        let second = event("Second", start: first.endDate.addingTimeInterval(120), duration: 300)
        var latest: ContextSnapshot?
        service.onSnapshotChange = { latest = $0 }
        service.replaceCachedEvents([first, second])
        #expect(latest?.metric == "11m")
        #expect(latest?.mayInterruptMedia == false)
        #expect(!clock.scheduled.isEmpty)
        clock.advance(to: first.startDate.addingTimeInterval(-600))
        #expect(latest?.metric == "10m")
        #expect(latest?.mayInterruptMedia == true)
        clock.advance(to: first.startDate)
        #expect(latest?.metric == "Now · 5m left")
        #expect(latest?.mayInterruptMedia == false)
        clock.advance(to: first.startDate.addingTimeInterval(60.001))
        #expect(latest?.metric == "Now · 3m left")
        clock.advance(to: first.endDate)
        #expect(latest?.title == "Second")
        #expect(latest?.events.map(\.id) == ["Second"])
        clock.advance(to: second.endDate)
        #expect(latest == nil)
        #expect(clock.scheduled.isEmpty)
    }

    @Test("Calendar replacement and stop invalidate already queued reevaluations")
    func calendarCancellation() {
        let clock = ManualContextClock()
        let service = CalendarGlanceService(timing: clock.timing)
        var changes = 0
        service.onSnapshotChange = { _ in changes += 1 }
        service.replaceCachedEvents([event("Old", start: clock.now.addingTimeInterval(660), duration: 300)])
        service.replaceCachedEvents([event("New", start: clock.now.addingTimeInterval(3600), duration: 300)])
        service.stop()
        let stoppedChanges = changes
        clock.advance(to: clock.now.addingTimeInterval(7200))
        #expect(changes == stoppedChanges)
        #expect(service.events.isEmpty)
        #expect(clock.scheduled.isEmpty)
    }

    @Test("Legacy completed timer and voice cards expire and restore the next persistent source")
    func persistentExpiry() {
        let clock = ManualContextClock()
        let coordinator = ContextCoordinator(timing: clock.timing)
        coordinator.updateCalendar(ContextSnapshot(kind: .calendar, title: "Meeting"))
        let timerDeadline = clock.now.addingTimeInterval(12)
        coordinator.updateTimer(ContextSnapshot(kind: .timer, title: "Timer complete", expiresAt: timerDeadline))
        let voiceDeadline = clock.now.addingTimeInterval(6)
        coordinator.updateVoiceNote(ContextSnapshot(kind: .voiceNote, title: "Voice complete", expiresAt: voiceDeadline))
        #expect(coordinator.snapshot?.kind == .voiceNote)
        clock.advance(to: voiceDeadline)
        #expect(coordinator.snapshot?.kind == .timer)
        clock.advance(to: timerDeadline)
        #expect(coordinator.snapshot?.kind == .calendar)
        #expect(clock.scheduled.isEmpty)
    }

    @Test("Replaced legacy expiry cannot overwrite a newer transient")
    func staleExpiry() {
        let clock = ManualContextClock()
        let coordinator = ContextCoordinator(timing: clock.timing)
        coordinator.updateCalendar(ContextSnapshot(kind: .calendar, title: "Meeting"))
        let timerDeadline = clock.now.addingTimeInterval(12)
        coordinator.updateTimer(ContextSnapshot(kind: .timer, title: "Done", expiresAt: timerDeadline))
        coordinator.present(ContextSnapshot(kind: .power, title: "Power", expiresAt: clock.now.addingTimeInterval(20)))
        clock.advance(to: timerDeadline)
        #expect(coordinator.snapshot?.title == "Power")
        clock.advance(to: clock.now.addingTimeInterval(8))
        #expect(coordinator.snapshot?.kind == .calendar)
    }

    private func event(_ title: String, start: Date, duration: TimeInterval) -> CalendarEventSnapshot {
        CalendarEventSnapshot(id: title, calendarIdentifier: "test", title: title,
                              startDate: start, endDate: start.addingTimeInterval(duration),
                              isAllDay: false, colorHex: "#123456")
    }
}
