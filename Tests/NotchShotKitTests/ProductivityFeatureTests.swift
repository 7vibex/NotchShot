import Foundation
import Testing
@testable import NotchShotKit

@Suite("Droppy-inspired productivity features")
struct ProductivityFeatureTests {
    @Test("Natural-language planner extracts kind, relative day, time, duration, and clean title")
    func naturalLanguagePlanner() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 20, hour: 10
        )))
        let draft = try #require(NaturalLanguagePlanner.parse(
            "Remind me to call Alex tomorrow at 3:30pm for 45 minutes",
            now: now,
            calendar: calendar
        ))
        #expect(draft.kind == .reminder)
        #expect(draft.title == "call Alex")
        #expect(draft.duration == 45 * 60)
        #expect(calendar.component(.day, from: draft.date) == 21)
        #expect(calendar.component(.hour, from: draft.date) == 15)
        #expect(calendar.component(.minute, from: draft.date) == 30)
    }

    @Test("Focus timer snapshots show real remaining time and completion state")
    func focusTimerPolicy() {
        let running = FocusTimerSnapshot(
            label: "Deep Work",
            state: .running,
            duration: 25 * 60,
            elapsed: 65
        )
        let context = FocusTimerPolicy.context(from: running)
        #expect(context.kind == .timer)
        #expect(context.metric == "23:55")
        #expect(context.focusTimer?.label == "Deep Work")
        #expect(!context.mayInterruptMedia)

        var completed = running
        completed.elapsed = completed.duration
        completed.state = .completed
        #expect(FocusTimerPolicy.context(from: completed).mayInterruptMedia)
    }

    @Test("Live transcript replaces volatile words and preserves finalized phrases")
    func liveTranscriptAccumulator() {
        var transcript = LiveTranscriptAccumulator()

        transcript.consume("hello wor", isFinal: false)
        #expect(transcript.text == "hello wor")

        transcript.consume("hello world", isFinal: false)
        #expect(transcript.text == "hello world")

        transcript.consume("hello world", isFinal: true)
        transcript.consume("from the not", isFinal: false)
        #expect(transcript.text == "hello world from the not")

        transcript.consume("from the notch", isFinal: true)
        #expect(transcript.text == "hello world from the notch")
        #expect(transcript.volatilePart.isEmpty)
    }

    @Test("Empty speech updates do not erase finalized text")
    func liveTranscriptIgnoresEmptyFinals() {
        var transcript = LiveTranscriptAccumulator()
        transcript.consume("saved phrase", isFinal: true)
        transcript.consume("   ", isFinal: true)
        #expect(transcript.text == "saved phrase")
    }

    @Test("AI sanitization retains explicit start time and terminal source")
    func aiElapsedMetadata() throws {
        let started = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let activity = AIActivitySnapshot(
            id: "build",
            source: .terminal,
            state: .working,
            title: "Swift build",
            startedAt: started,
            updatedAt: started.addingTimeInterval(12)
        )
        let sanitized = try #require(AIActivityPolicy.sanitized(activity))
        #expect(sanitized.source == .terminal)
        #expect(sanitized.startedAt == started)
        #expect(sanitized.elapsed(now: started.addingTimeInterval(42)) == 42)
    }

    @Test("AI hook installation preserves unrelated settings, backs up once, and is idempotent")
    @MainActor
    func hookInstallationMerge() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let reporter = root.appendingPathComponent("notchshot-ai")
        try Data("#!/bin/sh\n".utf8).write(to: reporter)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: reporter.path)

        let installer = AIHookInstaller(home: root)
        let settings = installer.configurationURL(for: .claude)
        try FileManager.default.createDirectory(
            at: settings.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let existing: [String: Any] = [
            "theme": "dark",
            "hooks": [
                "Stop": [[
                    "matcher": "",
                    "hooks": [["type": "command", "command": "existing-tool"]],
                ]],
            ],
        ]
        try JSONSerialization.data(withJSONObject: existing).write(to: settings)

        let first = try installer.install(.claude, reporterURL: reporter)
        #expect(first.addedEvents == AIHookIntegration.claude.events.count)
        #expect(first.backupURL != nil)
        let merged = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
        )
        #expect(merged["theme"] as? String == "dark")
        let hooks = try #require(merged["hooks"] as? [String: Any])
        let stop = try #require(hooks["Stop"] as? [[String: Any]])
        #expect(stop.count == 2)

        let second = try installer.install(.claude, reporterURL: reporter)
        #expect(second.addedEvents == 0)
        #expect(second.backupURL == nil)

        let codexConfig = root.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: codexConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("notify = [\"existing\"]\n\n[features]\nother_flag = true\n".utf8)
            .write(to: codexConfig)
        let codex = try installer.install(.codex, reporterURL: reporter)
        #expect(codex.enabledRuntime)
        let configText = try String(contentsOf: codexConfig, encoding: .utf8)
        #expect(configText.contains("notify = [\"existing\"]"))
        #expect(configText.contains("other_flag = true"))
        #expect(configText.contains("codex_hooks = true"))
    }
}
