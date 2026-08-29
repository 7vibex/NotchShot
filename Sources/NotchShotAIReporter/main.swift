import Darwin
import Foundation
import NotchShotAIReporterSupport

private enum Source: String, Codable {
    case claude
    case codex
    case cursor
    case terminal
}

private enum ActivityState: String, Codable {
    case working
    case waiting
    case finished
    case failed
}

private enum StepState: String, Codable {
    case pending
    case working
    case completed
    case failed
}

private struct Step: Codable {
    var id: String
    var label: String
    var state: StepState
}

private struct Activity: Codable {
    var id: String
    var source: Source
    var state: ActivityState
    var title: String
    var detail: String?
    var progress: Double?
    var workspace: String?
    var steps: [Step]
    var startedAt: Date?
    var updatedAt: Date
}

private enum ReporterError: LocalizedError {
    case usage(String)
    case unsafeDirectory

    var errorDescription: String? {
        switch self {
        case .usage(let message): message
        case .unsafeDirectory: "NotchShot's AI Activity directory is not a safe regular directory."
        }
    }
}

private struct Options {
    var values: [String: [String]] = [:]

    init(_ arguments: ArraySlice<String>) throws {
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else {
                throw ReporterError.usage("Unexpected argument: \(argument)")
            }
            let key = String(argument.dropFirst(2))
            let next = arguments.index(after: index)
            guard next < arguments.endIndex, !arguments[next].hasPrefix("--") else {
                throw ReporterError.usage("Missing value for --\(key)")
            }
            values[key, default: []].append(arguments[next])
            index = arguments.index(after: next)
        }
    }

    func value(_ key: String) -> String? { values[key]?.last }
    func all(_ key: String) -> [String] { values[key] ?? [] }
    func required(_ key: String) throws -> String {
        guard let value = value(key), !value.isEmpty else {
            throw ReporterError.usage("Missing --\(key)")
        }
        return value
    }
}

private enum Reporter {
    static let help = """
    notchshot-ai — local Claude, Codex, and Cursor activity reporter

      notchshot-ai update --source codex --state working --title "Fixing export" [options]
      notchshot-ai hook --source claude [--event Stop]     # reads hook JSON on stdin
      notchshot-ai run --title "Build" -- swift build      # wraps any command
      notchshot-ai clear --source cursor [--id session-id]
      notchshot-ai path

    update options:
      --id ID                 Stable task/session identifier (default: current)
      --detail TEXT           Short current action
      --progress 0...100      Explicit percent; omitted means indeterminate
      --workspace NAME        Optional project label
      --step STATE:LABEL      Repeatable; pending, working, completed, or failed

    Hook mode intentionally extracts only lifecycle labels, prompt titles, tool
    names, and a workspace name. It does not copy transcripts or tool contents.
    """

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("NotchShot", isDirectory: true)
            .appendingPathComponent("AI Activity", isDirectory: true)
    }

    static func run(_ arguments: [String]) throws {
        guard let command = arguments.first else {
            print(help)
            return
        }
        switch command {
        case "help", "--help", "-h":
            print(help)
        case "path":
            print(directory.path)
        case "update":
            try update(Options(arguments.dropFirst()))
        case "hook":
            try hook(Options(arguments.dropFirst()))
            // A neutral JSON response is accepted by hook runners that parse stdout.
            print("{}")
        case "clear":
            try clear(Options(arguments.dropFirst()))
        case "run":
            try runCommand(Array(arguments.dropFirst()))
        default:
            throw ReporterError.usage("Unknown command: \(command)\n\n\(help)")
        }
    }

    private static func update(_ options: Options) throws {
        let source = try parsedSource(options.required("source"))
        let state = try parsedState(options.required("state"))
        let identifier = safeIdentifier(options.value("id") ?? "current")
        guard !identifier.isEmpty else { throw ReporterError.usage("--id contains no safe characters") }

        let progress: Double?
        if let value = options.value("progress") {
            guard let percent = Double(value), (0 ... 100).contains(percent) else {
                throw ReporterError.usage("--progress must be a number from 0 through 100")
            }
            progress = percent / 100
        } else {
            progress = nil
        }

        let existing = try? read(source: source, identifier: identifier)
        let activity = Activity(
            id: identifier,
            source: source,
            state: state,
            title: bounded(
                CommandSecretRedactor.redactText(try options.required("title")),
                maximum: 160
            ),
            detail: boundedOptional(
                options.value("detail").map(CommandSecretRedactor.redactText),
                maximum: 240
            ),
            progress: progress,
            workspace: boundedOptional(options.value("workspace"), maximum: 120),
            steps: try options.all("step").prefix(6).enumerated().map { index, value in
                let components = value.split(separator: ":", maxSplits: 1).map(String.init)
                guard components.count == 2,
                      let state = StepState(rawValue: components[0]),
                      !bounded(components[1], maximum: 120).isEmpty else {
                    throw ReporterError.usage("--step must look like completed:Build")
                }
                return Step(
                    id: "step-\(index)",
                    label: bounded(
                        CommandSecretRedactor.redactText(components[1]),
                        maximum: 120
                    ),
                    state: state
                )
            },
            startedAt: existing?.startedAt ?? Date(),
            updatedAt: Date()
        )
        try write(activity)
        print(fileURL(source: source, identifier: identifier).path)
    }

    private static func hook(_ options: Options) throws {
        let source = try parsedSource(options.required("source"))
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let json = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
        let event = options.value("event")
            ?? firstString(in: json, keys: ["hook_event_name", "event_name", "event", "type"])
            ?? "activity"
        let identifier = safeIdentifier(
            firstString(in: json, keys: ["session_id", "conversation_id", "thread_id", "sessionId"])
                ?? "current"
        )
        let existing = try? read(source: source, identifier: identifier)
        let prompt = firstString(in: json, keys: ["prompt", "user_prompt", "userPrompt"])
        let title = boundedOptional(
            prompt.map(CommandSecretRedactor.redactText),
            maximum: 160
        )
            ?? existing?.title
            ?? defaultTitle(for: source, event: event)
        let tool = firstString(in: json, keys: ["tool_name", "toolName"])
        let detail = tool.map { "Using \(bounded($0, maximum: 80))" }
            ?? lifecycleDetail(event)
        let workspacePath = firstString(in: json, keys: ["cwd", "workspace", "project_dir"])
        let workspace = workspacePath.map {
            URL(fileURLWithPath: $0).lastPathComponent
        }.flatMap { boundedOptional($0, maximum: 120) }
            ?? existing?.workspace

        try write(Activity(
            id: identifier,
            source: source,
            state: state(for: event),
            title: title,
            detail: detail,
            progress: existing?.progress,
            workspace: workspace,
            steps: existing?.steps ?? [],
            startedAt: existing?.startedAt ?? Date(),
            updatedAt: Date()
        ))
    }

    private static func runCommand(_ arguments: [String]) throws {
        guard let divider = arguments.firstIndex(of: "--"), divider < arguments.index(before: arguments.endIndex) else {
            throw ReporterError.usage("run requires options followed by -- and a command")
        }
        let options = try Options(arguments[..<divider])
        let command = Array(arguments[arguments.index(after: divider)...])
        let source = try parsedSource(options.value("source") ?? "terminal")
        let identifier = safeIdentifier(options.value("id") ?? "run-\(getpid())")
        guard !identifier.isEmpty else { throw ReporterError.usage("--id contains no safe characters") }
        let title = bounded(
            CommandSecretRedactor.redactText(
                options.value("title") ?? URL(fileURLWithPath: command[0]).lastPathComponent
            ),
            maximum: 160
        )
        let workspace = options.value("workspace") ?? FileManager.default.currentDirectoryPath
        let started = Date()
        try write(Activity(
            id: identifier,
            source: source,
            state: .working,
            title: title,
            detail: "Running \(bounded(CommandSecretRedactor.redact(command).joined(separator: " "), maximum: 180))",
            progress: nil,
            workspace: URL(fileURLWithPath: workspace).lastPathComponent,
            steps: [],
            startedAt: started,
            updatedAt: started
        ))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.currentDirectoryURL = URL(fileURLWithPath: workspace, isDirectory: true)
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            try write(Activity(
                id: identifier, source: source, state: .failed, title: title,
                detail: error.localizedDescription, progress: nil,
                workspace: URL(fileURLWithPath: workspace).lastPathComponent,
                steps: [], startedAt: started, updatedAt: Date()
            ))
            throw error
        }
        let succeeded = process.terminationReason == .exit && process.terminationStatus == 0
        try write(Activity(
            id: identifier, source: source, state: succeeded ? .finished : .failed,
            title: title,
            detail: succeeded ? "Command completed" : "Command exited with status \(process.terminationStatus)",
            progress: succeeded ? 1 : nil,
            workspace: URL(fileURLWithPath: workspace).lastPathComponent,
            steps: [], startedAt: started, updatedAt: Date()
        ))
        if !succeeded { exit(process.terminationStatus == 0 ? EXIT_FAILURE : process.terminationStatus) }
    }

    private static func clear(_ options: Options) throws {
        let source = try parsedSource(options.required("source"))
        let identifier = safeIdentifier(options.value("id") ?? "current")
        guard !identifier.isEmpty else { throw ReporterError.usage("--id contains no safe characters") }
        let url = fileURL(source: source, identifier: identifier)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func write(_ activity: Activity) throws {
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(activity)
        let destination = fileURL(source: activity.source, identifier: activity.id)
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private static func read(source: Source, identifier: String) throws -> Activity {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Activity.self, from: Data(contentsOf: fileURL(
            source: source,
            identifier: identifier
        )))
    }

    private static func ensureDirectory() throws {
        let parent = directory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
           values.isSymbolicLink == true || values.isDirectory != true {
            throw ReporterError.unsafeDirectory
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ReporterError.unsafeDirectory
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private static func fileURL(source: Source, identifier: String) -> URL {
        directory.appendingPathComponent("\(source.rawValue)-\(safeIdentifier(identifier)).json")
    }

    private static func parsedSource(_ value: String) throws -> Source {
        guard let source = Source(rawValue: value.lowercased()) else {
            throw ReporterError.usage("--source must be claude, codex, cursor, or terminal")
        }
        return source
    }

    private static func parsedState(_ value: String) throws -> ActivityState {
        guard let state = ActivityState(rawValue: value.lowercased()) else {
            throw ReporterError.usage("--state must be working, waiting, finished, or failed")
        }
        return state
    }

    private static func state(for event: String) -> ActivityState {
        let normalized = event.lowercased().filter(\.isLetter)
        if normalized.contains("failure") || normalized.contains("failed") {
            return .failed
        }
        if normalized.contains("permission") || normalized.contains("notification") {
            return .waiting
        }
        if normalized == "stop"
            || normalized.contains("sessionend")
            || normalized.contains("afteragentresponse")
            || normalized.contains("agentturncomplete") {
            return .finished
        }
        return .working
    }

    private static func defaultTitle(for source: Source, event: String) -> String {
        "\(source.rawValue.capitalized) activity · \(event)"
    }

    private static func lifecycleDetail(_ event: String) -> String? {
        let normalized = event.lowercased().filter(\.isLetter)
        if normalized.contains("compact") { return "Compacting context" }
        if normalized.contains("subagentstart") { return "Starting a subagent" }
        if normalized.contains("subagentstop") { return "Subagent finished" }
        if normalized.contains("permission") { return "Waiting for permission" }
        if normalized.contains("notification") { return "Needs attention" }
        return nil
    }

    private static func firstString(in json: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = json[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func safeIdentifier(_ value: String) -> String {
        String(value.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)
        }.prefix(64))
    }

    private static func boundedOptional(_ value: String?, maximum: Int) -> String? {
        guard let value else { return nil }
        let result = bounded(value, maximum: maximum)
        return result.isEmpty ? nil : result
    }

    private static func bounded(_ value: String, maximum: Int) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximum))
    }

}

do {
    try Reporter.run(Array(CommandLine.arguments.dropFirst()))
} catch {
    fputs("notchshot-ai: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
