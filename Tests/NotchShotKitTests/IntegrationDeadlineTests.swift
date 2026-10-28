import Darwin
import Foundation
import NotchShotAIReporterSupport
import Synchronization
import Testing
@testable import NotchShotKit

@Suite("Status line command deadlines")
struct StatusLineCommandTests {
    @Test("The complete input is written while output is drained")
    func completeInput() {
        let output = StatusLineCommand.run(
            command: "/usr/bin/wc -c", input: Data(repeating: 32, count: 512 * 1_024), timeout: 2
        )
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "524288")
    }

    @Test("A non-reading child cannot block stdin past the deadline")
    func blockedInput() {
        let start = ContinuousClock.now
        let output = StatusLineCommand.run(
            command: "exec /bin/sleep 30", input: Data(repeating: 32, count: 512 * 1_024), timeout: 0.15
        )
        #expect(output.isEmpty)
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test("Output larger than a pipe is drained and retained within the limit")
    func outputLimit() {
        let start = ContinuousClock.now
        let output = StatusLineCommand.run(
            command: "/usr/bin/yes x | /usr/bin/head -c 131072", input: Data(), timeout: 2
        )
        #expect(output.hasPrefix("x\nx"))
        #expect(output.utf8.count <= StatusLineCommand.maximumOutputBytes)
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test("A child ignoring termination is killed and reaped")
    func ignoresTermination() throws {
        let start = ContinuousClock.now
        let output = StatusLineCommand.run(
            command: "trap '' TERM; printf '%s' $$; while :; do /bin/sleep 1; done", input: Data(), timeout: 0.15
        )
        let pid = try #require(Int32(output))
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(kill(pid, 0) != 0)
    }

    @Test("A descendant retaining stdout does not hold the reporter open")
    func inheritedOutput() throws {
        let start = ContinuousClock.now
        let output = StatusLineCommand.run(command: "/bin/sleep 30 & printf '%s' $!", input: Data(), timeout: 2)
        let pid = try #require(Int32(output))
        #expect(ContinuousClock.now - start < .seconds(1))
        let deadline = ContinuousClock.now + .seconds(2)
        while kill(pid, 0) == 0, ContinuousClock.now < deadline { usleep(10_000) }
        #expect(kill(pid, 0) != 0)
    }
}

@Suite("Crewline request cancellation")
struct CrewlineRequestCancellationTests {
    @Test("Cancelling a held request resolves it and removes the pending entry")
    func cancelRegistered() async throws {
        let connection = CrewlineConnection(port: 0, token: "synthetic-unused")
        let (sent, signal) = AsyncStream<Void>.makeStream()
        let request = Task {
            try await connection.waitForReply(id: "cancel") { _ in signal.yield(()) }
        }
        var iterator = sent.makeAsyncIterator()
        _ = await iterator.next()
        #expect(await connection.pendingRequestCount == 1)
        request.cancel()
        switch await request.result {
        case .failure(let error): #expect(error is CancellationError)
        case .success: Issue.record("Cancelled request returned a payload")
        }
        #expect(await connection.pendingRequestCount == 0)
    }

    @Test("Cancellation before admission sends no frame")
    func cancelBeforeAdmission() async {
        let connection = CrewlineConnection(port: 0, token: "synthetic-unused")
        let calls = Mutex(0)
        let (gate, signal) = AsyncStream<Void>.makeStream()
        let request = Task {
            var iterator = gate.makeAsyncIterator()
            _ = await iterator.next()
            return try await connection.waitForReply(id: "early") { _ in calls.withLock { $0 += 1 } }
        }
        request.cancel()
        signal.finish()
        switch await request.result {
        case .failure(let error): #expect(error is CancellationError)
        case .success: Issue.record("Cancelled request was admitted")
        }
        #expect(calls.withLock { $0 } == 0)
        #expect(await connection.pendingRequestCount == 0)
    }

    @Test("An unanswered request still has its timeout and is removed once")
    func requestTimeout() async {
        let connection = CrewlineConnection(port: 0, token: "synthetic-unused")
        do {
            _ = try await connection.waitForReply(id: "timeout", timeout: .milliseconds(20)) { _ in }
            Issue.record("Unanswered request succeeded")
        } catch {
            #expect(error as? CrewlineConnectionError == .timedOut)
        }
        #expect(await connection.pendingRequestCount == 0)
    }

    @Test("A send failure resolves the same registered continuation")
    func sendFailure() async {
        let connection = CrewlineConnection(port: 0, token: "synthetic-unused")
        do {
            _ = try await connection.waitForReply(id: "failure") { $0(CrewlineConnectionError.closed) }
            Issue.record("Failed send succeeded")
        } catch {
            #expect(error as? CrewlineConnectionError == .closed)
        }
        #expect(await connection.pendingRequestCount == 0)
    }
}
