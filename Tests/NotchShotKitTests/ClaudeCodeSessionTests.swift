import Foundation
import Testing
@testable import NotchShotKit

@Suite("Claude Code activity")
struct ClaudeCodeSessionTests {
    @Test("Claude hook events map approval, idle, failure, and session end states")
    func hookStatePolicy() {
        #expect(ClaudeCodeHookPolicy.phase(
            event: "PermissionRequest",
            status: "waiting_for_approval",
            notificationType: nil
        ) == .waiting)
        #expect(ClaudeCodeHookPolicy.phase(
            event: "Stop",
            status: "waiting_for_input",
            notificationType: nil
        ) == .waiting)
        #expect(ClaudeCodeHookPolicy.phase(
            event: "PostToolUseFailure",
            status: "failed",
            notificationType: nil
        ) == .failed)
        #expect(ClaudeCodeHookPolicy.phase(
            event: "SessionEnd",
            status: "ended",
            notificationType: nil
        ) == .finished)
    }

    @Test("A live session maps to a bounded Claude activity without tool payloads")
    func sessionActivityMapping() throws {
        let received = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let session = ClaudeCodeSession(
            id: "session-1",
            cwd: "/Users/example/Project",
            phase: .waiting,
            title: "Review the patch",
            detail: "Waiting for permission to use Bash",
            lastTool: "Bash",
            permission: ClaudeCodePermissionRequest(
                id: "permission-1",
                toolName: "Bash",
                detail: "Claude is asking to run a command",
                receivedAt: received
            ),
            startedAt: received,
            updatedAt: received
        )

        let activity = session.aiActivity
        #expect(activity.source == .claude)
        #expect(activity.state == .waiting)
        #expect(activity.title == "Review the patch")
        #expect(activity.workspace == "/Users/example/Project")
        #expect(activity.steps.map(\.label) == ["Using Bash"])
        #expect(!activity.detail!.contains("tool_input"))
        #expect(session.permission?.toolName == "Bash")
    }

    @Test("On-demand conversation parsing keeps visible text and tool labels only")
    func transcriptParsing() {
        let data = Data("""
            {"type":"user","uuid":"u1","timestamp":"2026-08-31T10:00:00Z","message":{"role":"user","content":"Please inspect the export"}}
            {"type":"assistant","uuid":"a1","timestamp":"2026-08-31T10:00:01Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"private reasoning"},{"type":"text","text":"I will inspect it."}]}}
            {"type":"assistant","uuid":"a2","timestamp":"2026-08-31T10:00:02Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tool-1","name":"Bash","input":{"command":"private command"}}]}}
            {"type":"user","uuid":"r1","timestamp":"2026-08-31T10:00:03Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool-1","content":"private output"}]}}
            """.utf8
        )

        let messages = ClaudeConversationReader.messages(from: data)
        #expect(messages.map { $0.role } == [
            ClaudeTranscriptRole.user,
            ClaudeTranscriptRole.assistant,
            ClaudeTranscriptRole.tool,
        ])
        #expect(messages[0].text == "Please inspect the export")
        #expect(messages[1].text == "I will inspect it.")
        #expect(messages[2].text == "Used Bash")
        #expect(!messages.contains { $0.text.contains("private") })
        #expect(messages[2].toolName == "Bash")
    }

    @Test("A transcript is found by session id even when the project slug does not match")
    func transcriptLookupIgnoresUndocumentedSlug() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-claude-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        // Claude's real folder name for /Users/example/my_app replaces the
        // underscore; the old lookup built "-Users-example-my_app" and missed it.
        let project = home
            .appendingPathComponent(".claude/projects/-Users-example-my-app", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let transcript = project.appendingPathComponent("session-42.jsonl")
        try Data("""
            {"type":"user","cwd":"/Users/example/my_app","uuid":"u1","message":{"role":"user","content":"Hello"}}
            """.utf8).write(to: transcript)

        let session = ClaudeCodeSession(id: "session-42", cwd: "/Users/example/my_app")
        let found = ClaudeConversationReader.sessionFileURL(for: session, homeDirectory: home)
        #expect(found?.standardizedFileURL == transcript.standardizedFileURL)
    }

    @Test("The recorded cwd disambiguates a duplicate session id across projects")
    func transcriptLookupPrefersMatchingCwd() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-claude-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let otherProject = home
            .appendingPathComponent(".claude/projects/-Users-example-other", isDirectory: true)
        let matchingProject = home
            .appendingPathComponent(".claude/projects/-Users-example-target", isDirectory: true)
        try FileManager.default.createDirectory(at: otherProject, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: matchingProject, withIntermediateDirectories: true)
        try Data("""
            {"type":"user","cwd":"/Users/example/other","uuid":"u1","message":{"role":"user","content":"Other"}}
            """.utf8).write(to: otherProject.appendingPathComponent("session-7.jsonl"))
        let matching = matchingProject.appendingPathComponent("session-7.jsonl")
        try Data("""
            {"type":"user","cwd":"/Users/example/target","uuid":"u2","message":{"role":"user","content":"Target"}}
            """.utf8).write(to: matching)

        let session = ClaudeCodeSession(id: "session-7", cwd: "/Users/example/target")
        let found = ClaudeConversationReader.sessionFileURL(for: session, homeDirectory: home)
        #expect(found?.standardizedFileURL == matching.standardizedFileURL)
    }
}
