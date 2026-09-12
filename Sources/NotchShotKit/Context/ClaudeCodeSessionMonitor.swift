import Darwin
import Foundation
import NotchShotAIReporterSupport
import Observation

public enum ClaudeCodeSessionPhase: String, Codable, Equatable, Sendable {
    case working
    case waiting
    case finished
    case failed

    public var title: String {
        switch self {
        case .working: "Working"
        case .waiting: "Waiting"
        case .finished: "Finished"
        case .failed: "Failed"
        }
    }

    public var aiState: AIActivityState {
        switch self {
        case .working: .working
        case .waiting: .waiting
        case .finished: .finished
        case .failed: .failed
        }
    }

    public var isTerminal: Bool { self == .finished || self == .failed }
}

public struct ClaudeCodePermissionRequest: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var toolName: String
    public var detail: String?
    public var receivedAt: Date

    public init(
        id: String = UUID().uuidString,
        toolName: String,
        detail: String? = nil,
        receivedAt: Date = Date()
    ) {
        self.id = id
        self.toolName = toolName
        self.detail = detail
        self.receivedAt = receivedAt
    }
}

public struct ClaudeCodeSession: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var cwd: String
    public var pid: Int?
    public var tty: String?
    public var phase: ClaudeCodeSessionPhase
    public var title: String
    public var detail: String?
    public var lastTool: String?
    public var permission: ClaudeCodePermissionRequest?
    public var startedAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        cwd: String,
        pid: Int? = nil,
        tty: String? = nil,
        phase: ClaudeCodeSessionPhase = .working,
        title: String = "Claude Code session",
        detail: String? = nil,
        lastTool: String? = nil,
        permission: ClaudeCodePermissionRequest? = nil,
        startedAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.cwd = cwd
        self.pid = pid
        self.tty = tty
        self.phase = phase
        self.title = title
        self.detail = detail
        self.lastTool = lastTool
        self.permission = permission
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }

    public var workspaceName: String {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    public var aiActivity: AIActivitySnapshot {
        let steps: [AIActivityStep] = if let lastTool, !lastTool.isEmpty {
            [AIActivityStep(
                id: "last-tool",
                label: "Using \(lastTool)",
                state: phase == .failed
                    ? .failed
                    : phase == .working ? .working : .completed
            )]
        } else {
            []
        }
        return AIActivitySnapshot(
            id: id,
            source: .claude,
            state: phase.aiState,
            title: title,
            detail: detail,
            workspace: cwd.isEmpty ? nil : cwd,
            steps: steps,
            startedAt: startedAt,
            updatedAt: updatedAt
        )
    }
}

/// Pure event policy shared by the live monitor and its contract tests.
enum ClaudeCodeHookPolicy {
    static func phase(event: String, status: String?, notificationType: String?) -> ClaudeCodeSessionPhase {
        let normalizedEvent = normalized(event)
        let normalizedStatus = normalized(status ?? "")
        let normalizedNotification = normalized(notificationType ?? "")

        if normalizedEvent.contains("permissionrequest") || normalizedStatus.contains("waitingforapproval") {
            return .waiting
        }
        if normalizedEvent.contains("posttoolusefailure")
            || normalizedEvent.contains("permissiondenied")
            || normalizedEvent.contains("failure") {
            return .failed
        }
        if normalizedEvent.contains("sessionend") {
            return .finished
        }
        if normalizedEvent.contains("notification") {
            return .waiting
        }
        if normalizedNotification.contains("idleprompt") || normalizedStatus.contains("waitingforinput") {
            return .waiting
        }
        if normalizedEvent == "stop" || normalizedEvent.contains("stopfailure") || normalizedEvent.contains("sessionstart") {
            return .waiting
        }
        return .working
    }

    static func normalized(_ value: String) -> String {
        value.lowercased().filter(\.isLetter)
    }

    static func bounded(_ value: String?, maximum: Int) -> String? {
        guard let value else { return nil }
        let result = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximum))
        return result.isEmpty ? nil : result
    }

    static func detail(
        event: String,
        phase: ClaudeCodeSessionPhase,
        tool: String?,
        notificationType: String?,
        message: String?
    ) -> String? {
        if phase == .waiting, normalized(event).contains("permissionrequest") {
            return tool.map { "Waiting for permission to use \(bounded($0, maximum: 80) ?? "Claude Code tool")" }
                ?? "Waiting for permission"
        }
        if let tool = bounded(tool, maximum: 80) {
            return "Using \(tool)"
        }
        if let message = bounded(message, maximum: 180) {
            return message
        }
        let normalizedEvent = normalized(event)
        if normalizedEvent.contains("precompact") { return "Compacting context" }
        if normalizedEvent == "stop" || normalizedEvent.contains("stopfailure") {
            return "Waiting for your next prompt"
        }
        if normalizedEvent.contains("sessionend") { return "Session ended" }
        if phase == .waiting, normalized(notificationType ?? "").contains("idleprompt") {
            return "Waiting for your next prompt"
        }
        return nil
    }
}

/// Unix socket transport used by the bundled Claude hook. All mutable state is
/// confined to `queue`; the unchecked marker documents that invariant for
/// Swift's strict concurrency checking.
private final class ClaudeCodeHookServer: @unchecked Sendable {
    static let socketPath = ClaudeHookSocket.path
    private static let maximumMessageBytes = 64 * 1_024

    private final class Client: @unchecked Sendable {
        let fileDescriptor: Int32
        var source: DispatchSourceRead?
        var buffer = Data()
        var handledMessage = false

        init(fileDescriptor: Int32) {
            self.fileDescriptor = fileDescriptor
        }
    }

    private let queue = DispatchQueue(
        label: "com.notchshot.claude-hook-socket",
        qos: .userInitiated
    )
    private var serverFileDescriptor: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var eventHandler: (@Sendable (Data) -> Void)?
    private var clients: [Int32: Client] = [:]
    private var pendingBySession: [String: Int32] = [:]

    func start(onData: @escaping @Sendable (Data) -> Void) {
        queue.async { [weak self] in
            self?.startOnQueue(onData: onData)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopOnQueue()
        }
    }

    func respond(sessionID: String, decision: String, reason: String?) {
        queue.async { [weak self] in
            self?.respondOnQueue(sessionID: sessionID, decision: decision, reason: reason)
        }
    }

    private func startOnQueue(onData: @escaping @Sendable (Data) -> Void) {
        guard serverFileDescriptor < 0 else { return }
        guard removeStaleSocketIfSafe() else {
            Log.app.error("Claude hook socket path could not be reclaimed safely")
            return
        }
        eventHandler = onData

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return }
        serverFileDescriptor = descriptor
        setNonBlocking(descriptor)
        setNoSIGPIPE(descriptor)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        Self.socketPath.withCString { path in
            withUnsafeMutablePointer(to: &address.sun_path) { pathPointer in
                let buffer = UnsafeMutableRawPointer(pathPointer).assumingMemoryBound(to: CChar.self)
                strcpy(buffer, path)
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            close(descriptor)
            serverFileDescriptor = -1
            Log.app.error("Claude hook socket bind failed with errno \(code)")
            return
        }
        chmod(Self.socketPath, 0o600)
        guard listen(descriptor, 16) == 0 else {
            let code = errno
            close(descriptor)
            serverFileDescriptor = -1
            unlink(Self.socketPath)
            Log.app.error("Claude hook socket listen failed with errno \(code)")
            return
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnections()
        }
        source.setCancelHandler { [weak self] in
            guard let self, self.serverFileDescriptor >= 0 else { return }
            close(self.serverFileDescriptor)
            self.serverFileDescriptor = -1
        }
        acceptSource = source
        source.resume()
    }

    private func stopOnQueue() {
        acceptSource?.setCancelHandler {}
        acceptSource?.cancel()
        acceptSource = nil
        if serverFileDescriptor >= 0 {
            close(serverFileDescriptor)
            serverFileDescriptor = -1
        }
        for fileDescriptor in Array(clients.keys) {
            closeClient(fileDescriptor)
        }
        clients.removeAll()
        pendingBySession.removeAll()
        eventHandler = nil
        _ = removeStaleSocketIfSafe()
    }

    private func acceptConnections() {
        guard serverFileDescriptor >= 0 else { return }
        while true {
            let clientFileDescriptor = accept(serverFileDescriptor, nil, nil)
            guard clientFileDescriptor >= 0 else {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                return
            }
            setNonBlocking(clientFileDescriptor)
            setNoSIGPIPE(clientFileDescriptor)
            guard ClaudeHookSocket.isTrustedPeer(clientFileDescriptor) else {
                Log.app.error("Rejected a Claude hook socket connection from another user")
                close(clientFileDescriptor)
                continue
            }
            let client = Client(fileDescriptor: clientFileDescriptor)
            clients[clientFileDescriptor] = client
            let source = DispatchSource.makeReadSource(
                fileDescriptor: clientFileDescriptor,
                queue: queue
            )
            source.setEventHandler { [weak self, weak client] in
                guard let self, let client else { return }
                self.read(client)
            }
            source.setCancelHandler {
                close(clientFileDescriptor)
            }
            client.source = source
            source.resume()
        }
    }

    private func read(_ client: Client) {
        var bytes = [UInt8](repeating: 0, count: 4_096)
        let count = Darwin.read(client.fileDescriptor, &bytes, bytes.count)
        if count > 0 {
            client.buffer.append(contentsOf: bytes.prefix(count))
            guard client.buffer.count <= Self.maximumMessageBytes else {
                closeClient(client.fileDescriptor)
                return
            }
            if let newline = client.buffer.firstIndex(of: 10), !client.handledMessage {
                let message = Data(client.buffer[..<newline])
                client.handledMessage = true
                handle(message: message, from: client)
            }
        } else if count == 0 {
            if !client.handledMessage, !client.buffer.isEmpty {
                client.handledMessage = true
                handle(message: client.buffer, from: client)
            }
            closeClient(client.fileDescriptor)
        } else if errno != EAGAIN && errno != EWOULDBLOCK {
            closeClient(client.fileDescriptor)
        }
    }

    private func handle(message: Data, from client: Client) {
        guard message.count <= Self.maximumMessageBytes,
              let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any]
        else {
            closeClient(client.fileDescriptor)
            return
        }

        eventHandler?(message)
        let event = (object["hook_event_name"] as? String)
            ?? (object["event"] as? String)
            ?? ""
        let status = (object["status"] as? String) ?? ""
        let sessionID = (object["session_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedEvent = ClaudeCodeHookPolicy.normalized(event)
        let expectsResponse = normalizedEvent.contains("permissionrequest")
            || ClaudeCodeHookPolicy.normalized(status).contains("waitingforapproval")

        guard expectsResponse, !sessionID.isEmpty else {
            closeClient(client.fileDescriptor)
            return
        }

        if let previousFileDescriptor = pendingBySession[sessionID], previousFileDescriptor != client.fileDescriptor {
            closeClient(previousFileDescriptor)
        }
        pendingBySession[sessionID] = client.fileDescriptor
    }

    private func respondOnQueue(sessionID: String, decision: String, reason: String?) {
        guard let fileDescriptor = pendingBySession.removeValue(forKey: sessionID) else { return }
        var response: [String: Any] = ["decision": decision]
        if let reason {
            response["reason"] = String(reason.prefix(240))
        }
        guard let data = try? JSONSerialization.data(withJSONObject: response),
              writeAll(data + Data([10]), to: fileDescriptor) else {
            closeClient(fileDescriptor)
            return
        }
        closeClient(fileDescriptor)
    }

    private func writeAll(_ data: Data, to fileDescriptor: Int32) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return true }
            var pointer = baseAddress.assumingMemoryBound(to: UInt8.self)
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(fileDescriptor, pointer, remaining)
                guard written > 0 else { return false }
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
            return true
        }
    }

    private func closeClient(_ fileDescriptor: Int32) {
        pendingBySession = pendingBySession.filter { $0.value != fileDescriptor }
        guard let client = clients.removeValue(forKey: fileDescriptor) else {
            close(fileDescriptor)
            return
        }
        client.source?.setCancelHandler {}
        client.source?.cancel()
        close(fileDescriptor)
    }

    private func setNonBlocking(_ fileDescriptor: Int32) {
        let flags = fcntl(fileDescriptor, F_GETFL)
        if flags >= 0 { _ = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) }
    }

    private func setNoSIGPIPE(_ fileDescriptor: Int32) {
        var value: Int32 = 1
        _ = setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &value,
            socklen_t(MemoryLayout<Int32>.size)
        )
    }

    private func removeStaleSocketIfSafe() -> Bool {
        var information = stat()
        guard lstat(Self.socketPath, &information) == 0 else {
            return errno == ENOENT
        }
        guard (information.st_mode & S_IFMT) == S_IFSOCK else { return false }
        return unlink(Self.socketPath) == 0
    }
}

@MainActor
@Observable
public final class ClaudeCodeSessionMonitor {
    public static let shared = ClaudeCodeSessionMonitor()

    public private(set) var sessions: [ClaudeCodeSession] = []
    public private(set) var snapshot: ContextSnapshot?
    public private(set) var isRunning = false
    public var onSnapshotChange: ((ContextSnapshot?) -> Void)?

    private let server = ClaudeCodeHookServer()
    private var pruneTask: Task<Void, Never>?
    private var mayInterruptMedia = true

    public init() {}

    public func start(mayInterruptMedia: Bool) {
        self.mayInterruptMedia = mayInterruptMedia
        guard !isRunning else {
            publish()
            return
        }
        isRunning = true
        server.start { [weak self] data in
            Task { @MainActor [weak self] in
                self?.receiveHookData(data)
            }
        }
        pruneTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                self?.pruneExpiredSessions()
            }
        }
        publish()
    }

    public func stop() {
        isRunning = false
        pruneTask?.cancel()
        pruneTask = nil
        server.stop()
        sessions = []
        snapshot = nil
        onSnapshotChange?(nil)
    }

    public func session(for id: String) -> ClaudeCodeSession? {
        sessions.first { $0.id == id }
    }

    /// Removes a session from the focused Claude surface until Claude emits a
    /// subsequent hook event for it. This is presentation state only: it does
    /// not delete Claude's local transcript or alter Claude Code itself.
    public func dismiss(sessionID: String) {
        // A pending PermissionRequest is a live decision the hook process is
        // waiting on. Removing the row without answering it would strand the
        // request until the reporter's timeout and hide Allow/Deny, so dismiss
        // resolves it as a denial first.
        if let index = sessions.firstIndex(where: { $0.id == sessionID }),
           sessions[index].permission != nil {
            server.respond(sessionID: sessionID, decision: "deny", reason: "Dismissed")
        }
        let previousCount = sessions.count
        sessions.removeAll { $0.id == sessionID }
        guard sessions.count != previousCount else { return }
        publish()
    }

    public func approve(sessionID: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
              sessions[index].permission != nil else { return }
        server.respond(sessionID: sessionID, decision: "allow", reason: nil)
        sessions[index].permission = nil
        sessions[index].phase = .working
        sessions[index].detail = "Permission approved"
        sessions[index].updatedAt = Date()
        publish()
    }

    public func deny(sessionID: String, reason: String? = nil) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
              sessions[index].permission != nil else { return }
        let boundedReason = ClaudeCodeHookPolicy.bounded(reason, maximum: 180)
        server.respond(
            sessionID: sessionID,
            decision: "deny",
            reason: boundedReason ?? "Denied by user via NotchShot"
        )
        sessions[index].permission = nil
        sessions[index].phase = .failed
        sessions[index].detail = boundedReason ?? "Permission denied"
        sessions[index].updatedAt = Date()
        publish()
    }

    private func receiveHookData(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawID = object["session_id"] as? String else { return }
        let id = AIActivityPolicy.safeIdentifier(rawID)
        guard !id.isEmpty else { return }

        let event = (object["hook_event_name"] as? String)
            ?? (object["event"] as? String)
            ?? "activity"
        let status = object["status"] as? String
        let notificationType = object["notification_type"] as? String
        let tool = ClaudeCodeHookPolicy.bounded(
            (object["tool_name"] as? String) ?? (object["tool"] as? String),
            maximum: 80
        )
        let prompt = ClaudeCodeHookPolicy.bounded(object["prompt"] as? String, maximum: 160)
        let cwd = ClaudeCodeHookPolicy.bounded(object["cwd"] as? String, maximum: 240) ?? ""
        let message = ClaudeCodeHookPolicy.bounded(object["message"] as? String, maximum: 180)
        let phase = ClaudeCodeHookPolicy.phase(
            event: event,
            status: status,
            notificationType: notificationType
        )
        let now = Date()
        let pid = (object["pid"] as? NSNumber)?.intValue
        let tty = ClaudeCodeHookPolicy.bounded(object["tty"] as? String, maximum: 80)

        var session = sessions.first(where: { $0.id == id })
            ?? ClaudeCodeSession(
                id: id,
                cwd: cwd,
                pid: pid,
                tty: tty,
                phase: phase,
                title: prompt ?? "Claude Code session",
                startedAt: now,
                updatedAt: now
            )
        if !cwd.isEmpty { session.cwd = cwd }
        if let pid { session.pid = pid }
        if let tty { session.tty = tty }
        if let prompt { session.title = prompt }
        session.phase = phase
        session.lastTool = tool ?? session.lastTool
        session.detail = ClaudeCodeHookPolicy.detail(
            event: event,
            phase: phase,
            tool: tool,
            notificationType: notificationType,
            message: message
        )
        session.updatedAt = now

        let normalizedEvent = ClaudeCodeHookPolicy.normalized(event)
        if normalizedEvent.contains("permissionrequest") {
            session.permission = ClaudeCodePermissionRequest(
                toolName: tool ?? "Claude Code tool",
                detail: message
            )
        } else if normalizedEvent.contains("posttooluse")
                    || normalizedEvent.contains("permissiondenied")
                    || normalizedEvent == "stop"
                    || normalizedEvent.contains("sessionend") {
            session.permission = nil
        }

        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        sessions.sort { lhs, rhs in
            if lhs.phase.isTerminal != rhs.phase.isTerminal {
                return !lhs.phase.isTerminal
            }
            if (lhs.permission != nil) != (rhs.permission != nil) {
                return lhs.permission != nil
            }
            return lhs.updatedAt > rhs.updatedAt
        }
        publish()
    }

    private func pruneExpiredSessions(now: Date = Date()) {
        let oldCount = sessions.count
        sessions.removeAll { session in
            let lifetime = session.phase.isTerminal
                ? AIActivityPolicy.terminalLifetime
                : AIActivityPolicy.activeLifetime
            return session.updatedAt.addingTimeInterval(lifetime) <= now
        }
        if oldCount != sessions.count { publish() }
    }

    private func publish() {
        let newSnapshot = AIActivityPolicy.contextSnapshot(
            from: sessions.map(\.aiActivity),
            mayInterruptMedia: mayInterruptMedia
        )
        guard snapshot != newSnapshot else { return }
        snapshot = newSnapshot
        onSnapshotChange?(newSnapshot)
    }
}
