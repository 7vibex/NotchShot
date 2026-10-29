import AVFoundation
import Foundation
import Testing
@testable import NotchShotKit

@Suite("Isolated recording recovery audit", .serialized)
@MainActor
struct RecordingRecoveryAuditTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recording-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root.resolvingSymlinksInPath()
    }

    @Test("Recovery rejects a redirected scratch parent")
    func redirectedParent() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let scratch = root.appendingPathComponent("scratch")
        try FileManager.default.createSymbolicLink(at: scratch, withDestinationURL: outside)
        let file = scratch.appendingPathComponent("foreign.mp4")
        try await RecordingExportAndEffectsTests.makeFixtureVideo(at: file)
        let bytes = try Data(contentsOf: file)
        #expect(!RecordingService.isRecoverableRecording(file, inProgress: scratch))
        do {
            _ = try await RecordingService().recover(file, inProgress: scratch, destination: { root.appendingPathComponent("stolen.mp4") })
            Issue.record("Redirected recording moved")
        } catch { #expect(try Data(contentsOf: file) == bytes) }
    }

    @Test("Explicitly discarded files cannot enter direct recovery")
    func excludedCandidate() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("discarded.mp4")
        try await RecordingExportAndEffectsTests.makeFixtureVideo(at: source)
        try Data().write(to: RecordingScratchRetirement.marker(for: source))
        #expect(!RecordingService.isRecoverableRecording(source, inProgress: root))
        let destination = root.appendingPathComponent("destination.mp4")
        do {
            _ = try await RecordingService().recover(source, inProgress: root, destination: { destination })
            Issue.record("Discarded recording was recovered")
        } catch {
            #expect(FileManager.default.fileExists(atPath: source.path))
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    @Test("A three-hour timeline recovers intact and refuses duplicate recovery")
    func longTimeline() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("long.mp4")
        let destination = root.appendingPathComponent("saved/long.mp4")
        try await RecordingExportAndEffectsTests.makeFixtureVideo(at: source, duration: 10_800)
        let bytes = try Data(contentsOf: source)
        let service = RecordingService()
        let asset = try await service.recover(source, inProgress: root, destination: { destination })
        #expect(abs((asset.duration ?? 0) - 10_800) < 0.01)
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(!RecordingService.isRecoverableRecording(source, inProgress: root))
        do {
            _ = try await service.recover(source, inProgress: root, destination: { destination })
            Issue.record("A moved source was recovered twice")
        } catch { #expect(try Data(contentsOf: destination) == bytes) }
    }

    @Test("Invalid recovery preserves both scratch and an existing destination")
    func invalidRecovery() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("broken.mp4")
        let destination = root.appendingPathComponent("existing.mp4")
        try Data("truncated".utf8).write(to: source)
        try Data("existing".utf8).write(to: destination)
        do {
            _ = try await RecordingService().recover(source, inProgress: root, destination: { destination })
            Issue.record("Invalid movie accepted")
        } catch {
            #expect(try Data(contentsOf: source) == Data("truncated".utf8))
            #expect(try Data(contentsOf: destination) == Data("existing".utf8))
        }
    }

    @Test("Discard fallback preserves bytes and excludes a retained source")
    func discardFailures() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("partial.mp4")
        let bytes = Data("partial recording".utf8)
        try bytes.write(to: source)
        let blocked = root.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let service = RecordingService()
        let retained = service.discardScratchRecording(source, discardedDirectory: blocked) { _ in
            throw CocoaError(.fileWriteNoPermission)
        }
        #expect(retained == source)
        #expect(try Data(contentsOf: source) == bytes)
        #expect(FileManager.default.fileExists(atPath: RecordingScratchRetirement.marker(for: source).path))
        #expect(!RecordingService.isRecoverableRecording(source, inProgress: root))
    }

    @Test("A failed Trash operation moves the entire file to retained discards")
    func retainedDiscard() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("partial.mp4")
        let bytes = Data("partial recording".utf8); try bytes.write(to: source)
        let retained = try #require(RecordingService().discardScratchRecording(source, discardedDirectory: root.appendingPathComponent("discarded")) { _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        #expect(try Data(contentsOf: retained) == bytes)
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test("Actual Trash keeps a disposable recording recoverable",
          .enabled(if: ProcessInfo.processInfo.environment["NOTCHSHOT_RECORDING_DISCARD_INTEGRATION"] == "1"))
    func actualTrash() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("notchshot-audit-\(UUID().uuidString).mp4")
        let bytes = Data("disposable isolated recording".utf8); try bytes.write(to: source)
        var trashed: NSURL?
        let retained = RecordingService().discardScratchRecording(source, discardedDirectory: root.appendingPathComponent("discarded")) { file in
            try FileManager.default.trashItem(at: file, resultingItemURL: &trashed)
        }
        #expect(retained == nil)
        let url = try #require(trashed as URL?)
        #expect(try Data(contentsOf: url) == bytes)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        // Deliberately leave the disposable checkpoint in recoverable Trash.
    }


    @Test("A destination collision preserves valid footage and the existing document")
    func destinationCollision() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("valid.mp4")
        let destination = root.appendingPathComponent("existing.mp4")
        try await RecordingExportAndEffectsTests.makeFixtureVideo(at: source)
        let bytes = try Data(contentsOf: source)
        try Data("existing document".utf8).write(to: destination)
        do {
            _ = try await RecordingService().recover(source, inProgress: root, destination: { destination })
            Issue.record("Existing destination replaced")
        } catch {
            #expect(try Data(contentsOf: source) == bytes)
            #expect(try Data(contentsOf: destination) == Data("existing document".utf8))
        }
    }

    @Test("Concurrent recovery chooses unique destinations after validation")
    func concurrentRecovery() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.mp4")
        let second = root.appendingPathComponent("second.mp4")
        try await RecordingExportAndEffectsTests.makeFixtureVideo(at: first)
        try FileManager.default.copyItem(at: first, to: second)
        let service = RecordingService()
        let outputs = root.appendingPathComponent("outputs")
        try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
        async let a = service.recover(first, inProgress: root, destination: { AppPaths.uniqueURL(in: outputs, name: "Recovered", extension: "mp4") })
        async let b = service.recover(second, inProgress: root, destination: { AppPaths.uniqueURL(in: outputs, name: "Recovered", extension: "mp4") })
        let assets = try await [a, b]
        #expect(assets[0].url != assets[1].url)
        #expect(assets.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
    }

    @Test("Interrupted and endurance media recover through production validation",
          .enabled(if: ProcessInfo.processInfo.environment["NOTCHSHOT_RECOVERY_FIXTURES"] != nil))
    func runtimeFixtures() async throws {
        let fixtureRoot = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NOTCHSHOT_RECOVERY_FIXTURES"]))
        for name in ["interrupted", "endurance"] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("\(name).mp4")
            try FileManager.default.copyItem(at: fixtureRoot.appendingPathComponent("\(name).mp4"), to: source)
            let bytes = try Data(contentsOf: source)
            let asset = try await RecordingService().recover(source, inProgress: root, destination: { root.appendingPathComponent("saved/movie.mp4") })
            #expect((asset.duration ?? 0) > (name == "endurance" ? 119 : 2))
            #expect(try Data(contentsOf: asset.url) == bytes)
            #expect(try await AVURLAsset(url: asset.url).load(.isPlayable))
        }
    }
}
