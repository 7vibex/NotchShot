import Darwin
import Foundation

/// Runs the user's chained status line under one deadline, including input,
/// output and cleanup. A dedicated process group keeps background descendants
/// from outliving the status line or keeping an inherited pipe open forever.
public enum StatusLineCommand {
    public static let maximumOutputBytes = 16 * 1_024

    public static func run(command: String, input: Data, timeout: TimeInterval = 5) -> String {
        guard !command.utf8.contains(0) else { return "" }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0.01, min(timeout, 5))
        var incoming: [Int32] = [-1, -1]
        var outgoing: [Int32] = [-1, -1]
        defer {
            for descriptor in incoming + outgoing where descriptor >= 0 { close(descriptor) }
        }
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &incoming) == 0,
              socketpair(AF_UNIX, SOCK_STREAM, 0, &outgoing) == 0 else { return "" }

        // Socket writes can suppress SIGPIPE without changing this process's
        // signal disposition (which is shared with every other thread).
        var enabled: Int32 = 1
        guard setsockopt(incoming[0], SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0,
              fcntl(incoming[0], F_SETFL, O_NONBLOCK) == 0,
              fcntl(outgoing[0], F_SETFL, O_NONBLOCK) == 0 else { return "" }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGTERM, SIGINT, SIGQUIT, SIGHUP, SIGPIPE] { sigaddset(&defaults, signal) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)
        posix_spawnattr_setflags(&attributes, Int16(
            POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
        ))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, incoming[1], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, outgoing[1], STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        let words: [String] = ["/bin/sh", "-c", command]
        let arguments = words.map { strdup($0) } + [nil]
        let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (arguments + environment).forEach { free($0) } }
        var pid = pid_t()
        guard posix_spawn(&pid, "/bin/sh", &actions, &attributes, arguments, environment) == 0 else { return "" }
        close(incoming[1]); incoming[1] = -1
        close(outgoing[1]); outgoing[1] = -1

        // Keep the leader unreaped until the group has been retired, so its
        // PID cannot be reused while cleanup still sends group signals.
        defer {
            kill(-pid, SIGTERM)
            usleep(50_000)
            kill(-pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        }
        var output = Data()
        var offset = 0
        var bytes = [UInt8](repeating: 0, count: 4_096)
        while ProcessInfo.processInfo.systemUptime < deadline {
            if offset == input.count, incoming[0] >= 0 {
                close(incoming[0]); incoming[0] = -1
            }
            var descriptors = [
                pollfd(fd: incoming[0], events: Int16(POLLOUT), revents: 0),
                pollfd(fd: outgoing[0], events: Int16(POLLIN), revents: 0),
            ]
            let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
            let ready = poll(&descriptors, nfds_t(descriptors.count), Int32(min(20, remaining * 1_000)))
            if ready < 0, errno != EINTR { break }
            if incoming[0] >= 0, descriptors[0].revents != 0 {
                let written = input.withUnsafeBytes { buffer in
                    Darwin.write(incoming[0], buffer.baseAddress!.advanced(by: offset), min(16_384, input.count - offset))
                }
                if written > 0 {
                    offset += written
                } else if written < 0, errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
                    close(incoming[0]); incoming[0] = -1
                }
            }
            var reachedEOF = false
            // Limit each drain batch so a continuous producer cannot prevent
            // the outer loop from checking its deadline.
            for _ in 0 ..< 16 {
                let count = Darwin.read(outgoing[0], &bytes, bytes.count)
                if count > 0 {
                    let retained = min(count, maximumOutputBytes - output.count)
                    output.append(contentsOf: bytes.prefix(retained))
                } else {
                    reachedEOF = count == 0
                    break
                }
            }
            var information = siginfo_t()
            let waited = waitid(P_PID, id_t(pid), &information, WEXITED | WNOHANG | WNOWAIT)
            if waited == 0, information.si_pid == pid {
                // If a descendant still holds stdout, the next nonblocking
                // read already drained available bytes; it must not hold up
                // the reporter after the actual status command has finished.
                if reachedEOF || descriptors[1].revents == 0 { break }
            }
        }
        return String(data: output, encoding: .utf8)?.trimmingCharacters(in: .newlines) ?? ""
    }
}
