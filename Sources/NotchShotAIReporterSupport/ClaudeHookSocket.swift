import Darwin
import Foundation

/// The local socket used by the bundled AI reporter to reach NotchShot's
/// Claude Code surface. It lives under the current user's temporary directory
/// and carries the user id in its name so no other account can bind it first
/// or answer a permission request on this user's behalf.
public enum ClaudeHookSocket {
    public static let fileNamePrefix = "notchshot-claude"

    /// Per-user path, short enough for `sockaddr_un.sun_path` (103 UTF-8 bytes
    /// plus the terminating NUL). Falls back to a uid-suffixed `/tmp` name only
    /// when the user's temporary directory is unusually long; peer verification
    /// still protects that fallback.
    public static var path: String {
        let name = "\(fileNamePrefix)-\(getuid()).sock"
        let preferred = FileManager.default.temporaryDirectory
            .appendingPathComponent(name).path
        if preferred.utf8.count < 104 { return preferred }
        return "/tmp/\(name)"
    }

    /// True only when the connected socket's peer is the current user. Called
    /// by both the app (after `accept`) and the reporter (after `connect`), so
    /// neither side can be impersonated by another local account.
    public static func isTrustedPeer(_ fileDescriptor: Int32) -> Bool {
        guard fileDescriptor >= 0 else { return false }
        var peerUser = uid_t(0)
        var peerGroup = gid_t(0)
        guard getpeereid(fileDescriptor, &peerUser, &peerGroup) == 0 else { return false }
        return peerUser == getuid()
    }
}

/// A connection to one of NotchShot's owner-only local sockets, for the two
/// command-line tools.
public enum OwnerOnlySocket {
    public enum ConnectionError: Error {
        case socketUnavailable
        case pathTooLong
        case notListening
        case untrustedPeer
    }

    /// The returned descriptor belongs to the caller. A vanished app gives
    /// failed writes rather than `SIGPIPE`, and a wedged one cannot hold a
    /// write past the two-second limit once its socket buffer is full. Never
    /// connects to a listener owned by another account.
    public static func connection(
        to path: String,
        receiveTimeoutSeconds: Int? = nil
    ) throws(ConnectionError) -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw .socketUnavailable }
        var noSigPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var sendTimeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
        if let receiveTimeoutSeconds {
            var receiveTimeout = timeval(tv_sec: receiveTimeoutSeconds, tv_usec: 0)
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(descriptor)
            throw .pathTooLong
        }
        _ = path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                strcpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), source)
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(descriptor)
            throw .notListening
        }
        guard ClaudeHookSocket.isTrustedPeer(descriptor) else {
            close(descriptor)
            throw .untrustedPeer
        }
        return descriptor
    }
}
