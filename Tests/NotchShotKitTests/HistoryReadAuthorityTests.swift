import Darwin
import Foundation
import Testing
@testable import NotchShotKit

@Suite("History read authority")
struct HistoryReadAuthorityTests {
    @Test("A failed read and failed backup cannot grant permission to overwrite History",
          .enabled(if: getuid() != 0, "File permission fixture requires a non-root user"))
    @MainActor
    func unreadableStoreRemainsProtected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("history.json")
        defer {
            chmod(root.path, 0o700)
            chmod(url.path, 0o600)
            try? FileManager.default.removeItem(at: root)
        }
        func repository() -> HistoryRepository {
            HistoryRepository(storeURL: url, managedArtifactDirectories: [], historyEnabled: true, indexesCaptureText: false)
        }
        let seed = repository()
        seed.record(asset: CaptureAsset(
            url: root.appendingPathComponent("synthetic.png"), kind: .screenshot,
            pixelSize: CGSize(width: 10, height: 10)
        ), image: nil)
        try seed.save()
        let original = try Data(contentsOf: url)
        #expect(chmod(url.path, 0o000) == 0)
        #expect(chmod(root.path, 0o500) == 0)
        #expect(throws: (any Error).self) { try Data(contentsOf: url) }

        let failed = repository()
        if case .failed(_, let backupURL) = failed.loadOutcome {
            #expect(backupURL == nil)
        } else { Issue.record("Read/backup failure fixture did not reach the intended state") }
        #expect(failed.loadRecoveryMessage?.contains("Saving is disabled") == true)
        #expect(failed.loadRecoveryMessage?.contains("was quarantined") == false)
        #expect(chmod(root.path, 0o700) == 0)
        #expect(chmod(url.path, 0o600) == 0)
        #expect(throws: (any Error).self) { try failed.save() }
        #expect(try Data(contentsOf: url) == original)
        #expect(repository().entries.count == 1)
    }

    @Test("A successful backup preserves the original while allowing a fresh History")
    @MainActor
    func backedUpStoreCanRecover() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.json")
        let original = Data("incomplete legacy history".utf8)
        try original.write(to: url)
        let repository = HistoryRepository(
            storeURL: url, managedArtifactDirectories: [], historyEnabled: true, indexesCaptureText: false
        )
        guard case .failed(_, let possibleBackup) = repository.loadOutcome else {
            Issue.record("Invalid store did not reach recovery")
            return
        }
        let backup = try #require(possibleBackup)
        #expect(repository.loadRecoveryMessage?.contains("was quarantined") == true)
        repository.record(asset: CaptureAsset(
            url: root.appendingPathComponent("new.png"), kind: .screenshot,
            pixelSize: CGSize(width: 10, height: 10)
        ), image: nil)
        try repository.save()
        #expect(try Data(contentsOf: backup) == original)
        let reopened = HistoryRepository(
            storeURL: url, managedArtifactDirectories: [], historyEnabled: true, indexesCaptureText: false
        )
        #expect(reopened.entries.count == 1)
    }
}
