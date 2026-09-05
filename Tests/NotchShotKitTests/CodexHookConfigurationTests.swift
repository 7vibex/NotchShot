import Foundation
import Testing
@testable import NotchShotKit

@Suite("Codex hook configuration preservation")
@MainActor
struct CodexHookConfigurationTests {
    private func withFixture(
        config: String,
        _ body: (AIHookInstaller, URL, URL) throws -> Void
    ) throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-toml-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true
        )
        let reporter = home.appendingPathComponent("notchshot-ai")
        try Data("#!/bin/sh\n".utf8).write(to: reporter)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: reporter.path)
        try Data(config.utf8).write(to: home.appendingPathComponent(".codex/config.toml"))
        try body(AIHookInstaller(home: home), home, reporter)
    }

    @Test("Commented and quoted tables retain all unrelated bytes", arguments: [
        "[features] # enabled features",
        "[\"features\"] # enabled features",
        "[ 'features' ] # enabled features",
        "[\"\\u0066eatures\"] # escaped table name",
    ])
    func tableHeaders(header: String) throws {
        let original = "notify = [\"existing\"]\n" + header
            + "\nother_flag = true\n[projects.\"/tmp/example\"] # project settings\ntrust_level = \"trusted\"\n"
        let expected = original.replacingOccurrences(of: header + "\n", with: header + "\ncodex_hooks = true\n")
        try withFixture(config: original) { installer, home, reporter in
            let result = try installer.install(.codex, reporterURL: reporter)
            #expect(result.enabledRuntime)
            let configURL = home.appendingPathComponent(".codex/config.toml")
            #expect(try String(contentsOf: configURL, encoding: .utf8) == expected)
            let backups = try FileManager.default.contentsOfDirectory(
                at: configURL.deletingLastPathComponent(), includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasPrefix("config.toml.notchshot-backup-") }
            #expect(backups.count == 1)
            let backup = try #require(backups.first)
            #expect(try String(contentsOf: backup, encoding: .utf8) == original)
            #expect(try installer.install(.codex, reporterURL: reporter).enabledRuntime == false)
            #expect(try String(contentsOf: configURL, encoding: .utf8) == expected)
        }
    }

    @Test("Updating the boolean preserves comments, similar keys, and line endings")
    func existingBoolean() throws {
        let original = "[features] # keep\r\n'codex_hooks'  =  false # keep this explanation\r\ncodex_hooks_extra = false\r\n[other] # boundary\r\ncodex_hooks = false\r\n"
        let expected = original.replacingOccurrences(
            of: "'codex_hooks'  =  false", with: "'codex_hooks'  =  true"
        )
        try withFixture(config: original) { installer, home, reporter in
            _ = try installer.install(.codex, reporterURL: reporter)
            #expect(try String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8) == expected)
        }
    }

    @Test("Prompt strings and array comments cannot impersonate feature headers")
    func multilineStrings() throws {
        let original = #"""
        instructions = """
        [features] # text inside a prompt
        codex_hooks = false
        """
        literal = '''
        ["features"]
        '''
        values = [
            "# this is a string", # array comment
            "[features]",
        ]
        [features] # real table
        other_flag = true
        """# + "\n"
        let expected = original.replacingOccurrences(
            of: "[features] # real table\n", with: "[features] # real table\ncodex_hooks = true\n"
        )
        try withFixture(config: original) { installer, home, reporter in
            _ = try installer.install(.codex, reporterURL: reporter)
            #expect(try String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8) == expected)
        }
    }

    @Test("Unsupported or ambiguous syntax changes neither configuration file", arguments: [
        "features = { codex_hooks = false }\n",
        "features.codex_hooks = false\n",
        "[features]\ncodex_hooks.child = true\n",
        "[features.codex_hooks]\nchild = true\n",
        "[[features]]\ncodex_hooks = false\n",
        "[features]\ncodex_hooks = false\ncodex_hooks = true\n",
        "[features]\ncodex_hooks = 'false'\n",
        "[features]\n[\"features\"] # duplicate table\n",
        "instructions = \"\"\"\n[features]\n",
    ])
    func rejectWithoutMutation(original: String) throws {
        try withFixture(config: original) { installer, home, reporter in
            let configDirectory = home.appendingPathComponent(".codex")
            let hooks = configDirectory.appendingPathComponent("hooks.json")
            let existingHooks = Data("{\"hooks\":{},\"unrelated\":true}".utf8)
            try existingHooks.write(to: hooks)
            let before = try FileManager.default.contentsOfDirectory(atPath: configDirectory.path).sorted()
            #expect(throws: AIHookInstallerError.self) {
                try installer.install(.codex, reporterURL: reporter)
            }
            #expect(try String(contentsOf: configDirectory.appendingPathComponent("config.toml"), encoding: .utf8) == original)
            #expect(try Data(contentsOf: hooks) == existingHooks)
            #expect(try FileManager.default.contentsOfDirectory(atPath: configDirectory.path).sorted() == before)
        }
    }

    @Test("Insertion handles a header at EOF and a missing table")
    func insertionBoundaries() throws {
        #expect(try CodexHookConfigurationEditor.enablingHooks(in: "[features] # comment")
            == "[features] # comment\ncodex_hooks = true\n")
        #expect(try CodexHookConfigurationEditor.enablingHooks(in: "notify = [\"existing\"]")
            == "notify = [\"existing\"]\n[features]\ncodex_hooks = true\n")
        #expect(try CodexHookConfigurationEditor.enablingHooks(in: "[features]\r\nother = true\r\n")
            == "[features]\r\ncodex_hooks = true\r\nother = true\r\n")
    }
}
