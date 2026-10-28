import Foundation
import NotchShotAIReporterSupport

/// Turns Claude hook events into the run card's detail: the turn's timed
/// tool calls, Claude's task list, the model, and where Pause or Stop
/// stands. Pure, so the live monitor and its tests share it.
enum ClaudeCodeRunTracker {
    /// Applies one hook event. Returns false for the events that are only
    /// about Pause or Stop, which must not touch the session's phase or text.
    static func apply(
        _ object: [String: Any],
        event normalizedEvent: String,
        tool: String?,
        now: Date,
        to session: inout ClaudeCodeSession
    ) -> Bool {
        if let model = ClaudeRunReport.model(from: object["model"]) { session.model = model }
        let status = object["status"] as? String
        let target = (object["tool_target"] as? String).flatMap { ClaudeCodeHookPolicy.bounded($0, maximum: 120) }
        let toolUseID = (object["tool_use_id"] as? String).flatMap(ClaudeRunReport.safeIdentifier)

        if status == ClaudeRunControl.heldStatus {
            // Held before the next tool, so the last one is done.
            if !session.reportsToolEnds { AgentRunTimeline.endAll(at: now, in: &session.actions) }
            let next = tool.map { AgentRunAction(id: "held", tool: $0, target: target, startedAt: now) }
            session.control = .paused(before: next.map { AgentRunPhrasing.text(for: [$0], finished: false) })
            session.updatedAt = now
            return false
        }
        if status == ClaudeRunControl.stoppedStatus {
            endTurn(of: &session, at: now)
            session.phase = .waiting
            session.detail = ClaudeRunControl.stopReason
            session.updatedAt = now
            return false
        }

        switch normalizedEvent {
        case "userpromptsubmit":
            session.actions = []
            session.toolCallCount = 0
            session.turnStartedAt = now
            session.turnEndedAt = nil
            session.control = nil
            if AgentRunPlan.isComplete(session.plan) { session.plan = [] }
        case "pretooluse":
            if session.turnStartedAt == nil || session.turnEndedAt != nil {
                // Seen mid-turn, or a turn the user started without a hook.
                if session.turnEndedAt != nil { session.actions = []; session.toolCallCount = 0 }
                session.turnStartedAt = now
                session.turnEndedAt = nil
            }
            // A hold that timed out lets the call through; the pause still
            // stands for the next one.
            if session.control?.isPaused == true { session.control = .pausing }
            if let list = object["plan"] as? [[String: Any]] {
                session.plan = AgentRunPlan.steps(fromList: list)
            } else if let operation = object["plan_op"] as? [String: Any] {
                session.plan = AgentRunPlan.applying(operation, to: session.plan)
            }
            guard let tool else { break }
            if ClaudeRunReport.isPlanTool(tool) {
                if !session.reportsToolEnds { AgentRunTimeline.endAll(at: now, in: &session.actions) }
                break
            }
            AgentRunTimeline.begin(
                AgentRunAction(id: toolUseID ?? UUID().uuidString, tool: tool, target: target, startedAt: now),
                in: &session.actions,
                endsOpenCalls: !session.reportsToolEnds
            )
            session.toolCallCount += 1
        case "posttooluse":
            session.reportsToolEnds = true
            AgentRunTimeline.end(toolUseID: toolUseID, tool: tool, at: now, failed: false, in: &session.actions)
        case "posttoolusefailure":
            AgentRunTimeline.end(toolUseID: toolUseID, tool: tool, at: now, failed: true, in: &session.actions)
        case "stop", "stopfailure", "sessionend":
            endTurn(of: &session, at: now)
        default:
            break
        }
        return true
    }

    /// The row text for a call that just started, for the compact list.
    static func detail(forStartOf tool: String?, in session: ClaudeCodeSession) -> String? {
        guard let tool else { return nil }
        if ClaudeRunReport.isPlanTool(tool) { return "Updating its plan" }
        return AgentRunTimeline.currentText(for: session.actions)?.text
    }

    private static func endTurn(of session: inout ClaudeCodeSession, at now: Date) {
        AgentRunTimeline.endAll(at: now, in: &session.actions)
        if session.turnStartedAt != nil { session.turnEndedAt = now }
        session.control = nil
    }
}

extension ClaudeConversationReader {
    /// The model behind the newest assistant reply, from the end of the
    /// session's transcript. Only the `"model"` value is read; the rest of
    /// each row is skipped.
    static func latestModel(
        for session: ClaudeCodeSession,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        guard let url = sessionFileURL(for: session, homeDirectory: homeDirectory),
              let data = newestRows(of: url, maximumBytes: 256 * 1_024) else { return nil }
        return latestModel(in: data)
    }

    static func latestModel(in data: Data) -> String? {
        let marker = Array(#""model":""#.utf8)
        let bytes = [UInt8](data)
        guard bytes.count >= marker.count else { return nil }
        var index = bytes.count - marker.count
        while index >= 0 {
            if bytes[index] == marker[0], marker.indices.allSatisfy({ bytes[index + $0] == marker[$0] }) {
                let start = index + marker.count
                var end = start
                while end < bytes.count, bytes[end] != UInt8(ascii: "\""), end - start < 80 { end += 1 }
                let value = String(decoding: bytes[start ..< end], as: UTF8.self)
                // Claude Code stamps its own notices "<synthetic>".
                if value.hasPrefix("claude") { return value }
            }
            index -= 1
        }
        return nil
    }
}
