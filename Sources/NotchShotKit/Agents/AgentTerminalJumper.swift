import AppKit
import Darwin
import Foundation

/// Takes the user to the terminal tab a Claude Code session runs in.
///
/// The hook reports the PID of the process that ran it. From there the jumper
/// walks up the process tree to the first ancestor that is a GUI app (the
/// terminal or editor hosting the session) and reads the session's
/// controlling TTY. Terminal and iTerm2 can then select the exact tab by TTY;
/// tmux switches to the right pane first. Every other host is brought to the
/// front, which is still the right window in the common one-window case.
enum AgentTerminalJumper {
    struct ProcessInfo: Equatable {
        var pid: pid_t
        var parent: pid_t
        var name: String
        var tty: String?
    }

    struct Target: Equatable {
        var appPID: pid_t
        var bundleIdentifier: String?
        var tty: String?
        var tmuxPane: Bool
    }

    /// Returns false when nothing could be found, so the caller can fall
    /// back to opening the agent's app.
    @MainActor
    @discardableResult
    static func jump(pid: Int?, tty: String?) -> Bool {
        guard let pid, pid > 1 else { return false }
        let chain = ancestry(of: pid_t(pid))
        var hosts: [pid_t: String] = [:]
        for process in chain {
            if let app = NSRunningApplication(processIdentifier: process.pid), app.activationPolicy == .regular {
                hosts[process.pid] = app.bundleIdentifier ?? ""
            }
        }
        guard let target = target(in: chain, hint: tty, hosts: hosts) else { return false }

        if target.tmuxPane, let paneTTY = target.tty {
            return selectTmuxPane(tty: paneTTY)
        }
        guard let app = NSRunningApplication(processIdentifier: target.appPID) else { return false }

        if let tty = target.tty, !target.tmuxPane {
            switch target.bundleIdentifier {
            case "com.apple.Terminal":
                if runScript(terminalScript(tty: tty)) { return true }
            case "com.googlecode.iterm2":
                if runScript(iTermScript(tty: tty)) { return true }
            default:
                break
            }
        }
        return app.activate()
    }

    /// Pure: picks the hosting app and TTY out of a process chain, nearest
    /// process first.
    /// `hosts` maps the PIDs in the chain that are regular GUI apps to their
    /// bundle identifier ("" when an app has none).
    static func target(
        in chain: [ProcessInfo],
        hint: String?,
        hosts: [pid_t: String]
    ) -> Target? {
        let tty = hint.flatMap(normalizedTTY) ?? chain.lazy.compactMap(\.tty).first
        let throughTmux = chain.contains { $0.name.hasPrefix("tmux") }
        for process in chain {
            if let identifier = hosts[process.pid] {
                return Target(
                    appPID: process.pid,
                    bundleIdentifier: identifier.isEmpty ? nil : identifier,
                    tty: tty,
                    tmuxPane: false
                )
            }
        }
        // A tmux server is a daemon: its ancestry ends at launchd, not at the
        // terminal. The attached client still lives in one, so hand that over.
        if throughTmux, let tty {
            return Target(appPID: 0, bundleIdentifier: nil, tty: tty, tmuxPane: true)
        }
        return nil
    }

    // MARK: Process tree

    static func ancestry(of pid: pid_t, limit: Int = 24) -> [ProcessInfo] {
        var chain: [ProcessInfo] = []
        var current = pid
        var seen = Set<pid_t>()
        while current > 1, chain.count < limit, seen.insert(current).inserted,
              let info = processInfo(current) {
            chain.append(info)
            current = info.parent
        }
        return chain
    }

    static func processInfo(_ pid: pid_t) -> ProcessInfo? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }

        let name = withUnsafePointer(to: &info.kp_proc.p_comm) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
        let device = info.kp_eproc.e_tdev
        var tty: String?
        // NODEV (-1) means no controlling terminal.
        if device != -1, let deviceName = devname(device, mode_t(S_IFCHR)) {
            let value = String(cString: deviceName)
            if value != "??" { tty = "/dev/" + value }
        }
        return ProcessInfo(pid: pid, parent: info.kp_eproc.e_ppid, name: name, tty: tty)
    }

    static func normalizedTTY(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "??", trimmed != "not a tty" else { return nil }
        return trimmed.hasPrefix("/dev/") ? trimmed : "/dev/" + trimmed
    }

    // MARK: Hosts

    /// Only the TTY reaches the script, and only after validation, so no
    /// string from a hook can change what runs.
    static func isSafeTTY(_ tty: String) -> Bool {
        tty.range(of: #"^/dev/ttys?[0-9a-z]{1,4}$"#, options: .regularExpression) != nil
    }

    /// The scripts run on the main actor. Apple events wait two minutes for
    /// a reply by default, so a terminal busy drawing a flood of output would
    /// freeze the notch that long; past this bound the jump falls back to
    /// bringing the app forward.
    static let scriptTimeoutSeconds = 3

    static func terminalScript(tty: String) -> String? {
        guard isSafeTTY(tty) else { return nil }
        return """
        with timeout of \(scriptTimeoutSeconds) seconds
            tell application id "com.apple.Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            set selected of t to true
                            set index of w to 1
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end tell
        end timeout
        return false
        """
    }

    static func iTermScript(tty: String) -> String? {
        guard isSafeTTY(tty) else { return nil }
        return """
        with timeout of \(scriptTimeoutSeconds) seconds
            tell application id "com.googlecode.iterm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                select w
                                select t
                                select s
                                activate
                                return true
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
        end timeout
        return false
        """
    }

    @MainActor
    private static func runScript(_ source: String?) -> Bool {
        guard let source, let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            Log.app.info("Terminal jump script failed: \(error[NSAppleScript.errorNumber] as? Int ?? 0)")
            return false
        }
        return result.booleanValue
    }

    // MARK: tmux

    /// Switches the attached tmux client to the pane on `tty`, then brings
    /// that client's terminal forward.
    @MainActor
    private static func selectTmuxPane(tty: String) -> Bool {
        guard isSafeTTY(tty), let tmux = tmuxPath() else { return false }
        let panes = run(tmux, ["list-panes", "-a", "-F", "#{pane_tty} #{session_name}:#{window_index}.#{pane_index}"])
        guard let target = panes?
            .split(separator: "\n")
            .first(where: { $0.hasPrefix(tty + " ") })?
            .split(separator: " ", maxSplits: 1).last
            .map(String.init)
        else { return false }
        _ = run(tmux, ["switch-client", "-t", target])
        _ = run(tmux, ["select-window", "-t", target])
        _ = run(tmux, ["select-pane", "-t", target])

        // The most recently active client is the one the user looks at.
        if let clientPID = run(tmux, ["list-clients", "-F", "#{client_activity} #{client_pid}"])?
            .split(separator: "\n")
            .sorted(by: >)
            .first?
            .split(separator: " ").last
            .flatMap({ pid_t(String($0)) }) {
            for process in ancestry(of: clientPID) {
                if let app = NSRunningApplication(processIdentifier: process.pid), app.activationPolicy == .regular {
                    return app.activate()
                }
            }
        }
        return true
    }

    private static func tmuxPath() -> String? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
