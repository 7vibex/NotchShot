import Darwin
import Foundation
import NotchShotAIReporterSupport
import Synchronization
import Testing
@testable import NotchShotKit

@Suite("Claude action approval safety")
struct ClaudePermissionSafetyTests {
    private func action(_ command: String = "printf 'hello  world'\nprintf done") -> String? {
        ClaudePermissionDetails.actionDescription(tool: "Bash", input: ["command": command], cwd: "/tmp/synthetic-project")
    }

    @Test("Complete action details preserve command whitespace and flags")
    func completeDetails() throws {
        let description = try #require(ClaudePermissionDetails.actionDescription(
            tool: "Bash", input: ["command": "printf 'hello  world'\nprintf done", "timeout": 1_000, "run_in_background": true],
            cwd: "/tmp/synthetic-project"
        ))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(description.utf8)) as? [String: Any])
        #expect(object["command"] as? String == "printf 'hello  world'\nprintf done")
        #expect(object["run_in_background"] as? Bool == true)
        #expect(ClaudePermissionDetails.validated(description, tool: "Bash") == description)
    }

    @Test("Missing, hidden, oversized, unsupported or misleading details require the terminal")
    func incompleteDetails() {
        #expect(ClaudePermissionDetails.actionDescription(tool: "Bash", input: [:], cwd: "/tmp") == nil)
        #expect(ClaudePermissionDetails.actionDescription(tool: "Bash", input: ["command": "pwd"], cwd: nil) == nil)
        #expect(ClaudePermissionDetails.actionDescription(tool: "Write", input: ["command": "pwd"], cwd: "/tmp") == nil)
        #expect(ClaudePermissionDetails.actionDescription(tool: "Bash", input: ["command": "pwd", "unknown_option": true], cwd: "/tmp") == nil)
        #expect(action("printf -- --password synthetic-secret") == nil)
        #expect(action(String(repeating: "x", count: ClaudePermissionDetails.maximumBytes + 1)) == nil)
        #expect(action("printf safe\u{202E}hidden") == nil)
        #expect(ClaudePermissionDetails.validated("{\"command\":\"pwd\"}", tool: "Bash") == nil)
    }

    @Test("Legacy persisted requests cannot become approvable from a summary")
    func legacyRequest() throws {
        let original = ClaudeCodePermissionRequest(toolName: "Bash", detail: "Please approve")
        let decoded = try JSONDecoder().decode(ClaudeCodePermissionRequest.self, from: JSONEncoder().encode(original))
        #expect(!decoded.canApproveInline)
        #expect(decoded.reviewActionTitle == "Review in Terminal")
    }

    @MainActor
    private func deliver(_ monitor: ClaudeCodeSessionMonitor, id: String, action: String?) throws {
        var object: [String: Any] = [
            "session_id": "synthetic", "hook_event_name": "PermissionRequest", "tool_name": "Bash",
            "cwd": "/tmp/synthetic-project", "notchshot_request_id": id,
        ]
        if let action { object["permission_action"] = action }
        monitor.receiveHookData(try JSONSerialization.data(withJSONObject: object))
    }

    @Test("The monitor requires complete details and the displayed request identity")
    @MainActor
    func approvalAdmission() throws {
        let monitor = ClaudeCodeSessionMonitor()
        try deliver(monitor, id: "missing", action: nil)
        monitor.approve(sessionID: "synthetic", requestID: "missing")
        #expect(monitor.session(for: "synthetic")?.permission?.id == "missing")
        let complete = try #require(action())
        try deliver(monitor, id: "old", action: complete)
        try deliver(monitor, id: "current", action: complete)
        monitor.approve(sessionID: "synthetic", requestID: "old")
        monitor.approve(sessionID: "synthetic")
        #expect(monitor.session(for: "synthetic")?.permission?.id == "current")
        let session = try #require(monitor.session(for: "synthetic"))
        let interaction = try #require(AppCoordinator.interactions(for: session).first)
        if case .approval(let request) = interaction.kind {
            #expect(request.reviewActionTitle == "Review…")
        } else { Issue.record("Permission was not represented as an approval") }
        monitor.approve(sessionID: "synthetic", requestID: "current")
        #expect(monitor.session(for: "synthetic")?.permission == nil)
        #expect(monitor.session(for: "synthetic")?.phase == .working)
    }

    @Test("Terminal review releases a permission without marking it approved or denied")
    @MainActor
    func terminalFallback() throws {
        let monitor = ClaudeCodeSessionMonitor()
        try deliver(monitor, id: "terminal", action: nil)
        monitor.answerInTerminal(sessionID: "synthetic", requestID: "stale")
        #expect(monitor.session(for: "synthetic")?.permission != nil)
        monitor.answerInTerminal(sessionID: "synthetic", requestID: "terminal")
        #expect(monitor.session(for: "synthetic")?.permission == nil)
        #expect(monitor.session(for: "synthetic")?.phase == .waiting)
    }
}

@Suite("Claude hook socket resource bounds", .serialized)
struct ClaudeHookResourceTests {
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

    @Test("Idle connections are capped, retired, and followed by a valid event")
    func idleClientsRecover() async throws {
        let path = "/tmp/notchshot-audit-\(UUID().uuidString).sock"
        let received = Mutex<[Data]>([])
        let server = ClaudeCodeHookServer(socketPath: path, maximumClients: 3, readTimeout: 0.5)
        server.start { data in received.withLock { $0.append(data) } }
        defer { server.stopAndWait() }
        #expect(server.clientCount == 0) // Also fences asynchronous startup.
        var clients: [Int32] = []
        defer { clients.forEach { close($0) } }
        for _ in 0 ..< 3 { clients.append(try connect(path)) }
        try await wait { server.clientCount == 3 }
        for _ in 0 ..< 3 { clients.append(try connect(path)) }
        #expect(server.clientCount <= 3)
        try await wait { server.clientCount == 0 }
        let valid = try connect(path)
        defer { close(valid) }
        try send(["session_id": "recovered", "hook_event_name": "SessionStart"], to: valid)
        try await wait { received.withLock { !$0.isEmpty } }
        #expect(String(decoding: received.withLock { $0.last! }, as: UTF8.self).contains("recovered"))
    }

    @Test("A stale decision cannot answer a newer held request in the same session")
    func staleResponse() async throws {
        let path = "/tmp/notchshot-audit-\(UUID().uuidString).sock"
        let received = Mutex<[Data]>([])
        let server = ClaudeCodeHookServer(socketPath: path, decisionTimeout: 3)
        server.start { data in received.withLock { $0.append(data) } }
        defer { server.stopAndWait() }
        #expect(server.clientCount == 0)
        let first = try connect(path)
        defer { close(first) }
        let event: [String: Any] = ["session_id": "held", "hook_event_name": "PermissionRequest", "tool_name": "Bash"]
        try send(event, to: first)
        try await wait { received.withLock { $0.count == 1 } }
        let old = try #require(try JSONSerialization.jsonObject(with: received.withLock { $0[0] }) as? [String: Any])
        let second = try connect(path)
        defer { close(second) }
        try send(event, to: second)
        try await wait { received.withLock { $0.count == 2 } }
        let current = try #require(try JSONSerialization.jsonObject(with: received.withLock { $0[1] }) as? [String: Any])
        server.respond(sessionID: "held", requestID: old["notchshot_request_id"] as? String, decision: "allow", reason: nil)
        var descriptor = pollfd(fd: second, events: Int16(POLLIN), revents: 0)
        #expect(poll(&descriptor, 1, 50) == 0)
        server.respond(sessionID: "held", requestID: current["notchshot_request_id"] as? String, decision: "deny", reason: nil)
        #expect(poll(&descriptor, 1, 1_000) > 0)
        var bytes = [UInt8](repeating: 0, count: 1_024)
        let count = Darwin.read(second, &bytes, bytes.count)
        #expect(count > 0)
        #expect(String(decoding: bytes.prefix(max(0, count)), as: UTF8.self).contains("deny"))
    }

    @Test("Held decisions have a finite lifetime")
    func heldDecisionExpires() async throws {
        let path = "/tmp/notchshot-audit-\(UUID().uuidString).sock"
        let received = Mutex(false)
        let server = ClaudeCodeHookServer(socketPath: path, readTimeout: 1, decisionTimeout: 0.1)
        server.start { _ in received.withLock { $0 = true } }
        defer { server.stopAndWait() }
        #expect(server.clientCount == 0)
        let client = try connect(path)
        defer { close(client) }
        try send(["session_id": "held", "hook_event_name": "PermissionRequest"], to: client)
        try await wait { received.withLock { $0 } }
        try await wait { server.clientCount == 0 }
    }
}
