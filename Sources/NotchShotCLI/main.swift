import Darwin
import Foundation
import NotchShotAIReporterSupport

// `notchshot-cli activity …` publishes Live Activities to a running NotchShot
// over its per-user, owner-only Unix socket. It never asks the app to run,
// open, or read anything: the only payload is the bounded message defined in
// `LiveActivityProtocol.swift`, and the app validates it again on arrival.

private enum CLIError: LocalizedError {
    case usage(String)
    case unreachable(String)
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message): message
        case .unreachable(let message): "NotchShot is not reachable: \(message)"
        case .rejected(let message): "NotchShot rejected the activity: \(message)"
        }
    }

    var exitCode: Int32 {
        switch self {
        case .usage: 2
        case .rejected: 1
        case .unreachable: 3
        }
    }
}

private struct Options {
    var values: [String: String] = [:]

    init(_ arguments: ArraySlice<String>) throws {
        do throws(LongOptions.Failure) {
            for (key, value) in try LongOptions.parse(arguments) { values[key] = value }
        } catch {
            throw CLIError.usage(error.message)
        }
        let known: Set<String> = [
            "id", "source", "title", "subtitle", "state", "progress", "current", "total",
            "unit", "eta", "icon", "accent", "urgency", "expires",
        ]
        if let unknown = values.keys.first(where: { !known.contains($0) }) {
            throw CLIError.usage("Unknown option --\(unknown)")
        }
    }

    func double(_ key: String) throws -> Double? {
        guard let raw = values[key] else { return nil }
        guard let value = Double(raw), value.isFinite else { throw CLIError.usage("--\(key) must be a number") }
        return value
    }

    func message(command: LiveActivityCommand) throws -> LiveActivityMessage {
        guard let id = values["id"] else { throw CLIError.usage("--id is required") }
        var message = LiveActivityMessage(command: command, id: id)
        message.source = values["source"]
        message.title = values["title"]
        message.subtitle = values["subtitle"]
        message.state = values["state"]
        // Percent on the command line, matching `notchshot-ai --progress 60`.
        if let percent = try double("progress") {
            guard (0 ... 100).contains(percent) else { throw CLIError.usage("--progress must be 0-100") }
            message.progress = percent / 100
        }
        message.current = try double("current")
        message.total = try double("total")
        message.unit = values["unit"]
        message.etaSeconds = try double("eta")
        message.icon = values["icon"]
        message.accent = values["accent"]
        message.urgency = values["urgency"]
        message.expiresInSeconds = try double("expires")
        // Validate locally first so mistakes get a precise message even when
        // the app is not running.
        if case .failure(let error) = LiveActivitySanitizer.validate(message) {
            throw CLIError.usage(error.reason)
        }
        return message
    }
}

private enum Client {
    static func send(_ message: LiveActivityMessage) throws {
        let data = try JSONEncoder().encode(message) + Data([10])
        guard data.count <= LiveActivitySanitizer.maximumMessageBytes else {
            throw CLIError.usage("message too large")
        }
        let descriptor: Int32
        do throws(OwnerOnlySocket.ConnectionError) {
            descriptor = try OwnerOnlySocket.connection(to: LiveActivitySocket.path, receiveTimeoutSeconds: 2)
        } catch {
            switch error {
            case .socketUnavailable: throw CLIError.unreachable("socket() failed")
            case .pathTooLong: throw CLIError.unreachable("socket path too long")
            case .notListening: throw CLIError.unreachable("open NotchShot and enable Live Activities in Settings")
            case .untrustedPeer: throw CLIError.unreachable("the socket is not owned by the current user")
            }
        }
        defer { close(descriptor) }

        let written = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        guard written == data.count else { throw CLIError.unreachable("write failed") }
        shutdown(descriptor, SHUT_WR)

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        while response.count < 1_024 {
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            response.append(contentsOf: buffer.prefix(count))
            if response.contains(10) { break }
        }
        guard let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              let ok = object["ok"] as? Bool else {
            throw CLIError.unreachable("no acknowledgement")
        }
        if !ok { throw CLIError.rejected(object["error"] as? String ?? "unknown error") }
    }
}

private func usage() -> String {
    """
    Usage:
      notchshot-cli activity start   --id ID --title TITLE [options]
      notchshot-cli activity update  --id ID [options]
      notchshot-cli activity finish  --id ID [options]
      notchshot-cli activity fail    --id ID [options]
      notchshot-cli activity dismiss --id ID
      notchshot-cli activity run     --id ID [--title TITLE] [options] -- COMMAND [ARGS…]
      notchshot-cli activity icons

    Options:
      --source NAME        Short source label, e.g. "Xcode"
      --subtitle TEXT      Secondary line
      --state TEXT         Short state word, e.g. "Linking"
      --progress PERCENT   0-100. Omit when you have no measured progress.
      --current N --total N [--unit bytes|items|count]
      --eta SECONDS        Only when you measured it
      --icon NAME          One of: \(LiveActivityIcon.allCases.map(\.rawValue).joined(separator: ", "))
      --accent NAME        One of: \(LiveActivityAccent.allCases.map(\.rawValue).joined(separator: ", "))
      --urgency LEVEL      passive | normal | important
      --expires SECONDS    Remove automatically after this long

    IDs use A-Z a-z 0-9 . _ : - (max 64). Text is bounded and shown as plain text.
    Exit status: 0 accepted, 1 rejected, 2 usage error, 3 NotchShot not reachable.
    `run` preserves the wrapped command's exit status.
    """
}

/// Runs a command the user typed in their own shell and reports its start and
/// outcome. The app is only told about it; the app never runs anything.
private func run(_ arguments: ArraySlice<String>) throws -> Int32 {
    guard let divider = arguments.firstIndex(of: "--"), divider < arguments.endIndex - 1 else {
        throw CLIError.usage("run requires options, then --, then a command")
    }
    var options = try Options(arguments[..<divider])
    let command = Array(arguments[(divider + 1)...])
    if options.values["title"] == nil {
        options.values["title"] = URL(fileURLWithPath: command[0]).lastPathComponent
    }
    if options.values["icon"] == nil { options.values["icon"] = LiveActivityIcon.terminal.rawValue }

    // Reporting is best effort: an unreachable app must never stop the build.
    func report(_ command: LiveActivityCommand, state: String? = nil) {
        do {
            var message = try options.message(command: command)
            if let state { message.state = state }
            try Client.send(message)
        } catch {
            FileHandle.standardError.write(Data("notchshot-cli: \(error.localizedDescription)\n".utf8))
        }
    }

    report(.start, state: "Running")
    // A long-running command must not age out of the island while it is still
    // working. The heartbeat repeats the same fields as the start report — it
    // never invents progress or an ETA — and a missing app is ignored so the
    // user's command is unaffected. It is stopped synchronously when the child
    // exits, before the terminal report.
    let heartbeatOptions = options
    let heartbeat = ActivityHeartbeat()
    heartbeat.start {
        guard let message = try? heartbeatOptions.message(command: .update) else { return }
        try? Client.send(message)
    }
    let outcome: ForegroundCommand.Outcome
    do {
        outcome = try ForegroundCommand.run(command)
    } catch {
        heartbeat.stop()
        report(.fail, state: "Could not start")
        throw error
    }
    heartbeat.stop()
    options.values["progress"] = nil
    switch outcome {
    case .exited(0): report(.finish, state: "Done")
    case .exited(let status): report(.fail, state: "Exit \(status)")
    case .signaled(SIGINT): report(.fail, state: "Interrupted")
    case .signaled(let signal): report(.fail, state: "Signal \(signal)")
    }
    return outcome.shellStatus
}

private func main() -> Int32 {
    var arguments = CommandLine.arguments.dropFirst()
    guard arguments.first == "activity" else {
        print(usage())
        return arguments.isEmpty || arguments.first == "--help" || arguments.first == "help" ? 0 : 2
    }
    arguments = arguments.dropFirst()
    guard let subcommand = arguments.first else {
        print(usage())
        return 2
    }
    let rest = arguments.dropFirst()
    do {
        switch subcommand {
        case "icons":
            LiveActivityIcon.allCases.forEach { print($0.rawValue) }
            return 0
        case "run":
            return try run(rest)
        default:
            guard let command = LiveActivityCommand(rawValue: subcommand) else {
                throw CLIError.usage("Unknown subcommand: \(subcommand)\n\n\(usage())")
            }
            try Client.send(try Options(rest).message(command: command))
            return 0
        }
    } catch let error as CLIError {
        FileHandle.standardError.write(Data("notchshot-cli: \(error.localizedDescription)\n".utf8))
        return error.exitCode
    } catch {
        FileHandle.standardError.write(Data("notchshot-cli: \(error.localizedDescription)\n".utf8))
        return 1
    }
}

exit(main())
