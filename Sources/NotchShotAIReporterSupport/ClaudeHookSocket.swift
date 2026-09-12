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
