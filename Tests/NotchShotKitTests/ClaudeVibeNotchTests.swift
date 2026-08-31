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

struct AgentVibeNotchTests {
    @Test("Every supported agent gets the same Vibe status grammar")
    func statusGrammarCoversAllSources() {
        for source in AISource.allCases {
            let activity = AIActivitySnapshot(
                id: source.rawValue,
                source: source,
                state: .working,
                title: "Inspecting the workspace"
            )

            #expect(AgentVibePresentation.statusText(for: activity) == "Processing")
        }
    }

    @Test("Vibe activity ordering keeps Codex and other attention states visible")
    func crossProviderOrdering() {
        let now = Date()
        let terminal = AIActivitySnapshot(
            id: "terminal",
            source: .terminal,
            state: .finished,
            title: "Build",
            updatedAt: now.addingTimeInterval(30)
        )
        let cursor = AIActivitySnapshot(
            id: "cursor",
            source: .cursor,
            state: .working,
            title: "Editing",
            updatedAt: now
        )
        let codex = AIActivitySnapshot(
            id: "codex",
            source: .codex,
            state: .waiting,
            title: "Needs a decision",
            updatedAt: now.addingTimeInterval(-30)
        )

        let ordered = AgentVibePresentation.sorted([terminal, cursor, codex])
        #expect(ordered.map(\.source) == [.codex, .cursor, .terminal])
    }

    @Test("A mixed provider surface uses the neutral AI Agents header")
    func mixedHeaderTitle() {
        let codex = AIActivitySnapshot(
            id: "codex",
            source: .codex,
            state: .working,
            title: "Codex task"
        )
        let terminal = AIActivitySnapshot(
            id: "terminal",
            source: .terminal,
            state: .working,
            title: "Build"
        )

        #expect(AgentVibePresentation.headerTitle(for: [codex, terminal]) == "AI Agents")
        #expect(AgentVibePresentation.headerTitle(for: [codex]) == "Codex Agents")
    }
}
