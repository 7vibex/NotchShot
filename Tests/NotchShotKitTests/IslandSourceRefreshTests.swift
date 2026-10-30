import Foundation
import Testing
@testable import NotchShotKit

/// The observed island sources schedule a refresh only for values no refresh
/// has read yet. Hooks go straight to the monitor; nothing opens its socket.
@Suite("Island source refresh")
@MainActor
struct IslandSourceRefreshTests {
    private func hook(_ coordinator: AppCoordinator, prompt: String) throws {
        let object: [String: Any] = [
            "session_id": "synthetic-refresh", "hook_event_name": "UserPromptSubmit",
            "prompt": prompt, "cwd": "/tmp/synthetic-project",
        ]
        coordinator.context.claude.receiveHookData(try JSONSerialization.data(withJSONObject: object))
    }

    @Test("A refresh records the source values it read")
    func refreshRecordsValues() throws {
        let coordinator = AppCoordinator()
        try hook(coordinator, prompt: "First")
        #expect(coordinator.islandSourcesAtLastRefresh != coordinator.islandSourceValues)
        coordinator.refreshActivity()
        #expect(coordinator.islandSourcesAtLastRefresh == coordinator.islandSourceValues)
    }

    @Test("A change no refresh read is refreshed, including one made before tracking renews")
    func unreadChangeIsRefreshed() async throws {
        let coordinator = AppCoordinator()
        coordinator.observeIslandSources()
        coordinator.refreshActivity()
        try hook(coordinator, prompt: "First")
        let afterFirst = coordinator.islandSourceValues
        try hook(coordinator, prompt: "Second")
        #expect(coordinator.islandSourceValues != afterFirst)
        for _ in 0 ..< 200 where coordinator.islandSourcesAtLastRefresh != coordinator.islandSourceValues {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(coordinator.islandSourcesAtLastRefresh == coordinator.islandSourceValues)
        #expect(coordinator.islandSourcesAtLastRefresh?.claude.count == 1)
    }
}
