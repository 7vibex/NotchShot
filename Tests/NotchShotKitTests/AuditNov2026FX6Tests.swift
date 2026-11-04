import Darwin
import Foundation
import NotchShotAIReporterSupport
import Synchronization
import Testing
@testable import NotchShotKit

@Suite("November 2026 audit: agents, Crewline and document summaries")
struct AuditNov2026FX6Tests {
    // MARK: Helpers

    private func hook(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func permissionRequest(session: String = "s", id: String = "r1", tool: String = "Bash") throws -> Data {
        try hook([
            "session_id": session,
            "hook_event_name": "PermissionRequest",
            "status": "waiting_for_approval",
            "tool_name": tool,
            "notchshot_request_id": id,
        ])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-fx6-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func connect(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EMFILE) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = path.withCString { path in
            withUnsafeMutablePointer(to: &address.sun_path) { strcpy(UnsafeMutableRawPointer($0).assumingMemoryBound(to: CChar.self), path) }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    private func send(_ object: [String: Any], to fd: Int32) throws {
        let data = try JSONSerialization.data(withJSONObject: object) + Data([10])
        let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        #expect(count == data.count)
    }

    private func wait(until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    // MARK: Permission and question cards

    @MainActor
    @Test("A sibling tool's events leave a live permission card and its state alone")
    func siblingEventsKeepTheCard() throws {
        let monitor = ClaudeCodeSessionMonitor()
        monitor.receiveHookData(try permissionRequest())
        let asked = try #require(monitor.session(for: "s"))
        #expect(asked.permission?.id == "r1")
        #expect(asked.phase == .waiting)

        for event in ["PreToolUse", "PostToolUse", "PostToolUseFailure"] {
            monitor.receiveHookData(try hook(["session_id": "s", "hook_event_name": event, "tool_name": "Read"]))
            let session = try #require(monitor.session(for: "s"))
            #expect(session.permission?.id == "r1")
            #expect(session.phase == .waiting)
            #expect(session.detail == asked.detail)
        }

        monitor.receiveHookData(try hook(["session_id": "s", "hook_event_name": "PostToolUse", "tool_name": "Bash"]))
        #expect(monitor.session(for: "s")?.permission == nil)
    }

    @Test("Only a question's own tool or the turn's end retires its card")
    func questionEndings() {
        #expect(!ClaudeCodeHookPolicy.endsQuestion(event: "posttooluse", tool: "Read"))
        #expect(!ClaudeCodeHookPolicy.endsQuestion(event: "pretooluse", tool: "Bash"))
        #expect(ClaudeCodeHookPolicy.endsQuestion(event: "posttooluse", tool: "AskUserQuestion"))
        #expect(ClaudeCodeHookPolicy.endsQuestion(event: "userpromptsubmit", tool: nil))
        #expect(ClaudeCodeHookPolicy.endsQuestion(event: "stop", tool: nil))
        #expect(ClaudeCodeHookPolicy.endsQuestion(event: "sessionend", tool: nil))
    }

    @MainActor
    @Test("A closed request clears only the card with its own ID")
    func requestClosedIsBoundToTheRequest() throws {
        let monitor = ClaudeCodeSessionMonitor()
        monitor.receiveHookData(try permissionRequest())

        monitor.requestClosed(sessionID: "s", requestID: "stale")
        #expect(monitor.session(for: "s")?.permission?.id == "r1")

        monitor.requestClosed(sessionID: "s", requestID: "r1")
        let session = try #require(monitor.session(for: "s"))
        #expect(session.permission == nil)
        #expect(session.detail == "Answer in the terminal")
    }

    @MainActor
    @Test("An answer no hook received stops claiming it was delivered")
    func undeliveredAnswerIsCorrected() async throws {
        let monitor = ClaudeCodeSessionMonitor()
        monitor.receiveHookData(try permissionRequest())

        // Nothing is holding this request, as after the hook gave up.
        monitor.deny(sessionID: "s", requestID: "r1")
        let deadline = ContinuousClock.now + .seconds(3)
        while monitor.session(for: "s")?.detail != "Answer in the terminal", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(monitor.session(for: "s")?.detail == "Answer in the terminal")
        #expect(monitor.session(for: "s")?.phase == .waiting)
    }

    @MainActor
    @Test("A late undelivered report can't overwrite a newer event")
    func staleUndeliveredReportIsIgnored() throws {
        let monitor = ClaudeCodeSessionMonitor()
        monitor.receiveHookData(try hook(["session_id": "s", "hook_event_name": "PreToolUse", "tool_name": "Read"]))
        let before = try #require(monitor.session(for: "s"))
        monitor.answerNotDelivered(sessionID: "s", answeredAt: .distantPast)
        #expect(monitor.session(for: "s") == before)
    }

    @MainActor
    @Test("A permission card expires with its hook, and the session stays")
    func permissionExpires() throws {
        let monitor = ClaudeCodeSessionMonitor()
        monitor.receiveHookData(try permissionRequest())

        monitor.pruneExpiredSessions(now: Date().addingTimeInterval(ClaudeCodeSessionMonitor.permissionLifetime - 5))
        #expect(monitor.session(for: "s")?.permission != nil)

        monitor.pruneExpiredSessions(now: Date().addingTimeInterval(ClaudeCodeSessionMonitor.permissionLifetime + 1))
        let session = try #require(monitor.session(for: "s"))
        #expect(session.permission == nil)
        #expect(session.detail == "Answer in the terminal")
    }

    @MainActor
    @Test("A failed tool mid-turn doesn't end the session; one after the turn still ages out")
    func failedToolKeepsAnOpenTurn() throws {
        let monitor = ClaudeCodeSessionMonitor()
        monitor.receiveHookData(try hook([
            "session_id": "open", "hook_event_name": "PostToolUseFailure", "tool_name": "Read",
        ]))
        let open = try #require(monitor.session(for: "open"))
        #expect(open.phase == .failed)
        monitor.pruneExpiredSessions(now: open.updatedAt.addingTimeInterval(AIActivityPolicy.terminalLifetime - 1))
        #expect(monitor.session(for: "open")?.phase == .working)

        for event in ["UserPromptSubmit", "Stop"] {
            monitor.receiveHookData(try hook(["session_id": "closed", "hook_event_name": event]))
        }
        monitor.receiveHookData(try hook([
            "session_id": "closed", "hook_event_name": "PostToolUseFailure", "tool_name": "Read",
        ]))
        let closed = try #require(monitor.session(for: "closed"))
        #expect(closed.phase == .failed)
        monitor.pruneExpiredSessions(now: closed.updatedAt.addingTimeInterval(AIActivityPolicy.terminalLifetime + 1))
        #expect(monitor.session(for: "closed") == nil)
    }

    @MainActor
    @Test("A failed tool with no later event leaves soon; a later event brings back the full lifetime")
    func settledFailureIsShortLived() throws {
        let monitor = ClaudeCodeSessionMonitor()
        for id in ["quiet", "active"] {
            monitor.receiveHookData(try hook([
                "session_id": id, "hook_event_name": "PostToolUseFailure", "tool_name": "Read",
            ]))
        }
        let failedAt = try #require(monitor.session(for: "quiet")).updatedAt
        monitor.pruneExpiredSessions(now: failedAt.addingTimeInterval(AIActivityPolicy.terminalLifetime))
        #expect(monitor.session(for: "quiet")?.phase == .working)

        monitor.receiveHookData(try hook([
            "session_id": "active", "hook_event_name": "PreToolUse", "tool_name": "Read",
        ]))
        let pastBound = failedAt.addingTimeInterval(ClaudeCodeSessionMonitor.settledFailureLifetime + 60)
        monitor.pruneExpiredSessions(now: pastBound)
        #expect(monitor.session(for: "quiet") == nil)
        #expect(monitor.session(for: "active")?.phase == .working)
    }

    @MainActor
    @Test("A quiet Crewline run doesn't take the headline from a newer Claude event")
    func quietCrewlineRunDoesNotLead() {
        let now = Date(timeIntervalSince1970: 100_000)
        let crewline = activity("crewline", state: .waiting, updatedAt: now.addingTimeInterval(-600))
        let claude = activity("claude", state: .working, updatedAt: now.addingTimeInterval(-5))
        let visible = AIActivityPolicy.visibleActivities(
            from: [claude] + ContextCoordinator.stampingLive([crewline], at: now),
            now: now
        )
        #expect(visible.map(\.id) == ["claude", "crewline"])
    }

    @Test("A rate-limited stop leaves the session waiting")
    func stopFailureWaits() {
        #expect(ClaudeCodeHookPolicy.phase(event: "StopFailure", status: nil, notificationType: nil) == .waiting)
        #expect(ClaudeCodeHookPolicy.phase(event: "PostToolUseFailure", status: nil, notificationType: nil) == .failed)
    }

    // MARK: Hook server

    @Test("The server reports a held request's hook going away")
    func serverReportsClosedRequest() async throws {
        let path = "/tmp/notchshot-fx6-\(UUID().uuidString).sock"
        let received = Mutex<[Data]>([])
        let closed = Mutex<[String]>([])
        let server = ClaudeCodeHookServer(socketPath: path, decisionTimeout: 5)
        server.start(
            onData: { data in received.withLock { $0.append(data) } },
            onRequestClosed: { _, requestID in closed.withLock { $0.append(requestID) } }
        )
        defer { server.stopAndWait() }
        #expect(server.clientCount == 0) // Also fences asynchronous startup.

        let client = try connect(path)
        try send(["session_id": "held", "hook_event_name": "PermissionRequest", "tool_name": "Bash"], to: client)
        try await wait { received.withLock { $0.count == 1 } }
        let event = try #require(try JSONSerialization.jsonObject(with: received.withLock { $0[0] }) as? [String: Any])
        let requestID = try #require(event["notchshot_request_id"] as? String)

        close(client)
        try await wait { closed.withLock { $0 == [requestID] } }
    }

    @Test("An answer reports non-delivery only when no hook received it")
    func serverReportsUndelivered() async throws {
        let path = "/tmp/notchshot-fx6-\(UUID().uuidString).sock"
        let received = Mutex<[Data]>([])
        let undelivered = Mutex(0)
        let server = ClaudeCodeHookServer(socketPath: path, decisionTimeout: 5)
        server.start { data in received.withLock { $0.append(data) } }
        defer { server.stopAndWait() }
        #expect(server.clientCount == 0)

        server.respond(sessionID: "nobody", requestID: "gone", decision: "allow", reason: nil) {
            undelivered.withLock { $0 += 1 }
        }
        try await wait { undelivered.withLock { $0 == 1 } }

        let client = try connect(path)
        defer { close(client) }
        try send(["session_id": "held", "hook_event_name": "PermissionRequest", "tool_name": "Bash"], to: client)
        try await wait { received.withLock { $0.count == 1 } }
        let event = try #require(try JSONSerialization.jsonObject(with: received.withLock { $0[0] }) as? [String: Any])

        // Bound to the exact request: a wrong ID reaches nothing and says so.
        server.respond(sessionID: "held", requestID: "stale", decision: "allow", reason: nil) {
            undelivered.withLock { $0 += 1 }
        }
        try await wait { undelivered.withLock { $0 == 2 } }

        server.respond(sessionID: "held", requestID: event["notchshot_request_id"] as? String, decision: "deny", reason: nil) {
            undelivered.withLock { $0 += 1 }
        }
        var descriptor = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
        #expect(poll(&descriptor, 1, 1_000) > 0)
        var bytes = [UInt8](repeating: 0, count: 1_024)
        let count = Darwin.read(client, &bytes, bytes.count)
        #expect(String(decoding: bytes.prefix(max(0, count)), as: UTF8.self).contains("deny"))
        #expect(server.clientCount == 0) // Fences the respond above.
        #expect(undelivered.withLock { $0 } == 2)
    }

    @Test("Hooks waiting on a decision don't take the slots short events need")
    func waitingClientsLeaveRoom() async throws {
        let path = "/tmp/notchshot-fx6-\(UUID().uuidString).sock"
        let received = Mutex<[Data]>([])
        let server = ClaudeCodeHookServer(socketPath: path, maximumClients: 1, decisionTimeout: 5)
        server.start { data in received.withLock { $0.append(data) } }
        defer { server.stopAndWait() }
        #expect(server.clientCount == 0)

        let waiting = try connect(path)
        defer { close(waiting) }
        try send(["session_id": "held", "hook_event_name": "PermissionRequest", "tool_name": "Bash"], to: waiting)
        try await wait { received.withLock { $0.count == 1 } }

        let short = try connect(path)
        defer { close(short) }
        try send(["session_id": "other", "hook_event_name": "SessionStart"], to: short)
        try await wait { received.withLock { $0.count == 2 } }
    }

    // MARK: HTML text

    @Test("HTML text comes out without scripts, styles or anything remote")
    func htmlToText() {
        let page = """
        <html><head><style>p { color: red }</style><script>var secret = 1</script></head>
        <body background="https&#58;&#47;&#47;attacker.example/x.gif">
        <!-- a comment --><p>Fish &amp; chips, caf&eacute; &#x263A;</p>
        <ul><li>one</li><li>two</li></ul></body></html>
        """
        let text = DocumentSummaryService.plainText(fromHTML: page)
        #expect(text.contains("Fish & chips, café ☺"))
        #expect(text.contains("one"))
        #expect(text.contains("two"))
        #expect(!text.contains("onetwo"))
        #expect(!text.contains("secret"))
        #expect(!text.contains("color"))
        #expect(!text.contains("attacker"))
        #expect(!text.contains("comment"))
    }

    @Test("Deeply nested or unterminated HTML still returns its text")
    func hostileHTMLIsBounded() {
        let nested = String(repeating: "<div>", count: 50_000) + "deep"
        #expect(DocumentSummaryService.plainText(fromHTML: nested).contains("deep"))
        #expect(!DocumentSummaryService.plainText(fromHTML: "<p>kept</p><script>never closed").contains("never"))
    }

    // MARK: Activity history

    private func activity(
        _ id: String,
        state: AIActivityState = .finished,
        updatedAt: Date
    ) -> AIActivitySnapshot {
        AIActivitySnapshot(id: id, source: .codex, state: state, title: id, updatedAt: updatedAt)
    }

    @Test("Status files from before a Clear don't bring their rows back")
    func clearedHistoryStaysClear() {
        let cleared = Date(timeIntervalSince1970: 2_000)
        let before = activity("before", updatedAt: cleared.addingTimeInterval(-60))
        let at = activity("at", updatedAt: cleared)
        let after = activity("after", updatedAt: cleared.addingTimeInterval(60))

        #expect(AIActivityHistoryPolicy.merging([before, at, after], into: [], clearedAt: cleared).map(\.id) == ["after"])
        #expect(AIActivityHistoryPolicy.merging([before], into: []).map(\.id) == ["before"])
    }

    // MARK: Plan and timeline

    @Test("Task updates find their rows when Claude's numbers run ahead")
    func planNumbersCatchUp() {
        var plan: [AIActivityStep] = []
        for label in ["One", "Two", "Three"] {
            plan = AgentRunPlan.applying(["op": "create", "label": label], to: plan)
        }
        plan = AgentRunPlan.applying(["op": "update", "id": "7", "status": "in_progress"], to: plan)
        #expect(plan.map(\.id) == ["7", "8", "9"])
        #expect(plan[0].state == .working)
        plan = AgentRunPlan.applying(["op": "update", "id": "7", "status": "completed"], to: plan)
        #expect(plan[0].state == .completed)

        plan = AgentRunPlan.applying(["op": "update", "id": "8", "status": "in_progress"], to: plan)
        #expect(plan[1].state == .working)
        #expect(plan[0].state == .completed)

        plan = AgentRunPlan.applying(["op": "create", "label": "Four"], to: plan)
        #expect(plan.last?.id == "10")
    }

    @Test("An update that can't be placed changes nothing")
    func planUpdatesThatDoNotFit() {
        let plan = [
            AIActivityStep(id: "5", label: "Five", state: .pending),
            AIActivityStep(id: "6", label: "Six", state: .pending),
        ]
        #expect(AgentRunPlan.applying(["op": "update", "id": "9", "status": "deleted"], to: plan) == plan)
        // A task the app never saw is not the first unfinished row.
        #expect(AgentRunPlan.applying(["op": "update", "id": "9", "status": "completed"], to: plan) == plan)
        #expect(AgentRunPlan.applying(["op": "update", "id": "9", "label": "Renamed"], to: plan) == plan)
        #expect(AgentRunPlan.applying(["op": "update", "id": "2", "status": "completed"], to: plan) == plan)
        #expect(AgentRunPlan.applying(["op": "update", "id": "x", "status": "completed"], to: plan) == plan)
        #expect(AgentRunPlan.applying(
            ["op": "update", "id": "99999999999999", "status": "completed"],
            to: plan
        ) == plan)
    }

    @Test("A call that matches nothing doesn't end someone else's")
    func unmatchedEndLeavesOpenCalls() {
        let start = Date(timeIntervalSince1970: 1_000)
        var actions = [AgentRunAction(id: "agent", tool: "Agent", startedAt: start)]
        let later = start.addingTimeInterval(1)

        AgentRunTimeline.end(toolUseID: "todo", tool: "TodoWrite", at: later, failed: false, in: &actions)
        #expect(actions[0].isOpen)

        AgentRunTimeline.end(toolUseID: nil, tool: nil, at: later, failed: false, in: &actions)
        #expect(!actions[0].isOpen)
    }

    @Test("A plan tool finishing leaves the open call running")
    func planToolsEndNothing() {
        let start = Date(timeIntervalSince1970: 1_000)
        var session = ClaudeCodeSession(
            id: "s", cwd: "", phase: .working, title: "t", startedAt: start, updatedAt: start
        )
        session.actions = [AgentRunAction(id: "agent", tool: "Agent", startedAt: start)]
        for event in ["posttooluse", "posttoolusefailure"] {
            _ = ClaudeCodeRunTracker.apply([:], event: event, tool: "TodoWrite", now: start.addingTimeInterval(1), to: &session)
            #expect(session.actions[0].isOpen)
        }
    }

    // MARK: Hook installer

    @MainActor
    @Test("Replacing a moved hook keeps the user's own hook in the same entry")
    func movedHookKeepsNeighbours() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let claude = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        let reporter = home.appendingPathComponent("notchshot-ai")
        try Data("#!/bin/sh\n".utf8).write(to: reporter)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: reporter.path)
        let settings = claude.appendingPathComponent("settings.json")
        try Data(#"""
        {"hooks": {"Stop": [
            {"matcher": "", "hooks": [
                {"type": "command", "command": "/old/place/notchshot-ai report"},
                {"type": "command", "command": "my-own-hook"}
            ]},
            {"matcher": "", "hooks": [{"type": "command", "command": "/old/place/notchshot-ai again"}]}
        ]}}
        """#.utf8).write(to: settings)

        _ = try AIHookInstaller(home: home).install(.claude, reporterURL: reporter)

        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        let hooks = try #require(root["hooks"] as? [String: Any])
        let entries = try #require(hooks["Stop"] as? [[String: Any]])
        let commands = entries
            .flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            .compactMap { $0["command"] as? String }
        #expect(commands.contains("my-own-hook"))
        #expect(!commands.contains { $0.contains("/old/place/") })
        #expect(commands.contains { $0.contains(reporter.path) })
        // The entry that held only the old hook went with it.
        #expect(entries.count == 2)
    }

    // MARK: Usage files

    @Test("Usage reads only the files that can matter, and retention still applies")
    func usageReadsWhatMatters() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let window = ClaudeStatusSnapshot.Window(usedPercent: 10, resetsAt: nil)

        func write(_ name: String, age: TimeInterval, windows: Bool) throws {
            let url = folder.appendingPathComponent(name + ".json")
            let snapshot = ClaudeStatusSnapshot(
                sessionID: name,
                fiveHour: windows ? window : nil,
                updatedAt: now.addingTimeInterval(-age)
            )
            try encoder.encode(snapshot).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-age)],
                ofItemAtPath: url.path
            )
        }
        try write("recent", age: 60, windows: false)
        try write("alsoRecent", age: 120, windows: true)
        try write("noWindows", age: 3_600, windows: false)
        try write("older", age: 7_200, windows: true)
        try write("expired", age: 9 * 24 * 3_600, windows: true)

        let names = Set(ClaudeUsageMonitor.readSnapshots(in: folder, now: now).map(\.sessionID))
        #expect(names == ["recent", "alsoRecent"])
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("expired.json").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("older.json").path))

        // With no recent windows, reading goes on to the newest old file that has them.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("alsoRecent.json"))
        let fallback = Set(ClaudeUsageMonitor.readSnapshots(in: folder, now: now).map(\.sessionID))
        #expect(fallback == ["recent", "noWindows", "older"])
    }

    // MARK: Crewline

    @Test("An approval keeps its place across reads")
    func approvalKeepsFirstSeen() throws {
        let seen = Date(timeIntervalSince1970: 1_000)
        let workspace = CrewlineWorkspace(approvals: [
            CrewlineApproval(id: "a", runID: "run", tool: "Bash", summary: nil),
        ])
        let first = try #require(CrewlineActivityMapper.approvalInteractions(from: workspace, firstSeen: ["a": seen]).first)
        let second = try #require(CrewlineActivityMapper.approvalInteractions(from: workspace, firstSeen: ["a": seen]).first)
        #expect(first.receivedAt == seen)
        #expect(first == second)
    }

    @MainActor
    @Test("A read's fresh stamp isn't a change, and a quiet live run stays live")
    func liveStampsIgnoredAndRenewed() {
        let early = Date(timeIntervalSince1970: 1_000)
        let late = Date(timeIntervalSince1970: 9_000)
        let live = activity("run", state: .waiting, updatedAt: early)
        var moved = live
        moved.updatedAt = late

        #expect(ContextCoordinator.withoutLiveStamps([live]) == ContextCoordinator.withoutLiveStamps([moved]))

        var retitled = moved
        retitled.title = "Another"
        #expect(ContextCoordinator.withoutLiveStamps([live]) != ContextCoordinator.withoutLiveStamps([retitled]))

        let finishedEarly = activity("done", updatedAt: early)
        let finishedLate = activity("done", updatedAt: late)
        #expect(ContextCoordinator.withoutLiveStamps([finishedEarly]) != ContextCoordinator.withoutLiveStamps([finishedLate]))

        // A quiet run keeps its stamp until it nears the deadline, then stays
        // five minutes from it, so it never ages out and never jumps the queue.
        let stamped = ContextCoordinator.stampingLive([live, finishedEarly], at: early.addingTimeInterval(60))
        #expect(stamped[0].updatedAt == early)
        #expect(stamped[1].updatedAt == early)
        let floored = ContextCoordinator.stampingLive([live], at: late)[0]
        #expect(AIActivityPolicy.deadline(for: floored) == late.addingTimeInterval(300))
    }

    @Test("A descriptor from a dead server isn't a running Crewline")
    func descriptorNeedsItsProcess() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let userdata = home.appendingPathComponent("userdata", isDirectory: true)
        try FileManager.default.createDirectory(at: userdata, withIntermediateDirectories: true)
        let descriptor = userdata.appendingPathComponent("connection.json")
        let host = CrewlineLocalHost(homeURL: home)

        func write(_ object: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: object).write(to: descriptor)
        }
        try write(["wsPort": 4_321, "pid": Int(getpid())])
        #expect(host.port() == 4_321)
        // Older builds may write no PID at all.
        try write(["wsPort": 4_321])
        #expect(host.port() == 4_321)
        // Past the highest PID macOS hands out.
        try write(["wsPort": 4_321, "pid": 99_999_999])
        #expect(host.port() == nil)
        try write(["wsPort": 4_321, "pid": 1])
        #expect(host.port() == nil)
    }
}
