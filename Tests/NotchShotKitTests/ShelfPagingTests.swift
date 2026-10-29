import SwiftUI
import Testing
@testable import NotchShotKit

@Suite("Shelf paging")
struct ShelfPagingTests {
    @Test("A later capture comes in from the trailing edge, an earlier one from the leading edge")
    func edgeFollowsStep() {
        #expect(ShelfMotion.pageEdge(forStep: 1) == .trailing)
        #expect(ShelfMotion.pageEdge(forStep: 3) == .trailing)
        #expect(ShelfMotion.pageEdge(forStep: -1) == .leading)
        #expect(ShelfMotion.pageEdge(forStep: -4) == .leading)
        #expect(ShelfMotion.pageEdge(forStep: 0) == nil)
    }

    @Test("Arrow keys turn the way they point, even when wrapping past an end")
    func keysWrapLikeACarousel() {
        // → on the last of five wraps to the first and still enters from the trailing edge.
        #expect(ShelfPageTurn(move: .step(1), from: 4, serial: 1).edge == .trailing)
        // ← on the first wraps to the last and still enters from the leading edge.
        #expect(ShelfPageTurn(move: .step(-1), from: 0, serial: 1).edge == .leading)
    }

    @Test("A clicked thumbnail turns towards where it sits")
    func clicksTurnTowardsTheThumbnail() {
        #expect(ShelfPageTurn(move: .to(3), from: 1, serial: 1).edge == .trailing)
        #expect(ShelfPageTurn(move: .to(0), from: 2, serial: 1).edge == .leading)
        #expect(ShelfPageTurn(move: .to(2), from: 2, serial: 1).edge == nil)
    }

    @Test("Two turns the same way are still two turns")
    func serialSeparatesTurns() {
        let first = ShelfPageTurn(move: .step(1), from: 0, serial: 1)
        let second = ShelfPageTurn(move: .step(1), from: 0, serial: 2)
        #expect(first != second)
    }

    @Test("The ring slides on the selection curve, and moves at once under Reduce Motion")
    func ringAnimation() {
        #expect(ShelfMotion.ringAnimation(reduceMotion: true) == nil)
        #expect(ShelfMotion.ringAnimation(reduceMotion: false) == NotchMotion.selection(reduceMotion: false))
    }
}
