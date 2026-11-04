import Darwin
import Foundation
import Testing
@testable import NotchShotAIReporterSupport
@testable import NotchShotKit

@Suite("Audit Nov 2026: command redaction")
struct AuditNov2026RedactionTests {
    private func redacted(_ text: String) -> String {
        CommandSecretRedactor.redactText(text)
    }

    private func isUnchanged(_ text: String) -> Bool {
        redacted(text) == text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @Test("Everyday flags of known tools stay readable", arguments: [
        "mkdir -p dir",
        "git push -u origin main",
        "git checkout -b feature",
        "sort -u file",
        "find . -type f",
        "xcodebuild -project App.xcodeproj -destination generic/platform=macOS",
        "cd sub && mkdir -p a/b",
        "swift test 2>&1 | tail -5",
        "FOO=1 git log -p",
        "/bin/mkdir -p dir",
        "awk -F: '{print $1}' file",
        "rm -f file",
    ])
    func ordinaryCommands(command: String) {
        #expect(isUnchanged(command))
        #expect(ClaudePermissionDetails.actionDescription(
            tool: "Bash", input: ["command": command], cwd: "/tmp/synthetic-project"
        ) != nil)
    }

    @Test("Short options stay redacted unless every command on the line is known", arguments: [
        "curl -u user:hunter2 https://example.com",
        "wget -p hunter2 example.com",
        "cd sub && curl -u user:hunter2 example.com",
        "mkdir -p a; sshpass -p hunter2 ssh host",
        "mkdir -p a;sshpass -p hunter2 ssh host",
        "mkdir -p a\nsshpass -p hunter2 ssh host",
        "git log $(tool -p hunter2)",
        "git log `tool -p hunter2`",
        "find . -exec tool -p hunter2 {} +",
        "git -c alias.x='!tool -p hunter2' x",
        "git commit -m 'curl -u a:hunter2'",
        "sudo -p hunter2 ls",
        "ssh host tool -p hunter2",
        "zip -P hunter2 a.zip b",
        "sqlcmd -U sa -P hunter2",
        "mysql -phunter2 db",
        "unknown-tool -t hunter2",
    ])
    func credentialCommands(command: String) {
        #expect(!redacted(command).contains("hunter2"))
        #expect(ClaudePermissionDetails.actionDescription(
            tool: "Bash", input: ["command": command], cwd: "/tmp/synthetic-project"
        ) == nil)
    }

    @Test("curl's -F is matched by its exact spelling, split and attached")
    func multipartForm() {
        #expect(!redacted("curl -F data=hunter2 https://example.com").contains("hunter2"))
        #expect(!redacted("curl -Fdata=hunter2 https://example.com").contains("hunter2"))
        #expect(!CommandSecretRedactor.redact(["curl", "-F", "payload=hunter2", "u"]).joined().contains("hunter2"))
        // Lowercase -f takes no value anywhere it matters.
        #expect(redacted("unknown-tool -f file") == "unknown-tool -f file")
    }

    @Test("-F of a tool that takes no form data stays readable and approvable", arguments: [
        "npm test | grep -F error",
        "grep -F needle file",
        "ssh -F cfg host",
        "scp -F cfg a host:b",
        "sudo ls -F /x",
    ])
    func harmlessFormFlag(command: String) {
        #expect(isUnchanged(command))
        #expect(ClaudePermissionDetails.actionDescription(
            tool: "Bash", input: ["command": command], cwd: "/tmp/synthetic-project"
        ) != nil)
    }

    @Test("-F stays redacted for form data and for anything unknown", arguments: [
        "curl -F a=hunter2 https://example.com",
        "curl -Fa=hunter2 https://example.com",
        "npm test | grep -F x && curl -F a=hunter2 u",
        "grep -F needle file | http -F a=hunter2 u",
        "unknown-tool -F hunter2",
        "npm run x -F hunter2",
        "ssh -F cfg host tool -F hunter2",
        "ssh host tool -F hunter2",
        "grep -F \"$(tool -F hunter2)\" file",
        "find . -exec tool -F hunter2 {} +",
    ])
    func formDataStaysRedacted(command: String) {
        #expect(!redacted(command).contains("hunter2"))
    }

    @Test("Ordinary words and paths are not mistaken for secrets")
    func notSecrets() {
        #expect(redacted("The Asia team met") == "The Asia team met")
        #expect(redacted("Sources/Foo/Bar/H264Encoder123.swift") == "Sources/Foo/Bar/H264Encoder123.swift")
        #expect(ClaudeRunReport.target(
            tool: "Read",
            input: ["file_path": "/project/Sources/Foo/Bar/H264Encoder123.swift"],
            cwd: "/project"
        ) == "Sources/Foo/Bar/H264Encoder123.swift")
    }

    @Test("Real key shapes are still redacted")
    func realKeys() {
        // AWS's published documentation placeholders, in real key shapes.
        #expect(redacted("AKIAIOSFODNN7EXAMPLE") == "<redacted>")
        #expect(redacted("use ASIAIOSFODNN7EXAMPLE now") == "use <redacted> now")
        // Base64 with slashes and no file extension.
        #expect(redacted("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY") == "<redacted>")
    }
}

@Suite("Audit Nov 2026: reporter support")
struct AuditNov2026ReporterSupportTests {
    @Test("Long options parse in order, and name what is wrong")
    func longOptions() throws {
        let pairs = try LongOptions.parse(["--a", "1", "--b", "2", "--a", "3"])
        #expect(pairs.map(\.key) == ["a", "b", "a"])
        #expect(pairs.map(\.value) == ["1", "2", "3"])

        #expect(failure(["stray"]) == "Unexpected argument: stray")
        #expect(failure(["--a"]) == "Missing value for --a")
        #expect(failure(["--a", "--b"]) == "Missing value for --a")
    }

    private func failure(_ arguments: ArraySlice<String>) -> String? {
        do {
            _ = try LongOptions.parse(arguments)
            return nil
        } catch {
            return error.message
        }
    }

    @Test("Connecting reports why it could not, and leaves nothing open")
    func socketFailures() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx7-\(UUID().uuidString.prefix(8)).sock").path
        #expect(connectionError(to: missing) == .notListening)
        #expect(connectionError(to: "/tmp/" + String(repeating: "x", count: 200)) == .pathTooLong)
    }

    private func connectionError(to path: String) -> OwnerOnlySocket.ConnectionError? {
        do {
            close(try OwnerOnlySocket.connection(to: path))
            return nil
        } catch {
            return error
        }
    }
}

@Suite("Audit Nov 2026: notes typing")
@MainActor
struct AuditNov2026NotesTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("A keystroke shows at once, and flush puts it on disk")
    func flushSavesTyping() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("notes.json")
        let store = ProductivityNoteStore(storeURL: url)
        var note = store.create()
        let saved = try Data(contentsOf: url)

        note.body = "typed"
        store.edit(note)
        #expect(store.notes.first?.body == "typed")
        #expect(try Data(contentsOf: url) == saved)

        store.flush()
        #expect(store.lastError == nil)
        #expect(ProductivityNoteStore(storeURL: url).notes.first?.body == "typed")
    }

    @Test("Typing reaches the disk by itself once it pauses")
    func pauseSavesTyping() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("notes.json")
        let store = ProductivityNoteStore(storeURL: url)
        var note = store.create()
        note.body = "typed"
        store.edit(note)

        var reloaded: String?
        for _ in 0 ..< 100 {
            try await Task.sleep(for: .milliseconds(50))
            reloaded = ProductivityNoteStore(storeURL: url).notes.first?.body
            if reloaded == "typed" { break }
        }
        #expect(reloaded == "typed")
    }

    @Test("finishEditing saves without waiting for the pause")
    func finishEditingSaves() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("notes.json")
        let store = ProductivityNoteStore(storeURL: url)
        var note = store.create()
        note.body = "typed"
        store.edit(note)
        store.finishEditing()
        // Any later synchronous save runs behind the one finishEditing queued.
        store.flush()
        #expect(ProductivityNoteStore(storeURL: url).notes.first?.body == "typed")
    }

    @Test("A title keeps its spaces while typed, and is tidied on disk and when done")
    func titleAsTyped() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("notes.json")
        let store = ProductivityNoteStore(storeURL: url)
        var note = store.create()

        note.title = "two "
        store.edit(note)
        #expect(store.notes.first?.title == "two ")
        note.title = ""
        store.edit(note)
        #expect(store.notes.first?.title == "")

        store.flush()
        #expect(store.notes.first?.title == "Untitled Note")
        #expect(ProductivityNoteStore(storeURL: url).notes.first?.title == "Untitled Note")
    }

    @Test("A body-only edit leaves an untouched legacy title exactly as it was")
    func legacyTitleSurvivesTyping() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("notes.json")
        let title = "  legacy  "
        try JSONEncoder().encode([ProductivityNote(title: title, body: "Original")]).write(to: url)
        let store = ProductivityNoteStore(storeURL: url)
        var note = try #require(store.notes.first)
        note.body = "Changed"
        store.edit(note)
        store.flush()
        let reloaded = ProductivityNoteStore(storeURL: url).notes.first
        #expect(reloaded?.title == title)
        #expect(reloaded?.body == "Changed")
    }

    @Test("A discrete action saves the typing queued ahead of it")
    func discreteActionIncludesTyping() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("notes.json")
        let store = ProductivityNoteStore(storeURL: url)
        var note = store.create()
        note.body = "typed"
        store.edit(note)
        _ = store.create()
        let reloaded = ProductivityNoteStore(storeURL: url).notes
        #expect(reloaded.count == 2)
        #expect(reloaded.contains { $0.body == "typed" })
    }

    @Test("A locked store refuses typing up front, and a failed save keeps the text")
    func failures() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }

        let corrupt = Data("{synthetic invalid JSON".utf8)
        let lockedURL = root.appendingPathComponent("locked.json")
        try corrupt.write(to: lockedURL)
        let locked = ProductivityNoteStore(storeURL: lockedURL)
        #expect(locked.isWriteLocked)
        locked.edit(ProductivityNote())
        #expect(locked.notes.isEmpty)
        #expect(try Data(contentsOf: lockedURL) == corrupt)

        let changedURL = root.appendingPathComponent("changed.json")
        let store = ProductivityNoteStore(storeURL: changedURL)
        var note = store.create()
        try corrupt.write(to: changedURL, options: .atomic)
        note.body = "typed"
        store.edit(note)
        store.flush()
        #expect(store.lastError != nil)
        #expect(store.notes.first?.body == "typed")
        #expect(try Data(contentsOf: changedURL) == corrupt)
    }
}

@Suite("Audit Nov 2026: notification inbox")
@MainActor
struct AuditNov2026NotificationStoreTests {
    @Test("An inbox that could not be read is kept aside, and saving carries on")
    func unreadableInboxSurvives() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let undecodable = root.appendingPathComponent("undecodable.json")
        let future = Data(#"[{"state":"fromALaterBuild"}]"#.utf8)
        try future.write(to: undecodable)
        let oversized = root.appendingPathComponent("oversized.json")
        let large = Data(repeating: 32, count: ProductivityNotificationStore.maximumStoreBytes + 1)
        try large.write(to: oversized)

        for (url, original) in [(undecodable, future), (oversized, large)] {
            let store = ProductivityNotificationStore(storeURL: url)
            #expect(store.lastError != nil)
            store.recordScheduled(
                id: UUID(), title: "New", body: "Alert", priority: .standard, scheduledAt: Date()
            )
            #expect(store.items.count == 1)
            #expect(store.lastError == nil)
            let reopened = ProductivityNotificationStore(storeURL: url)
            #expect(reopened.lastError == nil)
            #expect(reopened.items.count == 1)
            let name = url.deletingPathExtension().lastPathComponent
            let kept = try FileManager.default.contentsOfDirectory(atPath: root.path)
                .filter { $0.hasPrefix(name + ".corrupt-") && $0.hasSuffix(".json") }
            #expect(kept.count == 1)
            #expect(try Data(contentsOf: root.appendingPathComponent(kept[0])) == original)
        }
    }

    @Test("A missing inbox is simply empty, and saves")
    func missingInboxSaves() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("nested/items.json")
        let store = ProductivityNotificationStore(storeURL: url)
        #expect(store.lastError == nil)
        store.recordScheduled(id: UUID(), title: "New", body: "Alert", priority: .standard, scheduledAt: Date())
        #expect(store.lastError == nil)
        #expect(ProductivityNotificationStore(storeURL: url).items.count == 1)
    }
}

@Suite("Audit Nov 2026: LocalSend")
struct AuditNov2026LocalSendTests {
    @Test("An IPv6 receiver gets a URL")
    func ipv6() throws {
        #expect(try LocalSendClient.baseURL(for: LocalSendPeer(host: "fc00::1")).absoluteString == "https://[fc00::1]:53317")
        #expect(try LocalSendClient.baseURL(for: LocalSendPeer(host: " 192.168.1.2 ", usesHTTPS: false)).absoluteString == "http://192.168.1.2:53317")
        #expect(throws: LocalSendError.invalidPeer) { try LocalSendClient.baseURL(for: LocalSendPeer(host: "8.8.8.8")) }
    }

    @Test("A refused host fails before anything is copied")
    func invalidHostCopiesNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.bin")
        try Data("bytes".utf8).write(to: file)
        let selection = try #require(LocalSendSelection(url: file))
        // Replaced after selection: reaching the copy would report unsafeFile.
        try FileManager.default.removeItem(at: file)
        await #expect(throws: LocalSendError.invalidPeer) {
            try await LocalSendClient().send(files: [selection], to: LocalSendPeer(host: "8.8.8.8")) { _ in }
        }
    }

    @Test("Only old leftover snapshots are removed at launch")
    func staleSnapshots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let stale = root.appendingPathComponent("notchshot-localsend-stale")
        let fresh = root.appendingPathComponent("notchshot-localsend-fresh")
        let unrelated = root.appendingPathComponent("something-else")
        for directory in [stale, fresh, unrelated] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let old = Date().addingTimeInterval(-3 * 24 * 60 * 60)
        for directory in [stale, unrelated] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: directory.path)
        }
        LocalSendClient.removeStaleSnapshots(in: root)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test("A send delivers the file; a reply without end is stopped and the session is cancelled")
    func loopbackTransfers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.bin")
        let size = 2_000_000
        try Data(repeating: 7, count: size).write(to: file)
        let selection = try #require(LocalSendSelection(url: file))

        let accepting = try LoopbackReceiver(uploadReply: .ok)
        defer { accepting.stop() }
        let sent = try await LocalSendClient().send(
            files: [selection],
            to: LocalSendPeer(host: "127.0.0.1", port: accepting.port, usesHTTPS: false)
        ) { _ in }
        #expect(sent == 1)
        #expect(accepting.uploadedBytes == size)

        let endless = try LoopbackReceiver(uploadReply: .endless)
        defer { endless.stop() }
        await #expect(throws: LocalSendError.invalidResponse) {
            try await LocalSendClient().send(
                files: [selection],
                to: LocalSendPeer(host: "127.0.0.1", port: endless.port, usesHTTPS: false)
            ) { _ in }
        }
        var cancelled = false
        for _ in 0 ..< 100 where !cancelled {
            try await Task.sleep(for: .milliseconds(20))
            cancelled = endless.requestLines.contains { $0.contains("/api/localsend/v2/cancel?sessionId=session") }
        }
        #expect(cancelled)

        let endlessPrepare = try LoopbackReceiver(uploadReply: .ok, endlessPrepare: true)
        defer { endlessPrepare.stop() }
        await #expect(throws: LocalSendError.invalidResponse) {
            try await LocalSendClient().send(
                files: [selection],
                to: LocalSendPeer(host: "127.0.0.1", port: endlessPrepare.port, usesHTTPS: false)
            ) { _ in }
        }
        #expect(endlessPrepare.uploadedBytes == 0)
    }
}

/// A tiny HTTP/1.1 receiver on the loopback address. Nothing leaves this Mac.
private final class LoopbackReceiver: @unchecked Sendable {
    enum UploadReply { case ok, endless }

    private let lock = NSLock()
    private var lines: [String] = []
    private var uploaded = 0
    private let listener: Int32
    private let uploadReply: UploadReply
    private let endlessPrepare: Bool
    let port: Int

    var requestLines: [String] { lock.withLock { lines } }
    var uploadedBytes: Int { lock.withLock { uploaded } }

    init(uploadReply: UploadReply, endlessPrepare: Bool = false) throws {
        self.uploadReply = uploadReply
        self.endlessPrepare = endlessPrepare
        listener = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let descriptor = listener
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, length) }
        }
        guard bound == 0, listen(descriptor, 16) == 0 else { throw POSIXError(.EADDRNOTAVAIL) }
        _ = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        port = Int(UInt16(bigEndian: address.sin_port))
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(descriptor, nil, nil)
                guard client >= 0 else { return }
                Thread.detachNewThread { [self] in serve(client) }
            }
        }
    }

    func stop() {
        shutdown(listener, SHUT_RDWR)
        close(listener)
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let separator = Data("\r\n\r\n".utf8)
        while received.range(of: separator) == nil {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { return }
            received.append(contentsOf: buffer.prefix(count))
        }
        guard let end = received.range(of: separator) else { return }
        let head = String(decoding: received[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let line = head.first ?? ""
        lock.withLock { lines.append(line) }
        let length = head
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        let isPrepare = line.contains("prepare-upload")
        var body = Data(received[end.upperBound...])
        var bodyBytes = body.count
        while bodyBytes < length {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { break }
            bodyBytes += count
            if isPrepare { body.append(contentsOf: buffer.prefix(count)) }
        }

        if isPrepare {
            if endlessPrepare {
                writeEndlessly(to: client)
                return
            }
            let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let identifiers = (object?["files"] as? [String: Any])?.keys.map { $0 } ?? []
            let tokens = Dictionary(uniqueKeysWithValues: identifiers.map { ($0, "token") })
            let reply = (try? JSONSerialization.data(withJSONObject: ["sessionId": "session", "files": tokens])) ?? Data()
            respond(to: client, body: String(decoding: reply, as: UTF8.self))
        } else if line.contains("/upload") {
            lock.withLock { uploaded += bodyBytes }
            if uploadReply == .endless {
                writeEndlessly(to: client)
            } else {
                respond(to: client, body: "ok")
            }
        } else {
            respond(to: client, body: "")
        }
    }

    private func respond(to client: Int32, body: String) {
        let text = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        _ = text.withCString { write(client, $0, strlen($0)) }
    }

    /// Until the client hangs up.
    private func writeEndlessly(to client: Int32) {
        let head = "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n"
        _ = head.withCString { write(client, $0, strlen($0)) }
        let chunk = [UInt8](repeating: 120, count: 65_536)
        while write(client, chunk, chunk.count) > 0 {}
    }
}
