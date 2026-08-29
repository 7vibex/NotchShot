import AppKit
import Foundation
import Testing
@testable import NotchShotKit

/// A copied capture is offered to the pasteboard as a promise rather than as
/// eagerly encoded bytes, because encoding a full-screen Retina image costs
/// hundreds of milliseconds on the main actor. These cover the part that
/// matters to the user: the clipboard still hands over a real image.
@Suite("Clipboard image promises")
@MainActor
struct PasteboardPromiseTests {
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("notchshot.tests.\(UUID().uuidString)"))
    }

    @Test("A promised image still yields decodable PNG bytes")
    func promisedPNGResolves() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        ImageExport.copyToPasteboard(
            TestImage.solid(width: 6, height: 4, red: 10, green: 200, blue: 90),
            to: pasteboard
        )

        let data = try #require(pasteboard.data(forType: .png))
        let decoded = try #require(NSBitmapImageRep(data: data))
        #expect(decoded.pixelsWide == 6)
        #expect(decoded.pixelsHigh == 4)
    }

    @Test("A promised image still yields decodable TIFF bytes")
    func promisedTIFFResolves() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        ImageExport.copyToPasteboard(
            TestImage.solid(width: 5, height: 7),
            to: pasteboard
        )

        let data = try #require(pasteboard.data(forType: .tiff))
        let decoded = try #require(NSBitmapImageRep(data: data))
        #expect(decoded.pixelsWide == 5)
        #expect(decoded.pixelsHigh == 7)
    }

    /// Both representations come from one promise, and asking for one must not
    /// consume the other — apps routinely probe several types before choosing.
    @Test("Both promised representations remain available")
    func bothRepresentationsResolve() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        ImageExport.copyToPasteboard(
            TestImage.solid(width: 8, height: 8, red: 255),
            to: pasteboard
        )

        #expect(pasteboard.data(forType: .tiff) != nil)
        #expect(pasteboard.data(forType: .png) != nil)
        // Re-reading is served from the provider's cache rather than encoding
        // the same pixels a second time.
        #expect(pasteboard.data(forType: .png) != nil)
    }

    @Test("The advertised types are the ones a paste can actually ask for")
    func advertisedTypesMatchPromise() {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        ImageExport.copyToPasteboard(TestImage.solid(width: 3, height: 3), to: pasteboard)

        let types = pasteboard.types ?? []
        #expect(types.contains(.png))
        #expect(types.contains(.tiff))
    }

    /// Copying twice must leave the newer capture on the clipboard; a stale
    /// promise outliving its replacement would paste the wrong screenshot.
    @Test("A second copy replaces the first")
    func secondCopyReplacesFirst() throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        ImageExport.copyToPasteboard(TestImage.solid(width: 4, height: 4), to: pasteboard)
        ImageExport.copyToPasteboard(TestImage.solid(width: 9, height: 2), to: pasteboard)

        let data = try #require(pasteboard.data(forType: .png))
        let decoded = try #require(NSBitmapImageRep(data: data))
        #expect(decoded.pixelsWide == 9)
        #expect(decoded.pixelsHigh == 2)
    }
}
