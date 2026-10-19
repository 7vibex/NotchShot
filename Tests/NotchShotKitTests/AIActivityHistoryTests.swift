import Foundation
import Testing
@testable import NotchShotKit

@Suite("AI activity history convergence")
struct AIActivityHistoryTests {
    private func activity(
        _ index: Int,
        source: AISource = .codex,
        state: AIActivityState = .finished,
        timestamp: Int? = nil
    ) -> AIActivitySnapshot {
        AIActivitySnapshot(
            id: String(format: "session-%02d", index), source: source, state: state,
            title: "Synthetic task \(index)", detail: "Synthetic completion",
            progress: 1, workspace: "Fixture",
            steps: [AIActivityStep(id: "step", label: "Done", state: .completed)],
            startedAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(2_000 + (timestamp ?? index)))
        )
    }

    @Test("Identical polls converge at both sides of the history cap", arguments: [0, 1, 20, 21, 32])
    func repeatedPolls(_ count: Int) {
        let incoming = (0 ..< count).map { activity($0) }
        let expected = Array(incoming.reversed().prefix(20))
        var history = AIActivityHistoryPolicy.merging(incoming, into: [])
        #expect(history == expected)
        for _ in 0 ..< 6 {
            let repeated = AIActivityHistoryPolicy.merging(incoming, into: history)
            #expect(repeated == history, "An unchanged poll must not trigger another history commit")
            history = repeated
        }
    }

    @Test("An updated event keeps its fields and becomes the newest history row")
    func updateIsRetained() {
        let history = (0 ..< 20).map { activity($0) }
        var update = activity(0, state: .failed, timestamp: 100)
        update.detail = "Updated failure"
        update.steps[0].state = .failed
        let result = AIActivityHistoryPolicy.merging([update], into: history)
        #expect(result.first == update)
        #expect(result.count == 20)
        #expect(result.filter { $0.displayIdentifier == update.displayIdentifier }.count == 1)
        #expect(AIActivityHistoryPolicy.merging([update], into: result) == result)
    }

    @Test("A same-time correction is retained and an older duplicate cannot undo it")
    func correctionsAndStaleDuplicates() {
        let original = activity(1)
        var corrected = original
        corrected.detail = "Corrected detail"
        let result = AIActivityHistoryPolicy.merging([corrected], into: [original])
        #expect(result == [corrected])
        #expect(AIActivityHistoryPolicy.merging([activity(1, timestamp: 0)], into: result) == result)
        #expect(AIActivityHistoryPolicy.merging([corrected], into: result) == result)
    }

    @Test("Timestamp ties use stable source-qualified IDs regardless of file order")
    func stableTies() {
        let tied = (0 ..< 32).map { activity($0, timestamp: 0) }
        let expected = Array(tied.prefix(20))
        #expect(AIActivityHistoryPolicy.merging(tied, into: []) == expected)
        #expect(AIActivityHistoryPolicy.merging(Array(tied.reversed()), into: expected) == expected)
        let otherSource = activity(0, source: .cursor, timestamp: 0)
        let distinct = AIActivityHistoryPolicy.merging([tied[0], otherSource], into: [])
        #expect(distinct.count == 2)
        #expect(Set(distinct.map(\.displayIdentifier)) == [tied[0].displayIdentifier, otherSource.displayIdentifier])
    }

    @Test("Working and waiting input do not replace completed history")
    func nonterminalInput() {
        let old = activity(1)
        let incoming = [activity(1, state: .working, timestamp: 100), activity(2, state: .waiting)]
        #expect(AIActivityHistoryPolicy.merging(incoming, into: [old]) == [old])
    }

    @Test("The caller's source filter leaves existing disabled-source history intact")
    func sourceFiltering() {
        let old = activity(0, source: .cursor)
        let incoming = [activity(1), activity(2, source: .cursor)]
        let enabledSources: Set<AISource> = [.codex]
        let result = AIActivityHistoryPolicy.merging(
            incoming.filter { enabledSources.contains($0.source) }, into: [old]
        )
        #expect(result == [incoming[0], old])
    }

    @Test("Persisted history keeps complete payloads and converges after chronological repair")
    func persistedHistory() throws {
        let old = (0 ..< 20).map { activity($0) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([AIActivitySnapshot].self, from: encoder.encode(old))
        let result = AIActivityHistoryPolicy.merging([], into: decoded)
        #expect(result == Array(old.reversed()))
        #expect(try decoder.decode([AIActivitySnapshot].self, from: encoder.encode(result)) == result)
        #expect(AIActivityHistoryPolicy.merging([], into: result) == result)
    }
}
