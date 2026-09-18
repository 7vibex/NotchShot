import Foundation
import NotchShotAIReporterSupport
import Testing
@testable import NotchShotKit

/// The external activity store should arm exactly one expiry wake-up and only
/// replace it when the registry's effective next deadline actually moves.
@Suite("External activity expiry scheduling")
@MainActor
struct ExternalActivityStoreExpiryTests {
    static let t0 = Date(timeIntervalSince1970: 6_000_000)

    private func temporarySocketPath() -> String {
        "/tmp/ns-expiry-\(getpid())-\(UInt32.random(in: 0 ... .max)).sock"
    }

    private func start(_ id: String, title: String, expiresIn: TimeInterval) -> LiveActivityUpdate {
        LiveActivityUpdate(command: .start, id: id, title: title, expiresIn: expiresIn)
    }

    @Test("Updates that keep the same effective deadline reuse the expiry task")
    func deadlineEqualityReusesTask() {
        let store = ExternalActivityStore(socketPath: temporarySocketPath())
        store.start()
        defer { store.stop() }

        _ = store.receive(start("build", title: "Build", expiresIn: 600), now: Self.t0)
        let generation = store.expiryTaskGeneration
        #expect(store.scheduledDeadlineForTesting == Self.t0.addingTimeInterval(600))

        for step in 1 ... 20 {
            let now = Self.t0.addingTimeInterval(Double(step))
            let update = LiveActivityUpdate(
                command: .update,
                id: "build",
                title: nil,
                progress: Double(step) / 20
            )
            _ = store.receive(update, now: now)
        }

        #expect(store.expiryTaskGeneration == generation, "same deadline, same task")
        #expect(store.scheduledDeadlineForTesting == Self.t0.addingTimeInterval(600))
    }

    @Test("A genuinely newer deadline replaces the task")
    func newerDeadlineReschedules() {
        let store = ExternalActivityStore(socketPath: temporarySocketPath())
        store.start()
        defer { store.stop() }

        _ = store.receive(start("first", title: "First", expiresIn: 600), now: Self.t0)
        let generation = store.expiryTaskGeneration

        _ = store.receive(
            start("second", title: "Second", expiresIn: 30),
            now: Self.t0.addingTimeInterval(1)
        )
        #expect(store.expiryTaskGeneration == generation + 1)
        #expect(store.scheduledDeadlineForTesting == Self.t0.addingTimeInterval(31))
    }

    @Test("Finishing keeps the registry's linger as the next deadline")
    func finishUsesLingerDeadline() {
        let store = ExternalActivityStore(socketPath: temporarySocketPath())
        store.start()
        defer { store.stop() }

        let finishTime = Self.t0.addingTimeInterval(5)
        _ = store.receive(start("build", title: "Build", expiresIn: 600), now: Self.t0)
        _ = store.receive(
            LiveActivityUpdate(command: .finish, id: "build", title: nil),
            now: finishTime
        )

        #expect(store.scheduledDeadlineForTesting == finishTime.addingTimeInterval(3))
    }

    @Test("Dismissing the earliest activity moves the deadline to the next one")
    func dismissReschedules() {
        let store = ExternalActivityStore(socketPath: temporarySocketPath())
        store.start()
        defer { store.stop() }

        _ = store.receive(start("short", title: "Short", expiresIn: 60), now: Self.t0)
        _ = store.receive(start("long", title: "Long", expiresIn: 600), now: Self.t0)
        #expect(store.scheduledDeadlineForTesting == Self.t0.addingTimeInterval(60))
        let generation = store.expiryTaskGeneration

        store.dismiss(id: "short")
        #expect(store.expiryTaskGeneration == generation + 1)
        #expect(store.scheduledDeadlineForTesting == Self.t0.addingTimeInterval(600))
    }

    @Test("Firing clears the deadline, and an empty registry leaves none armed")
    func firingClearsDeadline() async throws {
        let store = ExternalActivityStore(socketPath: temporarySocketPath())
        store.start()
        defer { store.stop() }

        _ = store.receive(start("short", title: "Short", expiresIn: 0.15), now: Date())
        #expect(store.scheduledDeadlineForTesting != nil)
        #expect(store.expiryTaskGeneration == 1)

        // Poll: the expiry wake-up resumes on the main actor, which the rest of
        // the suite may be occupying.
        for _ in 0 ..< 100 where !store.live.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(store.live.isEmpty)
        #expect(store.scheduledDeadlineForTesting == nil)

        // A later activity arms a fresh task.
        _ = store.receive(start("later", title: "Later", expiresIn: 60), now: Date())
        #expect(store.expiryTaskGeneration == 2)
        #expect(store.scheduledDeadlineForTesting != nil)
    }

    @Test("Stop clears the armed deadline and restart can arm a new one")
    func stopClearsDeadline() {
        let store = ExternalActivityStore(socketPath: temporarySocketPath())
        store.start()
        _ = store.receive(start("build", title: "Build", expiresIn: 60), now: Self.t0)
        #expect(store.scheduledDeadlineForTesting != nil)

        store.stop()
        #expect(store.scheduledDeadlineForTesting == nil)
        #expect(store.live.isEmpty)

        store.start()
        _ = store.receive(start("again", title: "Again", expiresIn: 60), now: Self.t0)
        #expect(store.scheduledDeadlineForTesting == Self.t0.addingTimeInterval(60))
        store.stop()
    }
}
