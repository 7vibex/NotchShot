import Foundation

public enum CrewlineConnectionError: LocalizedError, Equatable, Sendable {
    case notRunning
    case unauthorized
    case closed
    case timedOut
    case badResponse
    case server(code: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .notRunning: "Crewline isn't running."
        case .unauthorized: "Crewline no longer accepts NotchShot's pairing."
        case .closed: "The connection to Crewline closed."
        case .timedOut: "Crewline didn't answer in time."
        case .badResponse: "Crewline sent a reply NotchShot couldn't read."
        case .server(_, let message): message
        }
    }

    /// A device token Crewline has revoked or forgotten; pairing again is
    /// the only way back.
    var invalidatesCredential: Bool {
        switch self {
        case .unauthorized: true
        case .server(let code, _): code == "unauthorized" || code == "forbidden"
        default: false
        }
    }
}

/// Where a running Crewline keeps its port and root token. The desktop app
/// uses its Application Support home; the CLI and dev builds use
/// `~/.crewline` or `$CREWLINE_HOME`.
public struct CrewlineLocalHost: Sendable {
    public var homeURL: URL

    public init(homeURL: URL) { self.homeURL = homeURL }

    public static func candidates(environment: [String: String] = ProcessInfo.processInfo.environment) -> [CrewlineLocalHost] {
        var homes: [URL] = []
        if let explicit = environment["CREWLINE_HOME"], !explicit.isEmpty {
            homes.append(URL(fileURLWithPath: explicit, isDirectory: true))
        }
        let user = FileManager.default.homeDirectoryForCurrentUser
        homes.append(user.appendingPathComponent("Library/Application Support/Crewline/crewline-home", isDirectory: true))
        homes.append(user.appendingPathComponent(".crewline", isDirectory: true))
        return homes.map(CrewlineLocalHost.init)
    }

    /// The first home with a live server, judged by its `connection.json`.
    public static func running(environment: [String: String] = ProcessInfo.processInfo.environment) -> CrewlineLocalHost? {
        candidates(environment: environment).first { $0.port() != nil }
    }

    var userdata: URL { homeURL.appendingPathComponent("userdata", isDirectory: true) }

    /// The server's port. Crewline writes the file on start and removes it on
    /// quit, so its presence is the "is it running" signal the CLI uses too.
    public func port() -> Int? {
        let url = userdata.appendingPathComponent("connection.json")
        guard let data = try? Data(contentsOf: url, options: .uncached),
              data.count < 16 * 1_024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = object["wsPort"] as? NSNumber
        else { return nil }
        let port = number.intValue
        return (1...65_535).contains(port) ? port : nil
    }

    /// The root token, read only to mint a scoped device token during
    /// pairing. It is never stored or logged by NotchShot.
    func rootToken() -> String? {
        let url = userdata.appendingPathComponent("token")
        guard let data = try? Data(contentsOf: url, options: .uncached), data.count < 1_024,
              let token = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else { return nil }
        return token
    }
}

/// One authenticated socket to Crewline's local RPC server. Requests resolve
/// on their `res`/`err` frame; streams yield the raw JSON of each `next`
/// item. Payloads cross the actor as JSON `Data` so nothing non-Sendable
/// escapes it.
actor CrewlineConnection {
    private static let requestTimeout: Duration = .seconds(30)
    /// A bootstrap carries a hundred runs and two hundred issues; the
    /// default one-megabyte frame cap would truncate it.
    private static let maximumMessageBytes = 32 * 1_024 * 1_024

    private let port: Int
    private let token: String
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var streams: [String: AsyncStream<Data>.Continuation] = [:]
    private var nextID = 0
    private var onClose: (@Sendable (CrewlineConnectionError) -> Void)?

    init(port: Int, token: String, session: URLSession = .shared) {
        self.port = port
        self.token = token
        self.session = session
    }

    func open(onClose: @escaping @Sendable (CrewlineConnectionError) -> Void) {
        guard task == nil, let url = URL(string: "ws://127.0.0.1:\(port)") else { return }
        self.onClose = onClose
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = Self.maximumMessageBytes
        self.task = task
        task.resume()
        receiveLoop = Task { [weak self] in await self?.receive() }
    }

    func close() {
        finish(with: .closed, notify: false)
    }

    /// Sends `{op: "req"}` and waits for its reply's payload as JSON.
    func request(_ method: String, payload: [String: any Sendable]? = nil) async throws -> Data {
        guard let task else { throw CrewlineConnectionError.closed }
        nextID += 1
        let id = "ns-\(nextID)"
        let frame = try Self.frame(op: "req", id: id, method: method, payload: payload)

        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    Task { await self.register(id: id, continuation: continuation, frame: frame, on: task) }
                }
            }
            group.addTask {
                try await Task.sleep(for: Self.requestTimeout)
                await self.fail(id: id, with: .timedOut)
                throw CrewlineConnectionError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CrewlineConnectionError.closed }
            return result
        }
    }

    /// Opens a server stream. The returned sequence ends when the socket
    /// closes or the caller stops iterating.
    func subscribe(_ method: String, payload: [String: any Sendable]? = nil) throws -> AsyncStream<Data> {
        guard let task else { throw CrewlineConnectionError.closed }
        nextID += 1
        let id = "ns-sub-\(nextID)"
        let frame = try Self.frame(op: "sub", id: id, method: method, payload: payload)
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(32))
        streams[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        task.send(.string(frame)) { [weak self] error in
            guard error != nil else { return }
            Task { await self?.finish(with: .closed, notify: true) }
        }
        return stream
    }

    private func unsubscribe(_ id: String) {
        guard streams.removeValue(forKey: id) != nil, let task else { return }
        task.send(.string(#"{"op":"unsub","id":"\#(id)"}"#)) { _ in }
    }

    private func register(
        id: String,
        continuation: CheckedContinuation<Data, Error>,
        frame: String,
        on task: URLSessionWebSocketTask
    ) {
        guard self.task === task else {
            continuation.resume(throwing: CrewlineConnectionError.closed)
            return
        }
        pending[id] = continuation
        task.send(.string(frame)) { [weak self] error in
            guard error != nil else { return }
            Task { await self?.fail(id: id, with: .closed) }
        }
    }

    private func fail(id: String, with error: CrewlineConnectionError) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func receive() async {
        while let task {
            do {
                let message = try await task.receive()
                let data: Data? = switch message {
                case .string(let text): text.data(using: .utf8)
                case .data(let data): data
                @unknown default: nil
                }
                if let data { handle(data) }
            } catch {
                // A refused upgrade (bad token) surfaces as a 401 response.
                let status = (task.response as? HTTPURLResponse)?.statusCode
                finish(with: status == 401 || status == 403 ? .unauthorized : .closed, notify: true)
                return
            }
        }
    }

    private func handle(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String else { return }
        switch object["op"] as? String {
        case "res":
            let payload = (try? JSONSerialization.data(
                withJSONObject: object["payload"] ?? NSNull(),
                options: .fragmentsAllowed
            )) ?? Data("null".utf8)
            pending.removeValue(forKey: id)?.resume(returning: payload)
        case "err":
            let error = object["error"] as? [String: Any]
            let failure = CrewlineConnectionError.server(
                code: error?["code"] as? String ?? "error",
                message: error?["message"] as? String ?? "Crewline refused the request."
            )
            if let continuation = pending.removeValue(forKey: id) {
                continuation.resume(throwing: failure)
            } else {
                streams.removeValue(forKey: id)?.finish()
            }
        case "next":
            let item = (try? JSONSerialization.data(
                withJSONObject: object["item"] ?? NSNull(),
                options: .fragmentsAllowed
            )) ?? Data("null".utf8)
            streams[id]?.yield(item)
        case "done":
            streams.removeValue(forKey: id)?.finish()
        default:
            break
        }
    }

    private func finish(with error: CrewlineConnectionError, notify: Bool) {
        guard let task else { return }
        self.task = nil
        task.cancel(with: .normalClosure, reason: nil)
        receiveLoop?.cancel()
        receiveLoop = nil
        for continuation in pending.values { continuation.resume(throwing: error) }
        pending.removeAll()
        for continuation in streams.values { continuation.finish() }
        streams.removeAll()
        let onClose = self.onClose
        self.onClose = nil
        if notify { onClose?(error) }
    }

    static func frame(op: String, id: String, method: String, payload: [String: any Sendable]?) throws -> String {
        var object: [String: Any] = ["op": op, "id": id, "method": method]
        object["payload"] = payload.map { jsonReady($0 as [String: Any]) } ?? NSNull()
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else { throw CrewlineConnectionError.badResponse }
        return text
    }

    /// Unwraps `CrewlineSendableJSON` boxes so `JSONSerialization` sees
    /// plain dictionaries, arrays and scalars.
    static func jsonReady(_ value: Any) -> Any {
        switch value {
        case let box as CrewlineSendableJSON: jsonReady(box.value)
        case let dictionary as [String: Any]: dictionary.mapValues(jsonReady)
        case let array as [Any]: array.map(jsonReady)
        default: value
        }
    }
}

/// The two plain-HTTP endpoints beside the socket.
enum CrewlineHTTP {
    struct PairedDevice: Equatable, Sendable {
        var id: String
        var token: String
        var scopes: [String]
    }

    /// Exchanges a one-time pairing code for a scoped device token.
    static func pair(
        port: Int,
        code: String,
        deviceName: String,
        scopes: [String],
        session: URLSession = .shared
    ) async throws -> PairedDevice {
        guard let url = URL(string: "http://127.0.0.1:\(port)/remote-pair") else {
            throw CrewlineConnectionError.badResponse
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "code": code,
            "deviceName": deviceName,
            "scopes": scopes,
        ])
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            throw CrewlineConnectionError.server(
                code: object["error"] as? String ?? "pairing_failed",
                message: status == 429
                    ? "Too many pairing attempts. Try again in a minute."
                    : object["message"] as? String ?? "Crewline refused the pairing code."
            )
        }
        guard let id = object["id"] as? String, let token = object["token"] as? String, !token.isEmpty else {
            throw CrewlineConnectionError.badResponse
        }
        return PairedDevice(id: id, token: token, scopes: object["scopes"] as? [String] ?? [])
    }

    /// Uploads one file into Crewline's attachment store and returns the
    /// attachment record, ready for `runs.queueFollowUp`.
    static func upload(
        port: Int,
        token: String,
        fileURL: URL,
        mimeType: String,
        session: URLSession = .shared
    ) async throws -> [String: any Sendable] {
        guard let url = URL(string: "http://127.0.0.1:\(port)/attachments") else {
            throw CrewlineConnectionError.badResponse
        }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        let name = fileURL.lastPathComponent
        request.setValue(
            // The same escaping as JavaScript's encodeURIComponent, which the
            // server reverses with decodeURIComponent.
            name.addingPercentEncoding(
                withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))
            ) ?? "capture.png",
            forHTTPHeaderField: "x-crewline-file-name"
        )
        let (data, response) = try await session.upload(for: request, fromFile: fileURL)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 201 else {
            if status == 401 || status == 403 { throw CrewlineConnectionError.unauthorized }
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw CrewlineConnectionError.server(
                code: object?["error"] as? String ?? "upload_failed",
                message: object?["message"] as? String ?? "Crewline couldn't store the screenshot."
            )
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = object["path"] as? String,
              let storedName = object["name"] as? String
        else { throw CrewlineConnectionError.badResponse }
        var attachment: [String: any Sendable] = [
            "path": path,
            "name": storedName,
            "mimeType": object["mimeType"] as? String ?? mimeType,
            "size": (object["size"] as? NSNumber)?.intValue ?? 0,
            "kind": object["kind"] as? String ?? "image",
        ]
        if let id = object["id"] as? String { attachment["id"] = id }
        return attachment
    }
}
