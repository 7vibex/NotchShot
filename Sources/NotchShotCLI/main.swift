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
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else { throw CLIError.usage("Unexpected argument: \(argument)") }
            let key = String(argument.dropFirst(2))
            let next = arguments.index(after: index)
            guard next < arguments.endIndex, !arguments[next].hasPrefix("--") else {
                throw CLIError.usage("Missing value for --\(key)")
            }
            values[key] = arguments[next]
            index = arguments.index(after: next)
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
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CLIError.unreachable("socket() failed") }
        defer { close(descriptor) }
        var noSigPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let path = LiveActivitySocket.path
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw CLIError.unreachable("socket path too long")
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
            throw CLIError.unreachable("open NotchShot and enable Live Activities in Settings")
        }
        // Never hand activity data to a listener owned by another account.
        guard LiveActivitySocket.isTrustedPeer(descriptor) else {
            throw CLIError.unreachable("the socket is not owned by the current user")
        }

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
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = command
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        report(.fail, state: "Could not start")
        throw error
    }
    let succeeded = process.terminationReason == .exit && process.terminationStatus == 0
    options.values["progress"] = nil
    report(succeeded ? .finish : .fail, state: succeeded ? "Done" : "Exit \(process.terminationStatus)")
    return succeeded ? 0 : (process.terminationStatus == 0 ? EXIT_FAILURE : process.terminationStatus)
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
