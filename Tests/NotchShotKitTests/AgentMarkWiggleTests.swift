import Testing
@testable import NotchShotKit

@Suite("Agent mark wiggle")
struct AgentMarkWiggleTests {
    @Test("Needs you: a question or approval in any state, or the turn handed back")
    func needsYou() {
        for state in AIActivityState.allCases {
            #expect(AgentMarkWiggle.needsYou(state: state, isAsking: true), "\(state)")
        }
        #expect(AgentMarkWiggle.needsYou(state: .waiting, isAsking: false))
        #expect(!AgentMarkWiggle.needsYou(state: .working, isAsking: false))
        #expect(!AgentMarkWiggle.needsYou(state: .finished, isAsking: false))
        #expect(!AgentMarkWiggle.needsYou(state: .failed, isAsking: false))
    }

    @Test("Shakes only the update a run starts needing you")
    func startsNeedingYou() {
        #expect(AgentMarkWiggle.startsNeedingYou("claude:1", needsYou: true, before: []))
        #expect(AgentMarkWiggle.startsNeedingYou("claude:1", needsYou: true, before: ["codex:2"]))
        // Already needing you last update: no second shake.
        #expect(!AgentMarkWiggle.startsNeedingYou("claude:1", needsYou: true, before: ["claude:1"]))
        // Stopped needing you, or never did.
        #expect(!AgentMarkWiggle.startsNeedingYou("claude:1", needsYou: false, before: []))
        #expect(!AgentMarkWiggle.startsNeedingYou("claude:1", needsYou: false, before: ["claude:1"]))
    }

    @Test("Opening the island on runs that already wait shakes nothing")
    func firstDrawIsQuiet() {
        #expect(!AgentMarkWiggle.startsNeedingYou("claude:1", needsYou: true, before: nil))
    }

    @Test("One short shake that dies away and ends square")
    func keyframes() {
        #expect(AgentMarkWiggle.duration > 0)
        #expect(AgentMarkWiggle.duration <= 0.6)
        #expect(AgentMarkWiggle.keyframes.last?.degrees == 0)
        let swings = AgentMarkWiggle.keyframes.map { abs($0.degrees) }
        #expect(swings.allSatisfy { $0 <= 10 })
        // Each swing no wider than the one before it.
        #expect(zip(swings, swings.dropFirst()).allSatisfy { $0 >= $1 })
    }
}
