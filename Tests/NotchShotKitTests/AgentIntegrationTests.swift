import Foundation
import Testing
@testable import NotchShotAIReporterSupport
@testable import NotchShotKit

/// Pins the Crewline and Claude integration: question parsing and answer
/// encoding, the AskUserQuestion round trip, usage rings, and the terminal
/// jump's process-tree choice.
@Suite("Agent integration")
struct AgentIntegrationTests {
    // MARK: Crewline questions

    @Test func normalizedSelectQuestionAnswersWithItsValue() throws {
        let form = CrewlineParser.questionForm(from: [
            "question": "Pick a database",
            "normalizedQuestion": [
                "kind": "select",
                "prompt": "Which database?",
                "options": [["value": "pg", "label": "Postgres"], ["value": "sqlite", "label": "SQLite", "hint": "local"]],
            ],
        ])
        #expect(form.encoding == .crewlineNormalized)
        #expect(form.questions.count == 1)
        #expect(form.questions[0].options.map(\.label) == ["Postgres", "SQLite"])
        #expect(form.questions[0].options[1].hint == "local")
        #expect(form.sendsOnFirstChoice)
        let payload = try #require(AgentAnswerEncoder.encode(AgentQuestionAnswers(single: [0: "sqlite"]), for: form))
        #expect(payload == ["answer": .string("sqlite")])
    }

    @Test func normalizedConfirmAnswersWithABoolean() throws {
        let form = CrewlineParser.questionForm(from: [
            "question": "Continue?",
            "normalizedQuestion": ["kind": "confirm", "prompt": "Continue?"],
        ])
        #expect(form.questions[0].choices.map(\.value) == ["yes", "no"])
        let payload = try #require(AgentAnswerEncoder.encode(AgentQuestionAnswers(single: [0: "no"]), for: form))
        #expect(payload == ["answer": .bool(false)])
    }

    @Test func normalizedTextKeepsTheIndexedShape() throws {
        let form = CrewlineParser.questionForm(from: [
            "question": "Name it",
            "normalizedQuestion": ["kind": "text", "prompt": "What name?", "placeholder": "my-app"],
        ])
        #expect(form.encoding == .crewlineIndexed)
        #expect(form.questions[0].placeholder == "my-app")
        #expect(!form.sendsOnFirstChoice)
        #expect(AgentAnswerEncoder.encode(AgentQuestionAnswers(single: [0: "  "]), for: form) == nil)
        let payload = try #require(AgentAnswerEncoder.encode(AgentQuestionAnswers(single: [0: " notch "]), for: form))
        #expect(payload == ["0": .string("notch")])
    }

    @Test func nativeMultiQuestionFormAnswersByIndexInOfferedOrder() throws {
        let form = CrewlineParser.questionForm(from: [
            "question": "Setup",
            "detail": [
                ["header": "Lang", "question": "Language?", "options": [["label": "Swift"], ["label": "Rust"]]],
                ["question": "Extras?", "multiSelect": true,
                 "options": [["label": "Tests"], ["label": "CI"], ["label": "Docs"]]],
            ],
            // Ignored: more than one question.
            "normalizedQuestion": ["kind": "select", "prompt": "x", "options": []],
        ])
        #expect(form.encoding == .crewlineIndexed)
        #expect(form.questions.map(\.kind) == [.select, .multiSelect])
        #expect(form.questions[0].header == "Lang")
        #expect(form.questions[1].header == "Question 2")
        let answers = AgentQuestionAnswers(single: [0: "Rust"], multiple: [1: ["Docs", "Tests"]])
        let payload = try #require(AgentAnswerEncoder.encode(answers, for: form))
        #expect(payload == ["0": .string("Rust"), "1": .strings(["Tests", "Docs"])])
        #expect(AgentAnswerEncoder.encode(AgentQuestionAnswers(single: [0: "Rust"]), for: form) == nil)
    }

    @Test func pendingQuestionIsTheLatestUnresolvedRequest() throws {
        func row(_ type: String, _ body: [String: Any], seq: Int) -> [String: Any] {
            let data = try! JSONSerialization.data(withJSONObject: body)
            return ["type": type, "payload": String(data: data, encoding: .utf8)!, "seq": seq, "ts": "2026-10-19T10:00:0\(seq)Z"]
        }
        let resolved: [String: Any] = ["events": [
            row("input.requested", ["requestId": "r1", "question": "First?"], seq: 1),
            row("input.resolved", ["requestId": "r1"], seq: 2),
        ]]
        #expect(CrewlineParser.pendingQuestion(inRunEvents: resolved, runID: "run-1") == nil)

        let open: [String: Any] = ["events": [
            row("input.requested", ["requestId": "r1", "question": "First?"], seq: 1),
            row("input.resolved", ["requestId": "r1"], seq: 2),
            row("tool.started", ["tool": "Bash"], seq: 3),
            row("input.requested", ["requestId": "r2", "question": "Second?"], seq: 4),
        ]]
        let interaction = try #require(CrewlineParser.pendingQuestion(inRunEvents: open, runID: "run-1"))
        #expect(interaction.id == "r2")
        #expect(interaction.source == .crewline)
        #expect(interaction.activityKey == CrewlineParser.activityKey(runID: "run-1"))
        #expect(interaction.isQuestion)
    }

    @Test func usageAccountsSkipDisabledAndSplitWindows() throws {
        let accounts = CrewlineParser.usageAccounts(from: [
            "accounts": [
                ["provider": "codex", "label": "Codex", "status": "ready", "sourceId": "s", "accountId": "a",
                 "windows": [
                    ["id": "p", "label": "5h", "usedPercent": 42, "windowDurationMins": 300, "resetsAt": 1_800_000_000],
                    ["id": "w", "label": "week", "usedPercent": 140, "windowDurationMins": 10_080],
                 ]],
                ["provider": "claude", "disabled": true, "windows": [["usedPercent": 10]]],
                ["provider": "gemini", "windows": []],
            ],
        ])
        #expect(accounts.count == 1)
        let codex = try #require(accounts.first)
        #expect(codex.id == "s/a")
        #expect(!codex.isStale)
        #expect(codex.fiveHour?.usedPercent == 42)
        #expect(codex.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(codex.weekly?.usedPercent == 100)

        let groups = AgentUsagePolicy.crewlineGroups(from: accounts)
        #expect(groups.map(\.source) == [.codex])
        #expect(groups.first?.meters.map(\.kind) == [.fiveHour, .weekly])
        #expect(groups.first?.tightest?.kind == .weekly)
    }

    // MARK: Claude AskUserQuestion bridge

    nonisolated(unsafe) static let claudeToolInput: [String: Any] = [
        "questions": [
            ["question": "Which approach?", "header": "Approach", "multiSelect": false,
             "options": [["label": "Refactor", "description": "Cleaner"], ["label": "Patch"]]],
            ["question": "Also update?", "multiSelect": true,
             "options": [["label": "Docs"], ["label": "Tests"], ["label": "Changelog"]]],
        ],
    ]

    @Test func claudeQuestionsAreForwardedBounded() throws {
        let questions = try #require(ClaudeQuestionBridge.socketQuestions(fromToolInput: Self.claudeToolInput))
        #expect(questions.count == 2)
        #expect(questions[0]["header"] as? String == "Approach")
        #expect((questions[1]["options"] as? [[String: Any]])?.count == 3)
        #expect(ClaudeQuestionBridge.socketQuestions(fromToolInput: ["questions": []]) == nil)
        #expect(ClaudeQuestionBridge.socketQuestions(fromToolInput: nil) == nil)
    }

    @Test func claudeAnswerMapsIndicesBackToOriginalLabels() throws {
        let reply = Data(#"{"decision":"answer","answers":{"0":["1"],"1":["2","0"]}}"#.utf8)
        let output = try #require(ClaudeQuestionBridge.hookOutput(reply: reply, toolInput: Self.claudeToolInput))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let specific = try #require(object["hookSpecificOutput"] as? [String: Any])
        #expect(specific["permissionDecision"] as? String == "allow")
        let input = try #require(specific["updatedInput"] as? [String: Any])
        let answers = try #require(input["answers"] as? [String: String])
        #expect(answers == ["Which approach?": "Patch", "Also update?": "Changelog, Docs"])
        // The original questions travel back untouched.
        #expect((input["questions"] as? [[String: Any]])?.count == 2)
    }

    @Test func claudeAnswerDeclinesAnythingButAnAnswer() {
        let elsewhere = Data(#"{"decision":"ask"}"#.utf8)
        #expect(ClaudeQuestionBridge.hookOutput(reply: elsewhere, toolInput: Self.claudeToolInput) == nil)
        let outOfRange = Data(#"{"decision":"answer","answers":{"0":["9"],"1":["0"]}}"#.utf8)
        #expect(ClaudeQuestionBridge.hookOutput(reply: outOfRange, toolInput: Self.claudeToolInput) == nil)
    }

    @Test func claudeIndexedEncodingSendsOptionIndices() throws {
        let form = AgentQuestionForm(
            title: "Q",
            questions: [
                AgentQuestion(prompt: "A?", kind: .select, options: [.init(value: "0", label: "x"), .init(value: "1", label: "y")]),
                AgentQuestion(prompt: "B?", kind: .multiSelect, options: [.init(value: "0", label: "p"), .init(value: "1", label: "q")]),
            ],
            encoding: .claudeIndexed
        )
        let payload = try #require(AgentAnswerEncoder.encode(
            AgentQuestionAnswers(single: [0: "1"], multiple: [1: ["1", "0"]]),
            for: form
        ))
        #expect(payload == ["0": .strings(["1"]), "1": .strings(["0", "1"])])
    }

    // MARK: Claude status line and usage

    @Test func statusLineSnapshotReadsContextAndLimits() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let snapshot = try #require(ClaudeStatusLine.snapshot(from: [
            "session_id": "abc/../123",
            "model": ["display_name": "Opus"],
            "workspace": ["current_dir": "/tmp/project"],
            "context_window": ["used_percentage": 37.4],
            "rate_limits": [
                "five_hour": ["used_percentage": 81, "resets_at": 1_790_003_600],
                "seven_day": ["used_percentage": 12, "resets_at": "2026-10-25T00:00:00Z"],
            ],
        ], now: now))
        #expect(snapshot.sessionID == "abc..123")
        #expect(snapshot.contextPercent == 37.4)
        #expect(snapshot.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_790_003_600))
        #expect(snapshot.sevenDay?.resetsAt != nil)
        #expect(ClaudeStatusLine.defaultLine(for: snapshot) == "Opus · ctx 37% · 5h 81% · wk 12%")
        #expect(ClaudeStatusLine.snapshot(from: ["model": ["id": "x"]]) == nil)
    }

    @Test func claudeUsageDropsExpiredWindowsAndOldContext() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let fresh = ClaudeStatusSnapshot(
            sessionID: "a",
            contextPercent: 50,
            fiveHour: .init(usedPercent: 30, resetsAt: now.addingTimeInterval(-1)),
            sevenDay: .init(usedPercent: 60, resetsAt: now.addingTimeInterval(3_600)),
            updatedAt: now.addingTimeInterval(-60)
        )
        let group = try #require(AgentUsagePolicy.claudeGroup(from: [fresh], now: now))
        #expect(group.meters.map(\.kind) == [.weekly, .context])
        #expect(!group.isStale)

        let old = ClaudeStatusSnapshot(sessionID: "b", contextPercent: 90, updatedAt: now.addingTimeInterval(-3_600))
        #expect(AgentUsagePolicy.claudeGroup(from: [old], now: now) == nil)
    }

    @Test func claudeStatusLineWinsOverCrewlinesCopy() {
        let claude = AgentUsageGroup(source: .claude, label: "Claude", meters: [.init(kind: .context, usedPercent: 1)], isStale: false)
        let fromCrewline = [
            AgentUsageGroup(source: .claude, label: "Claude", meters: [.init(kind: .fiveHour, usedPercent: 2)], isStale: false),
            AgentUsageGroup(source: .codex, label: "Codex", meters: [.init(kind: .fiveHour, usedPercent: 3)], isStale: false),
        ]
        #expect(AgentUsagePolicy.merged(claude: claude, crewline: fromCrewline).map(\.source) == [.claude, .codex])
        #expect(AgentUsagePolicy.merged(claude: nil, crewline: fromCrewline).count == 2)
    }

    @Test func resetTextIsCompact() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(AgentUsagePolicy.resetText(now.addingTimeInterval(30), now: now) == "Resets in 1m")
        #expect(AgentUsagePolicy.resetText(now.addingTimeInterval(2 * 3_600 + 5 * 60), now: now) == "Resets in 2h 5m")
        #expect(AgentUsagePolicy.resetText(now.addingTimeInterval(3 * 86_400), now: now) == "Resets in 3 days")
        #expect(AgentUsagePolicy.resetText(nil, now: now) == nil)
    }

    @MainActor
    @Test func chainedStatusLineCommandUnescapes() {
        let command = "'/Apps/NotchShot.app/notchshot-ai' statusline --then 'echo '\\''hi'\\'''"
        #expect(AIHookInstaller.chainedCommand(in: command) == "echo 'hi'")
        #expect(AIHookInstaller.chainedCommand(in: "notchshot-ai statusline") == nil)
    }

    // MARK: Pairing and terminal jump

    @MainActor
    @Test func pairingAcceptsACodeOrALink() {
        #expect(CrewlineMonitor.pairingCode(from: "  ABCD-1234 \n") == "ABCD-1234")
        #expect(CrewlineMonitor.pairingCode(from: "crewline://pair?code=XY12&host=127.0.0.1") == "XY12")
    }

    @Test func jumpTargetsTheNearestGUIAncestor() {
        let chain: [AgentTerminalJumper.ProcessInfo] = [
            .init(pid: 300, parent: 200, name: "node", tty: "/dev/ttys004"),
            .init(pid: 200, parent: 100, name: "zsh", tty: "/dev/ttys004"),
            .init(pid: 100, parent: 1, name: "Terminal", tty: nil),
        ]
        let target = AgentTerminalJumper.target(in: chain, hint: nil, hosts: [100: "com.apple.Terminal"])
        #expect(target == .init(appPID: 100, bundleIdentifier: "com.apple.Terminal", tty: "/dev/ttys004", tmuxPane: false))
        // The hook's own report wins over the walk.
        #expect(AgentTerminalJumper.target(in: chain, hint: "ttys009", hosts: [100: ""])?.tty == "/dev/ttys009")
        #expect(AgentTerminalJumper.target(in: chain, hint: nil, hosts: [100: ""])?.bundleIdentifier == nil)
    }

    @Test func jumpThroughTmuxHandsOverThePane() {
        let chain: [AgentTerminalJumper.ProcessInfo] = [
            .init(pid: 300, parent: 200, name: "claude", tty: "/dev/ttys011"),
            .init(pid: 200, parent: 1, name: "tmux: server", tty: nil),
        ]
        let target = AgentTerminalJumper.target(in: chain, hint: nil, hosts: [:])
        #expect(target?.tmuxPane == true)
        #expect(target?.tty == "/dev/ttys011")
        #expect(AgentTerminalJumper.target(in: Array(chain.prefix(1)), hint: nil, hosts: [:]) == nil)
    }

    @Test func onlyPlainTTYsReachAppleScript() {
        #expect(AgentTerminalJumper.isSafeTTY("/dev/ttys004"))
        #expect(AgentTerminalJumper.isSafeTTY("/dev/tty0a"))
        #expect(!AgentTerminalJumper.isSafeTTY("/dev/ttys004\" then do shell script \"x"))
        #expect(!AgentTerminalJumper.isSafeTTY("/etc/passwd"))
        #expect(AgentTerminalJumper.terminalScript(tty: "/dev/../x") == nil)
        // A busy terminal must not hold the main actor for Apple events'
        // default two minutes.
        for script in [
            AgentTerminalJumper.terminalScript(tty: "/dev/ttys004"),
            AgentTerminalJumper.iTermScript(tty: "/dev/ttys004"),
        ] {
            #expect(script?.hasPrefix("with timeout of \(AgentTerminalJumper.scriptTimeoutSeconds) seconds") == true)
        }
        #expect(AgentTerminalJumper.normalizedTTY("not a tty") == nil)
        #expect(AgentTerminalJumper.normalizedTTY(" ttys002\n") == "/dev/ttys002")
    }

    /// tmux runs on the main actor; a wedged server must cost the budget,
    /// not hang the notch.
    @Test func tmuxCommandsGiveUpAtTheDeadline() {
        let started = Date()
        #expect(AgentTerminalJumper.run("/bin/sleep", ["10"], until: .now() + 0.3) == nil)
        #expect(Date().timeIntervalSince(started) < 2)

        #expect(AgentTerminalJumper.run("/bin/echo", ["pane"], until: .now() + 5) == "pane\n")
        // More than a pipe buffer of output still completes.
        let long = AgentTerminalJumper.run(
            "/bin/sh", ["-c", "head -c 300000 /dev/zero | tr '\\0' x"], until: .now() + 5
        )
        #expect(long?.count == 300_000)
        #expect(AgentTerminalJumper.run("/usr/bin/false", [], until: .now() + 5) == nil)
    }
}

/// Send to Agent checks a capture before its dialog and uploads it after, so
/// the upload must send the file that was chosen or nothing.
@Suite("Crewline attachments")
struct CrewlineAttachmentTests {
    @Test func chosenFileIsUploadedAsChosen() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let shot = try folder.write("SCREENSHOT", to: "shot.png")
        let identity = try #require(SafeAssetFile.identity(at: shot, maximumBytes: 1_000))
        let token = UUID().uuidString

        let attachment = try await CrewlineHTTP.upload(
            port: 1, token: token, fileURL: shot, expectedIdentity: identity,
            mimeType: "image/png", session: CrewlineUploadStub.session()
        )
        #expect(attachment["path"] as? String == "/stored/shot.png")
        #expect(CrewlineUploadStub.bodies(for: token) == [Data("SCREENSHOT".utf8)])
    }

    @Test func fileChangedWhileTheDialogWasOpenIsNotUploaded() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let secret = try folder.write("PRIVATE KEY", to: "secret.txt")
        let replacements: [(String, (URL) throws -> Void)] = [
            ("link", { url in
                try FileManager.default.removeItem(at: url)
                try FileManager.default.createSymbolicLink(at: url, withDestinationURL: secret)
            }),
            ("new file", { url in
                try FileManager.default.removeItem(at: url)
                try Data("PRIVATE KEY".utf8).write(to: url)
            }),
            ("edit in place", { url in
                let handle = try FileHandle(forWritingTo: url)
                try handle.write(contentsOf: Data("PRIVATEKEY".utf8))
                try handle.close()
                try FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: url.path)
            }),
        ]
        for (name, replace) in replacements {
            let shot = try folder.write("SCREENSHOT", to: "shot-\(UUID().uuidString).png")
            let identity = try #require(SafeAssetFile.identity(at: shot, maximumBytes: 1_000))
            try replace(shot)
            let token = UUID().uuidString

            await #expect(throws: NotchShotError.self, "\(name)") {
                try await CrewlineHTTP.upload(
                    port: 1, token: token, fileURL: shot, expectedIdentity: identity,
                    mimeType: "image/png", session: CrewlineUploadStub.session()
                )
            }
            #expect(CrewlineUploadStub.bodies(for: token).isEmpty, "\(name)")
        }
    }

    @Test func fileOverCrewlinesLimitIsRefusedBeforeReading() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let recording = try folder.write("", to: "recording.mov")
        let handle = try FileHandle(forWritingTo: recording)
        try handle.truncate(atOffset: UInt64(CrewlineHTTP.maximumAttachmentBytes + 1))
        try handle.close()
        let identity = try #require(SafeAssetFile.identity(at: recording, maximumBytes: .max))
        let token = UUID().uuidString

        await #expect(throws: CrewlineConnectionError.server(
            code: "body_too_large",
            message: "recording.mov is larger than 25 MB, the most Crewline takes."
        )) {
            try await CrewlineHTTP.upload(
                port: 1, token: token, fileURL: recording, expectedIdentity: identity,
                mimeType: "video/quicktime", session: CrewlineUploadStub.session()
            )
        }
        #expect(CrewlineUploadStub.bodies(for: token).isEmpty)
    }

    @Test func selectionPinsTheRecordedOrCurrentIdentity() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let shot = try folder.write("SCREENSHOT", to: "shot.png")
        let current = try #require(SafeAssetFile.identity(at: shot, maximumBytes: 1_000))

        let recorded = CaptureAsset(url: shot, kind: .screenshot, pixelSize: CGSize(width: 1, height: 1))
        #expect(SafeAssetFile.selectionIdentity(of: recorded) == current)
        // A legacy owned capture never stored one; it is taken at selection.
        let legacy = CaptureAsset(
            url: shot, kind: .screenshot, pixelSize: CGSize(width: 1, height: 1),
            captureMissingFileIdentities: false
        )
        #expect(legacy.externalFileIdentity == nil)
        #expect(SafeAssetFile.selectionIdentity(of: legacy) == current)
        // A Finder file without one cannot be vouched for.
        let finderFile = CaptureAsset(
            url: shot, kind: .document, pixelSize: .zero, ownership: .externalReference,
            captureMissingFileIdentities: false
        )
        #expect(SafeAssetFile.selectionIdentity(of: finderFile) == nil)

        try FileManager.default.removeItem(at: shot)
        try Data("OTHER".utf8).write(to: shot)
        #expect(SafeAssetFile.selectionIdentity(of: recorded) == nil)
    }
}

private struct TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-crewline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func write(_ text: String, to name: String) throws -> URL {
        let file = url.appendingPathComponent(name)
        try Data(text.utf8).write(to: file)
        return file
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Answers Crewline uploads in process and records each body by bearer
/// token, so tests running in parallel never see each other's requests.
private final class CrewlineUploadStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var received: [String: [Data]] = [:]

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CrewlineUploadStub.self]
        return URLSession(configuration: configuration)
    }

    static func bodies(for token: String) -> [Data] {
        lock.withLock { received["Bearer \(token)"] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while case let count = stream.read(&buffer, maxLength: buffer.count), count > 0 {
                body.append(buffer, count: count)
            }
            stream.close()
        }
        let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
        Self.lock.withLock { Self.received[authorization, default: []].append(body) }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: nil)
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"path":"/stored/shot.png","name":"shot.png"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Music keeps the centre while agents wait in the left satellite.
@Suite("Island media anchoring")
struct IslandMediaAnchoringTests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)
    static let anchored = IslandEngineConfiguration(anchoredKind: .media, preferredSlots: [.ai: .leading])

    static func activity(
        _ kind: IslandActivityKind,
        priority: IslandPriority = .normal,
        lifecycle: IslandLifecycle = .active
    ) -> IslandActivity {
        IslandActivity(
            id: IslandActivityID(kind: kind, key: "a"),
            priority: priority,
            relevance: 0.5,
            lifecycle: lifecycle,
            progress: .none,
            startedAt: t0,
            title: kind.rawValue,
            symbolName: "circle"
        )
    }

    @Test func waitingAgentStaysBesidePlayingMusic() {
        var engine = IslandPresentationEngine()
        engine.sync([Self.activity(.media), Self.activity(.timer)], now: Self.t0)
        _ = engine.present(configuration: Self.anchored, now: Self.t0)
        engine.sync(
            [Self.activity(.media), Self.activity(.timer), Self.activity(.ai, priority: .elevated, lifecycle: .waiting)],
            now: Self.t0
        )
        let presentation = engine.present(configuration: Self.anchored, now: Self.t0)
        #expect(presentation.primary?.id.kind == .media)
        #expect(presentation.leading?.id.kind == .ai)
        #expect(presentation.trailing?.id.kind == .timer)
    }

    @Test func withoutAnchoringAWaitingAgentTakesOver() {
        var engine = IslandPresentationEngine()
        engine.sync([Self.activity(.media), Self.activity(.ai, priority: .elevated, lifecycle: .waiting)], now: Self.t0)
        #expect(engine.present(now: Self.t0).primary?.id.kind == .ai)
    }

    @Test func pausedMusicDoesNotHoldTheCentre() {
        var engine = IslandPresentationEngine()
        engine.sync(
            [Self.activity(.media, lifecycle: .paused), Self.activity(.ai, priority: .elevated, lifecycle: .waiting)],
            now: Self.t0
        )
        #expect(engine.present(configuration: Self.anchored, now: Self.t0).primary?.id.kind == .ai)
    }

    @Test func tappingTheAgentPromotesItAndClearingHandsTheCentreBack() {
        var engine = IslandPresentationEngine()
        engine.sync([Self.activity(.media), Self.activity(.ai, priority: .elevated, lifecycle: .waiting)], now: Self.t0)
        _ = engine.present(configuration: Self.anchored, now: Self.t0)
        engine.select(IslandActivityID(kind: .ai, key: "a"), expand: true, now: Self.t0)
        let opened = engine.present(configuration: Self.anchored, now: Self.t0)
        #expect(opened.primary?.id.kind == .ai)
        #expect(opened.level == .expanded)
        engine.collapse()
        engine.clearSelection()
        let back = engine.present(configuration: Self.anchored, now: Self.t0)
        #expect(back.primary?.id.kind == .media)
        #expect(back.leading?.id.kind == .ai)
    }
}

/// The clipboard's smart actions only offer what would help.
@Suite("Clipboard smart actions")
struct ClipboardSmartActionTests {
    @Test func jsonFormatsWithoutReorderingKeys() throws {
        let transforms = ClipboardSmartActions.transforms(for: #"{"b":1,"a":[1, 2],"e":{},"s":"x, {y}: \"z\""}"#, kind: .text)
        let format = try #require(transforms.first { $0.kind == .formatJSON })
        #expect(format.output == """
        {
          "b": 1,
          "a": [
            1,
            2
          ],
          "e": {},
          "s": "x, {y}: \\"z\\""
        }
        """)
        let minify = try #require(transforms.first { $0.kind == .minifyJSON })
        #expect(minify.output == #"{"b":1,"a":[1,2],"e":{},"s":"x, {y}: \"z\""}"#)
    }

    @Test func jsonWithACombiningMarkAfterAQuoteFormatsWithoutCrashing() throws {
        // U+0301 right after a quote joins it into one Character. Read by
        // Character, the key's opening quote vanished, the brackets in the
        // value closed containers that never opened, and the indent crashed.
        let text = "{\"\u{301}a\":\"]]]\",\"b\":[1]}"
        let transforms = ClipboardSmartActions.transforms(for: text, kind: .text)
        let format = try #require(transforms.first { $0.kind == .formatJSON })
        #expect(format.output == "{\n  \"\u{301}a\": \"]]]\",\n  \"b\": [\n    1\n  ]\n}")
        #expect(transforms.first { $0.kind == .minifyJSON } == nil, "already minified")

        func part(_ object: String) -> String {
            Data(object.utf8).base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
        }
        let token = part(#"{"alg":"HS256"}"#) + "." + part("{\"\u{301}x\":\"]]\"}") + ".sig"
        let jwt = try #require(ClipboardSmartActions.transforms(for: token, kind: .text).first { $0.kind == .decodeJWT })
        #expect(jwt.output.hasSuffix("{\n  \"\u{301}x\": \"]]\"\n}"))
    }

    @Test func invalidOrScalarJSONIsLeftAlone() {
        #expect(ClipboardSmartActions.transforms(for: "{not json", kind: .text).isEmpty)
        #expect(ClipboardSmartActions.transforms(for: "42", kind: .text).isEmpty)
        #expect(ClipboardSmartActions.transforms(for: "hello world", kind: .text).isEmpty)
    }

    @Test func jwtDecodesHeaderAndClaims() throws {
        func part(_ object: String) -> String {
            Data(object.utf8).base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
        }
        let token = part(#"{"alg":"HS256","typ":"JWT"}"#) + "." + part(#"{"sub":"42","name":"Ada"}"#) + ".sig"
        let jwt = try #require(ClipboardSmartActions.transforms(for: token, kind: .text).first { $0.kind == .decodeJWT })
        #expect(jwt.output.contains(#""alg": "HS256""#))
        #expect(jwt.output.contains(#""name": "Ada""#))
    }

    @Test func base64OnlyWhenItDecodesToText() {
        let encoded = Data("hello from the notch".utf8).base64EncodedString()
        #expect(ClipboardSmartActions.transforms(for: encoded, kind: .text).first?.output == "hello from the notch")
        #expect(ClipboardSmartActions.decodedBase64("abcdefghijkl") == nil)
        #expect(ClipboardSmartActions.decodedBase64(Data([0, 1, 2, 3, 255, 254, 9, 7, 1]).base64EncodedString()) == nil)
    }

    @Test func timestampsBecomeDates() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let seconds = ClipboardSmartActions.transforms(for: "1700000000", kind: .text, timeZone: utc, locale: Locale(identifier: "en_US"))
        #expect(seconds.first { $0.kind == .timestampDate }?.output == "2023-11-14T22:13:20Z")
        let millis = ClipboardSmartActions.transforms(for: "1700000000123", kind: .text, timeZone: utc)
        #expect(millis.first { $0.kind == .timestampDate }?.output == "2023-11-14T22:13:20Z")
        #expect(ClipboardSmartActions.transforms(for: "9999999999", kind: .text).isEmpty)
        #expect(ClipboardSmartActions.transforms(for: "0123456789", kind: .text).isEmpty)
    }

    @Test func linksLoseOnlyTrackingParameters() {
        let link = "https://example.com/a?id=7&utm_source=x&fbclid=y"
        let cleaned = ClipboardSmartActions.transforms(for: link, kind: .link).first { $0.kind == .cleanLink }
        #expect(cleaned?.output == "https://example.com/a?id=7")
        #expect(ClipboardSmartActions.cleanedLink("https://example.com/a?id=7") == nil)
        #expect(ClipboardSmartActions.cleanedLink("https://example.com/?utm_medium=z") == "https://example.com/")
    }

    @Test func percentEncodingDecodes() {
        #expect(ClipboardSmartActions.transforms(for: "a%20b%2Fc", kind: .text).first?.output == "a b/c")
    }

    @Test func coloursConvert() {
        let transforms = ClipboardSmartActions.transforms(for: "#FF8000", kind: .color)
        #expect(transforms.map(\.output) == ["rgb(255, 128, 0)", "hsl(30, 100%, 50%)"])
        #expect(ClipboardSmartActions.transforms(for: "#fff", kind: .color).last?.output == "hsl(0, 0%, 100%)")
    }

    @Test func oversizedClippingsAreSkipped() {
        let huge = "[" + String(repeating: "1,", count: 200_000) + "1]"
        #expect(ClipboardSmartActions.transforms(for: huge, kind: .text).isEmpty)
    }
}
