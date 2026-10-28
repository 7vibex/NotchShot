import Darwin
import Foundation
import NotchShotAIReporterSupport
import Testing
@testable import NotchShotKit

@Suite("Agent run card")
struct AgentRunCardTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: What the hook sends

    @Test("Tool targets are short, project-relative and redacted")
    func toolTargets() {
        let cwd = "/Users/example/Project"
        #expect(ClaudeRunReport.target(
            tool: "Edit",
            input: ["file_path": "/Users/example/Project/src/billing/invoice.ts", "old_string": "secret body"],
            cwd: cwd
        ) == "src/billing/invoice.ts")
        #expect(ClaudeRunReport.target(tool: "Grep", input: ["pattern": "applyDiscount"], cwd: cwd) == "applyDiscount")
        #expect(ClaudeRunReport.target(
            tool: "Bash",
            input: ["command": "npm test", "description": "Run the test suite"],
            cwd: cwd
        ) == "Run the test suite")
        #expect(ClaudeRunReport.target(
            tool: "WebFetch",
            input: ["url": "https://docs.swift.org/swift-book/?token=abc"],
            cwd: cwd
        ) == "docs.swift.org")
        // Only the description or the command's first line, never the rest.
        let command = ClaudeRunReport.target(tool: "Bash", input: ["command": "make\nrm -rf build"], cwd: cwd)
        #expect(command == "make")
        #expect(ClaudeRunReport.target(tool: "mcp__github__create_issue", input: ["title": "x"], cwd: cwd) == nil)
        let long = ClaudeRunReport.target(
            tool: "Read",
            input: ["file_path": "/opt/" + String(repeating: "deep/", count: 20) + "file.swift"],
            cwd: cwd
        )
        #expect(long == "…/deep/deep/file.swift")
    }

    @Test("Task-list tools become plan payloads; other tools do not")
    func planPayloads() throws {
        let list = try #require(ClaudeRunReport.planPayload(tool: "TodoWrite", input: ["todos": [
            ["content": "Read the code", "status": "completed", "activeForm": "Reading the code"],
            ["content": "Fix the bug", "status": "in_progress"],
        ]])?["plan"] as? [[String: Any]])
        #expect(list.count == 2)
        #expect(list[1]["label"] as? String == "Fix the bug")

        let create = try #require(ClaudeRunReport.planPayload(tool: "TaskCreate", input: ["subject": "Write tests"])?["plan_op"] as? [String: Any])
        #expect(create["op"] as? String == "create")
        let update = try #require(ClaudeRunReport.planPayload(tool: "TaskUpdate", input: ["taskId": "2", "status": "completed"])?["plan_op"] as? [String: Any])
        #expect(update["id"] as? String == "2")
        #expect(ClaudeRunReport.planPayload(tool: "Edit", input: ["file_path": "/a"]) == nil)
        #expect(ClaudeRunReport.isPlanTool("TodoWrite"))
        #expect(!ClaudeRunReport.isPlanTool("Read"))
    }

    @Test("The model comes as an ID or as an object")
    func hookModel() {
        #expect(ClaudeRunReport.model(from: "claude-sonnet-5-5") == "claude-sonnet-5-5")
        #expect(ClaudeRunReport.model(from: ["id": "claude-opus-5-5", "display_name": "Opus 5.5"]) == "Opus 5.5")
        #expect(ClaudeRunReport.model(from: 3) == nil)
    }

    // MARK: Pause and Stop

    @Test("A control request round-trips through a private folder and clears")
    func controlFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-run-control-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(ClaudeRunControl.pending(sessionID: "s1", in: directory) == nil)
        #expect(ClaudeRunControl.request(.pause, sessionID: "s1", in: directory))
        #expect(ClaudeRunControl.pending(sessionID: "s1", in: directory) == .pause)
        #expect(ClaudeRunControl.request(.stop, sessionID: "s1", in: directory))
        #expect(ClaudeRunControl.pending(sessionID: "s1", in: directory) == .stop)
        // A request nobody picked up goes stale.
        #expect(ClaudeRunControl.pending(
            sessionID: "s1",
            in: directory,
            now: Date().addingTimeInterval(ClaudeRunControl.requestLifetime + 60)
        ) == nil)
        ClaudeRunControl.clear(sessionID: "s1", in: directory)
        #expect(ClaudeRunControl.pending(sessionID: "s1", in: directory) == nil)

        var information = stat()
        #expect(lstat(directory.path, &information) == 0)
        #expect(information.st_mode & 0o777 == 0o700)

        ClaudeRunControl.request(.stop, sessionID: "s2", in: directory)
        ClaudeRunControl.clearAll(in: directory)
        #expect(ClaudeRunControl.pending(sessionID: "s2", in: directory) == nil)
    }

    @Test("A request is never read through a link")
    func controlFileRefusesLinks() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-run-control-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let real = directory.appendingPathComponent("elsewhere")
        try Data("stop".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("s3"), withDestinationURL: real)
        #expect(ClaudeRunControl.pending(sessionID: "s3", in: directory) == nil)
    }

    @Test("Stop ends the turn and, before a tool, refuses it")
    func stopOutput() throws {
        let before = try #require(try JSONSerialization.jsonObject(
            with: Data(ClaudeRunControl.stopOutput(beforeTool: true).utf8)
        ) as? [String: Any])
        #expect(before["continue"] as? Bool == false)
        let specific = try #require(before["hookSpecificOutput"] as? [String: Any])
        #expect(specific["permissionDecision"] as? String == "deny")

        let after = try #require(try JSONSerialization.jsonObject(
            with: Data(ClaudeRunControl.stopOutput(beforeTool: false).utf8)
        ) as? [String: Any])
        #expect(after["continue"] as? Bool == false)
        #expect(after["hookSpecificOutput"] == nil)

        #expect(ClaudeRunControl.shouldStop(afterHoldReply: Data(#"{"decision":"stop"}"#.utf8)))
        #expect(!ClaudeRunControl.shouldStop(afterHoldReply: Data(#"{"decision":"resume"}"#.utf8)))
        #expect(!ClaudeRunControl.shouldStop(afterHoldReply: Data("garbage".utf8)))
    }

    // MARK: Timeline

    @Test("Finished reads fold into one row; the running edit stays its own")
    func rowsFoldLikeTheMock() {
        var actions: [AgentRunAction] = []
        for index in 0 ..< 12 {
            AgentRunTimeline.begin(
                AgentRunAction(id: "r\(index)", tool: "Read", target: "f\(index).swift", startedAt: t0.addingTimeInterval(Double(index) * 0.1)),
                in: &actions,
                endsOpenCalls: true
            )
        }
        AgentRunTimeline.begin(AgentRunAction(id: "g1", tool: "Grep", target: "applyDiscount", startedAt: t0.addingTimeInterval(1.9)), in: &actions, endsOpenCalls: true)
        AgentRunTimeline.begin(AgentRunAction(id: "g2", tool: "Grep", target: "invoice", startedAt: t0.addingTimeInterval(2.5)), in: &actions, endsOpenCalls: true)
        AgentRunTimeline.begin(
            AgentRunAction(id: "e1", tool: "Edit", target: "src/billing/invoice.ts", startedAt: t0.addingTimeInterval(3.4)),
            in: &actions,
            endsOpenCalls: true
        )

        let rows = AgentRunTimeline.rows(for: actions)
        #expect(rows.map(\.text) == ["Read 12 files", "Ran 2 searches", "Editing src/billing/invoice.ts"])
        #expect(abs(rows[0].duration(now: t0) - 1.9) < 0.001)
        #expect(abs(rows[1].duration(now: t0) - 1.5) < 0.001)
        #expect(rows[2].isCurrent)
        #expect(AgentRunTimeline.currentText(for: actions)?.text == "Editing src/billing/invoice.ts")
    }

    @Test("With end events, parallel calls end on their own IDs")
    func parallelCallsEndByID() {
        var actions: [AgentRunAction] = []
        AgentRunTimeline.begin(AgentRunAction(id: "a", tool: "Read", target: "a", startedAt: t0), in: &actions, endsOpenCalls: false)
        AgentRunTimeline.begin(AgentRunAction(id: "b", tool: "Read", target: "b", startedAt: t0.addingTimeInterval(0.01)), in: &actions, endsOpenCalls: false)
        #expect(AgentRunTimeline.currentText(for: actions)?.text == "Reading 2 files")
        AgentRunTimeline.end(toolUseID: "a", tool: "Read", at: t0.addingTimeInterval(1), failed: false, in: &actions)
        #expect(actions[0].endedAt == t0.addingTimeInterval(1))
        #expect(actions[1].isOpen)
        AgentRunTimeline.end(toolUseID: nil, tool: "Read", at: t0.addingTimeInterval(2), failed: true, in: &actions)
        #expect(actions[1].failed)
    }

    @Test("Durations and the run clock read like the mock")
    func timeText() {
        #expect(AgentRunPhrasing.duration(1.94, running: false) == "1.9s")
        #expect(AgentRunPhrasing.duration(0.4, running: true) == "0s")
        #expect(AgentRunPhrasing.duration(75, running: false) == "1m 15s")
        #expect(AgentRunPhrasing.clock(3) == "0:03")
        #expect(AgentRunPhrasing.clock(3_729) == "1:02:09")
        #expect(AgentRunPhrasing.toolName("mcp__github__create_issue", target: nil) == "github create issue")
    }

    // MARK: Plan

    @Test("Plans come from whole lists or one task at a time")
    func planSteps() {
        var plan = AgentRunPlan.steps(fromList: [
            ["label": "Read", "status": "completed"],
            ["label": "Find", "status": "completed"],
            ["label": "Edit", "status": "in_progress"],
            ["label": "Test", "status": "pending"],
            ["label": "Docs", "status": "pending"],
            ["label": "Ship", "status": "pending"],
        ])
        #expect(AgentRunPlan.position(of: plan)?.current == 3)
        #expect(AgentRunPlan.position(of: plan)?.total == 6)

        plan = []
        for label in ["One", "Two", "Three"] {
            plan = AgentRunPlan.applying(["op": "create", "label": label], to: plan)
        }
        #expect(plan.map(\.id) == ["1", "2", "3"])
        plan = AgentRunPlan.applying(["op": "update", "id": "1", "status": "completed"], to: plan)
        plan = AgentRunPlan.applying(["op": "update", "id": "2", "status": "in_progress"], to: plan)
        #expect(AgentRunPlan.position(of: plan)?.current == 2)
        #expect(AgentRunPlan.position(of: plan)?.total == 3)
        plan = AgentRunPlan.applying(["op": "update", "id": "3", "status": "deleted"], to: plan)
        #expect(plan.count == 2)
        plan = AgentRunPlan.applying(["op": "update", "id": "2", "status": "completed"], to: plan)
        #expect(AgentRunPlan.isComplete(plan))
    }

    @Test("Model IDs read as names")
    func modelNames() {
        #expect(AgentModelName.display("claude-sonnet-5-5") == "Claude Sonnet 5.5")
        #expect(AgentModelName.display("claude-opus-4-1-20250805") == "Claude Opus 4.1")
        #expect(AgentModelName.display("claude-3-5-sonnet-20241022") == "Claude 3.5 Sonnet")
        #expect(AgentModelName.display("claude-opus-4-6[1m]") == "Claude Opus 4.6")
        #expect(AgentModelName.display("Opus 4.6 (1M context)") == "Claude Opus 4.6")
        #expect(AgentModelName.display("gpt-5-codex") == "gpt-5-codex")
    }

    @Test("The transcript's newest real model wins over synthetic notices")
    func transcriptModel() {
        let rows = """
        {"type":"assistant","message":{"model":"claude-opus-5-5","content":[]}}
        {"type":"assistant","message":{"model":"claude-sonnet-5-5","content":[]}}
        {"type":"assistant","message":{"model":"<synthetic>","content":[]}}
        """
        #expect(ClaudeConversationReader.latestModel(in: Data(rows.utf8)) == "claude-sonnet-5-5")
        #expect(ClaudeConversationReader.latestModel(in: Data()) == nil)
    }

    // MARK: Hook events into a session

    @Test("A turn's events build the card's steps, plan and clock")
    func trackerBuildsATurn() {
        var session = ClaudeCodeSession(id: "s", cwd: "/p", startedAt: t0.addingTimeInterval(-600), updatedAt: t0)
        func apply(_ event: String, _ object: [String: Any], tool: String? = nil, at seconds: Double) -> Bool {
            ClaudeCodeRunTracker.apply(object, event: event, tool: tool, now: t0.addingTimeInterval(seconds), to: &session)
        }
        _ = apply("userpromptsubmit", [:], at: 0)
        #expect(session.turnStartedAt == t0)
        _ = apply("pretooluse", ["plan": [["label": "Fix", "status": "in_progress"], ["label": "Test", "status": "pending"]]], tool: "TodoWrite", at: 0.5)
        #expect(session.plan.count == 2)
        #expect(session.actions.isEmpty)
        _ = apply("pretooluse", ["tool_use_id": "t1", "tool_target": "a.swift"], tool: "Read", at: 1)
        _ = apply("pretooluse", ["tool_use_id": "t2", "tool_target": "a.swift"], tool: "Edit", at: 3)
        // Without PostToolUse, the edit ended the read.
        #expect(session.actions[0].endedAt == t0.addingTimeInterval(3))
        #expect(session.toolCallCount == 2)
        #expect(ClaudeCodeRunTracker.detail(forStartOf: "Edit", in: session) == "Editing a.swift")

        _ = apply("stop", [:], at: 5)
        #expect(session.turnEndedAt == t0.addingTimeInterval(5))
        #expect(session.actions.allSatisfy { !$0.isOpen })

        // The next turn starts clean but keeps an unfinished plan.
        _ = apply("userpromptsubmit", [:], at: 10)
        #expect(session.actions.isEmpty)
        #expect(session.plan.count == 2)
        #expect(session.turnEndedAt == nil)
    }

    @Test("Hold and stop events change only the run's control state")
    func trackerControlEvents() {
        var session = ClaudeCodeSession(id: "s", cwd: "/p", phase: .working, startedAt: t0, updatedAt: t0)
        session.control = .pausing
        let held = ClaudeCodeRunTracker.apply(
            ["status": ClaudeRunControl.heldStatus, "tool_target": "src/a.swift"],
            event: "pretooluse",
            tool: "Edit",
            now: t0,
            to: &session
        )
        #expect(!held)
        #expect(session.control == .paused(before: "Editing src/a.swift"))
        #expect(session.phase == .working)

        // A hold that timed out let the call through; the pause still stands.
        #expect(ClaudeCodeRunTracker.apply(["tool_use_id": "x"], event: "pretooluse", tool: "Edit", now: t0, to: &session))
        #expect(session.control == .pausing)

        session.control = .stopping
        let stopped = ClaudeCodeRunTracker.apply(
            ["status": ClaudeRunControl.stoppedStatus],
            event: "pretooluse",
            tool: "Bash",
            now: t0.addingTimeInterval(4),
            to: &session
        )
        #expect(!stopped)
        #expect(session.control == nil)
        #expect(session.phase == .waiting)
        #expect(session.detail == ClaudeRunControl.stopReason)
    }

    // MARK: Card text

    @Test("The card's headline, model line and step count follow the run")
    func cardModel() {
        var session = ClaudeCodeSession(id: "s", cwd: "/Users/example/billing", phase: .working, title: "Fix invoices", startedAt: t0, updatedAt: t0)
        session.turnStartedAt = t0
        session.plan = AgentRunPlan.steps(fromList: [
            ["label": "A", "status": "completed"], ["label": "B", "status": "completed"],
            ["label": "C", "status": "in_progress"], ["label": "D", "status": "pending"],
            ["label": "E", "status": "pending"], ["label": "F", "status": "pending"],
        ])
        AgentRunTimeline.begin(
            AgentRunAction(id: "e", tool: "Edit", target: "src/billing/invoice.ts", startedAt: t0),
            in: &session.actions,
            endsOpenCalls: true
        )
        let controls = AgentRunControls(canPause: true, canStop: true)
        var model = AgentRunCardModel(
            activity: session.aiActivity,
            claudeSession: session,
            interaction: nil,
            modelName: "Claude Sonnet 5.5",
            controls: controls
        )
        #expect(model.headline == "Editing src/billing/invoice.ts")
        #expect(model.headlineSymbol == "square.and.pencil")
        #expect(model.metaLeading == "Claude Sonnet 5.5 · billing")
        #expect(model.metaTrailing == "Step 3 of 6")
        #expect(model.endedAt == nil)
        #expect(model.isRunning)

        model = AgentRunCardModel(
            activity: session.aiActivity,
            claudeSession: session,
            interaction: nil,
            modelName: nil,
            controls: AgentRunControls(canPause: true, canStop: true, state: .paused(before: "Running tests"))
        )
        #expect(model.headline == "Paused before running tests")
        #expect(!model.isRunning)
        #expect(model.controls.showsResume)

        session.plan = []
        session.toolCallCount = 14
        model = AgentRunCardModel(activity: session.aiActivity, claudeSession: session, interaction: nil, modelName: nil, controls: .none)
        #expect(model.metaTrailing == "Step 14")
        #expect(model.metaLeading == "billing")
    }
}
