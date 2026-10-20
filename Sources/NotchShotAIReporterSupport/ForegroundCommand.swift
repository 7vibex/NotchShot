import Darwin
import Foundation

/// Runs a wrapped command the way the shell would have run it, for
/// `notchshot-cli activity run` and `notchshot-ai run`.
///
/// Foundation's `Process` starts each child in a process group of its own,
/// which the terminal treats as a background job. The command was stopped as
/// soon as it read the terminal (a password prompt, or ffmpeg's keyboard
/// controls), and Ctrl-C reached only the wrapper, which died without its
/// final report while the command kept running unseen. Here the command stays
/// in the caller's process group, so it is still the terminal's foreground
/// job, and it starts with the signal handling the caller had.
public enum ForegroundCommand {
    public enum Outcome: Equatable, Sendable {
        case exited(Int32)
        case signaled(Int32)

        /// What a shell reports: the exit status, or 128 plus the signal.
        public var shellStatus: Int32 {
            switch self {
            case .exited(let status): status
            case .signaled(let signal): 128 + signal
            }
        }
    }

    /// Runs `arguments` through `/usr/bin/env`, which finds the command on
    /// `PATH`, and waits for it to end.
    ///
    /// Meanwhile this process ignores the terminal's interrupt, quit and
    /// hangup, which reach the command directly, so it outlives the command
    /// and can report how it ended. A terminate sent to this process is
    /// passed on to the command. Signal handling is process-wide, so run one
    /// command at a time.
    public static func run(_ arguments: [String], currentDirectory: String? = nil) throws -> Outcome {
        // Watched before it is ignored, so no terminate falls in between.
        let forwarding = TerminateForwarding()
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        terminate.setEventHandler { forwarding.terminate() }
        terminate.resume()
        defer { terminate.cancel() }

        // Ignored before the spawn and reset in the spawn itself, so there is
        // no moment where Ctrl-C ends only this process. A signal the caller
        // already ignored (under `nohup`, say) stays ignored for the command.
        var previous: [(signal: Int32, action: sigaction)] = []
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGINT, SIGQUIT, SIGHUP, SIGTERM] {
            var ignore = sigaction()
            ignore.__sigaction_u.__sa_handler = SIG_IGN
            var old = sigaction()
            sigaction(signal, &ignore, &old)
            previous.append((signal, old))
            if !isIgnored(old) { sigaddset(&defaults, signal) }
        }
        defer {
            for (signal, action) in previous {
                var action = action
                sigaction(signal, &action, nil)
            }
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        // Nothing blocked: a dispatch thread blocks most signals, and a command
        // spawned from one would never see Ctrl-C.
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        posix_spawnattr_setsigmask(&attributes, &unblocked)
        // Like `Process`, only the standard streams are handed on.
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT)
        )

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor: Int32 in 0 ... 2 {
            posix_spawn_file_actions_addinherit_np(&actions, descriptor)
        }
        if let currentDirectory {
            posix_spawn_file_actions_addchdir(&actions, currentDirectory)
        }

        let argv = (["/usr/bin/env"] + arguments).map { strdup($0) } + [nil]
        let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + environment).forEach { free($0) } }
        var pid = pid_t()
        let spawned = posix_spawn(&pid, "/usr/bin/env", &actions, &attributes, argv, environment)
        guard spawned == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: spawned) ?? .EIO)
        }
        forwarding.started(pid)
        defer { forwarding.finished() }

        // Waited for without reaping first: until it is reaped, its process
        // ID cannot be reused, so a terminate never reaches another process.
        var information = siginfo_t()
        while waitid(P_PID, id_t(pid), &information, WEXITED | WNOWAIT) == -1 {
            guard errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECHILD) }
        }
        forwarding.finished()
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            guard errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECHILD) }
        }
        // <sys/wait.h>'s WIFEXITED/WTERMSIG are macros Swift does not import.
        let signal = status & 0x7f
        return signal == 0 ? .exited((status >> 8) & 0xff) : .signaled(signal)
    }

    private static func isIgnored(_ action: sigaction) -> Bool {
        guard let handler = action.__sigaction_u.__sa_handler else { return false }
        return unsafeBitCast(handler, to: Int.self) == unsafeBitCast(SIG_IGN, to: Int.self)
    }
}

/// Passes a terminate on to the command once it exists, and not once it has
/// ended.
private final class TerminateForwarding: @unchecked Sendable {
    private let lock = NSLock()
    private var child: pid_t = 0
    private var pending = false

    func terminate() {
        lock.withLock {
            if child > 0 { kill(child, SIGTERM) } else { pending = true }
        }
    }

    func started(_ pid: pid_t) {
        lock.withLock {
            child = pid
            if pending { kill(pid, SIGTERM) }
        }
    }

    func finished() {
        lock.withLock { child = -1 }
    }
}
