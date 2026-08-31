import Foundation
import Testing
@testable import NotchShotKit

struct ClaudeVibeNotchTests {
    @Test("Claude session status reflects permission before lifecycle phase")
    func statusText() {
        let session = ClaudeCodeSession(
            id: "permission",
            cwd: "/tmp/project",
            phase: .working,
            permission: ClaudeCodePermissionRequest(toolName: "Bash")
        )

        #expect(ClaudeVibeSessionPresentation.statusText(for: session) == "Waiting for approval")
        #expect(ClaudeVibeSessionPresentation.statusText(for: ClaudeCodeSession(
            id: "ready",
            cwd: "/tmp/project",
            phase: .waiting
        )) == "Ready")
    }

    @Test("Claude Vibe sessions keep attention and active work above terminal history")
    func ordering() {
        let now = Date()
        let finished = ClaudeCodeSession(
            id: "finished",
            cwd: "/tmp/project",
            phase: .finished,
            updatedAt: now.addingTimeInterval(30)
        )
        let working = ClaudeCodeSession(
            id: "working",
            cwd: "/tmp/project",
            phase: .working,
            updatedAt: now
        )
        let permission = ClaudeCodeSession(
            id: "permission",
            cwd: "/tmp/project",
            phase: .working,
            permission: ClaudeCodePermissionRequest(toolName: "Bash"),
            updatedAt: now.addingTimeInterval(-30)
        )

        let ordered = ClaudeVibeSessionPresentation.sorted([finished, working, permission])
        #expect(ordered.map(\.id) == ["permission", "working", "finished"])
    }
}
