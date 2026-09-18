import Darwin
import Foundation
import NotchShotAIReporterSupport

/// Unix-domain socket transport for the local Live Activity API.
///
/// One message per connection: the client writes a newline-terminated JSON
/// object, the server validates it on its own queue, hands the *validated*
/// update to the main actor, and writes a one-line acknowledgement. There is no
/// streaming, no request the server initiates, and nothing a message can make
/// the server read, open, or execute.
///
/// All mutable state is confined to `queue`; the unchecked marker documents
/// that invariant for strict concurrency checking.
final class LiveActivitySocketServer: @unchecked Sendable {
    typealias Handler = @Sendable (LiveActivityUpdate) async -> LiveActivityValidationError?

    private final class Client: @unchecked Sendable {
        let fileDescriptor: Int32
        var source: DispatchSourceRead?
        var buffer = Data()
        var handled = false

        init(fileDescriptor: Int32) {
            self.fileDescriptor = fileDescriptor
        }
    }

    /// Concurrent connections beyond this are closed on accept.
    static let maximumClients = 16
    /// A client that has not sent a complete message by then is dropped.
    static let readTimeout: TimeInterval = 2

    let socketPath: String
    private let queue = DispatchQueue(label: "com.notchshot.live-activity-socket", qos: .utility)
    private var serverFileDescriptor: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [Int32: Client] = [:]
    private var handler: Handler?

    init(socketPath: String = LiveActivitySocket.path) {
        self.socketPath = socketPath
    }

    func start(handler: @escaping Handler) {
        queue.async { [weak self] in self?.startOnQueue(handler: handler) }
    }

    func stop() {
        queue.async { [weak self] in self?.stopOnQueue() }
    }

    // MARK: Queue-confined

    private func startOnQueue(handler: @escaping Handler) {
        guard serverFileDescriptor < 0 else { return }
        guard removeStaleSocketIfSafe() else {
            Log.app.error("Live Activity socket path could not be reclaimed safely")
            return
        }
        guard socketPath.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            Log.app.error("Live Activity socket path is too long")
            return
        }
        self.handler = handler

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return }
        setNonBlocking(descriptor)
        setNoSIGPIPE(descriptor)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { path in
            withUnsafeMutablePointer(to: &address.sun_path) { pathPointer in
                let buffer = UnsafeMutableRawPointer(pathPointer).assumingMemoryBound(to: CChar.self)
                strcpy(buffer, path)
            }
        }
        // No process-wide umask change here: it would race every other file
        // the app writes. The per-user temporary directory is already 0700,
        // the socket is chmodded before `listen`, and every accepted peer's
        // user id is verified.
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            close(descriptor)
            Log.app.error("Live Activity socket bind failed with errno \(code)")
            return
        }
        chmod(socketPath, 0o600)
        guard listen(descriptor, 16) == 0 else {
            close(descriptor)
            unlink(socketPath)
            return
        }
        serverFileDescriptor = descriptor

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnections() }
        acceptSource = source
        source.resume()
    }

    private func stopOnQueue() {
        acceptSource?.cancel()
        acceptSource = nil
        if serverFileDescriptor >= 0 {
            close(serverFileDescriptor)
            serverFileDescriptor = -1
        }
        for fileDescriptor in Array(clients.keys) { closeClient(fileDescriptor) }
        handler = nil
        _ = removeStaleSocketIfSafe()
    }

    private func acceptConnections() {
        guard serverFileDescriptor >= 0 else { return }
        while true {
            let clientFileDescriptor = accept(serverFileDescriptor, nil, nil)
            guard clientFileDescriptor >= 0 else { return }
            setNonBlocking(clientFileDescriptor)
            setNoSIGPIPE(clientFileDescriptor)
            guard LiveActivitySocket.isTrustedPeer(clientFileDescriptor) else {
                Log.app.error("Rejected a Live Activity connection from another user")
                close(clientFileDescriptor)
                continue
            }
            guard clients.count < Self.maximumClients else {
                close(clientFileDescriptor)
                continue
            }
            let client = Client(fileDescriptor: clientFileDescriptor)
            clients[clientFileDescriptor] = client
            let source = DispatchSource.makeReadSource(fileDescriptor: clientFileDescriptor, queue: queue)
            source.setEventHandler { [weak self, weak client] in
                guard let self, let client else { return }
                self.read(client)
            }
            client.source = source
            source.resume()
            queue.asyncAfter(deadline: .now() + Self.readTimeout) { [weak self, weak client] in
                guard let self, let client, !client.handled,
                      self.clients[client.fileDescriptor] === client else { return }
                self.closeClient(client.fileDescriptor)
            }
        }
    }

    private func read(_ client: Client) {
        var bytes = [UInt8](repeating: 0, count: 2_048)
        let count = Darwin.read(client.fileDescriptor, &bytes, bytes.count)
        if count > 0 {
            guard !client.handled else { return }
            client.buffer.append(contentsOf: bytes.prefix(count))
            if let newline = client.buffer.firstIndex(of: 10) {
                let message = Data(client.buffer[..<newline])
                client.handled = true
                handle(message, from: client)
            } else if client.buffer.count > LiveActivitySanitizer.maximumMessageBytes {
                client.handled = true
                respond(.init("message too large"), to: client)
            }
        } else if count == 0 {
            if !client.handled, !client.buffer.isEmpty {
                client.handled = true
                handle(client.buffer, from: client)
            } else if !client.handled {
                closeClient(client.fileDescriptor)
            }
        } else if errno != EAGAIN && errno != EWOULDBLOCK {
            closeClient(client.fileDescriptor)
        }
    }

    private func handle(_ message: Data, from client: Client) {
        switch LiveActivitySanitizer.decode(message) {
        case .failure(let error):
            respond(error, to: client)
        case .success(let update):
            guard let handler else {
                respond(.init("live activities are disabled"), to: client)
                return
            }
            let fileDescriptor = client.fileDescriptor
            let queue = self.queue
            Task { [weak self] in
                let error = await handler(update)
                queue.async { [weak self] in
                    guard let self, let client = self.clients[fileDescriptor] else { return }
                    self.respond(error, to: client)
                }
            }
        }
    }

    private func respond(_ error: LiveActivityValidationError?, to client: Client) {
        let data = LiveActivitySanitizer.acknowledgement(error: error)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = Darwin.write(client.fileDescriptor, base, raw.count)
        }
        closeClient(client.fileDescriptor)
    }

    private func closeClient(_ fileDescriptor: Int32) {
        guard let client = clients.removeValue(forKey: fileDescriptor) else { return }
        client.source?.cancel()
        close(fileDescriptor)
    }

    private func setNonBlocking(_ fileDescriptor: Int32) {
        let flags = fcntl(fileDescriptor, F_GETFL)
        if flags >= 0 { _ = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) }
    }

    private func setNoSIGPIPE(_ fileDescriptor: Int32) {
        var value: Int32 = 1
        _ = setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Unlinks only a socket. A regular file or symlink planted at the path is
    /// left alone and the server refuses to start.
    private func removeStaleSocketIfSafe() -> Bool {
        var information = stat()
        guard lstat(socketPath, &information) == 0 else { return errno == ENOENT }
        guard (information.st_mode & S_IFMT) == S_IFSOCK else { return false }
        guard information.st_uid == getuid() else { return false }
        return unlink(socketPath) == 0
    }
}
