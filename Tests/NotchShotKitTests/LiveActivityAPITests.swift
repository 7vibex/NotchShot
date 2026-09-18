import Darwin
import Foundation
import NotchShotAIReporterSupport
import Testing
@testable import NotchShotKit

/// The external Live Activity API treats every message as untrusted. These
/// tests pin the validation and the bounds, not just the happy path.
@Suite("Live Activity API")
struct LiveActivityAPITests {
    static let t0 = Date(timeIntervalSince1970: 3_000_000)

    private func decode(_ json: String) -> Result<LiveActivityUpdate, LiveActivityValidationError> {
        LiveActivitySanitizer.decode(Data(json.utf8))
    }

    // MARK: Validation

    @Test("A well-formed start decodes into typed, bounded values")
    func validStart() throws {
        let result = decode(#"{"command":"start","id":"swift-test","source":"SwiftPM","title":"swift test","progress":0.25,"icon":"test","accent":"green","urgency":"normal","unit":"items","current":5,"total":20,"etaSeconds":30}"#)
        let update = try result.get()
        #expect(update.command == .start)
        #expect(update.id == "swift-test")
        #expect(update.progress == 0.25)
        #expect(update.icon == .test)
        #expect(update.accent == .green)
        #expect(update.current == 5)
        #expect(update.total == 20)
        #expect(update.unit == .items)
    }

    @Test("Identifiers must be short and use a safe character set",
          arguments: ["", "../etc/passwd", "a b", "rm -rf /", "ïd", String(repeating: "x", count: 65), "a/b"])
    func rejectsUnsafeIDs(_ id: String) {
        #expect(!LiveActivitySanitizer.isValidIdentifier(id))
    }

    @Test("Unknown commands, icons, accents, units and urgencies are rejected",
          arguments: [
              #"{"command":"exec","id":"a","title":"x"}"#,
              #"{"command":"start","id":"a","title":"x","icon":"/Applications/Evil.app"}"#,
              #"{"command":"start","id":"a","title":"x","icon":"hammer.fill"}"#,
              ##"{"command":"start","id":"a","title":"x","accent":"#FF0000"}"##,
              #"{"command":"start","id":"a","title":"x","unit":"parsecs"}"#,
              #"{"command":"start","id":"a","title":"x","urgency":"critical"}"#,
          ])
    func rejectsUnknownCatalogValues(_ json: String) {
        #expect((try? decode(json).get()) == nil)
    }

    @Test("Progress and measured values must be finite and in range",
          arguments: [
              #"{"command":"update","id":"a","progress":1.5}"#,
              #"{"command":"update","id":"a","progress":-0.1}"#,
              #"{"command":"update","id":"a","current":-1}"#,
              #"{"command":"update","id":"a","current":10,"total":5}"#,
              #"{"command":"update","id":"a","current":1e300}"#,
              #"{"command":"update","id":"a","etaSeconds":-5}"#,
              #"{"command":"update","id":"a","expiresInSeconds":0}"#,
              #"{"command":"update","id":"a","expiresInSeconds":999999999}"#,
          ])
    func rejectsOutOfRangeNumbers(_ json: String) {
        #expect((try? decode(json).get()) == nil)
    }

    @Test("A start without a title, malformed JSON, an empty body, and oversized messages are rejected")
    func rejectsMalformed() {
        #expect((try? decode(#"{"command":"start","id":"a"}"#).get()) == nil)
        #expect((try? decode("not json").get()) == nil)
        #expect((try? LiveActivitySanitizer.decode(Data()).get()) == nil)
        let huge = #"{"command":"start","id":"a","title":""# + String(repeating: "x", count: 5_000) + #""}"#
        #expect((try? decode(huge).get()) == nil)
    }

    @Test("Newer protocol versions are refused rather than half-understood")
    func rejectsFutureVersion() {
        #expect((try? decode(#"{"version":99,"command":"start","id":"a","title":"x"}"#).get()) == nil)
    }

    @Test("Text is stripped of control and bidi-override characters, collapsed, and bounded")
    func sanitizesText() {
        #expect(LiveActivitySanitizer.text("a\u{202E}b\u{0007}c", maximum: 80) == "abc")
        #expect(LiveActivitySanitizer.text("  line\n\n\tbreaks  ", maximum: 80) == "line breaks")
        #expect(LiveActivitySanitizer.text("\u{200B}\u{FEFF}", maximum: 80) == nil)
        let long = LiveActivitySanitizer.text(String(repeating: "t", count: 500), maximum: LiveActivitySanitizer.maximumTitleLength)
        #expect(long?.count == LiveActivitySanitizer.maximumTitleLength)
        #expect(long?.hasSuffix("…") == true)
    }

    @Test("Markup and paths are displayed as inert text, never interpreted")
    func markupIsInert() throws {
        let update = try decode(#"{"command":"start","id":"a","title":"<script>alert(1)</script> file:///etc/passwd"}"#).get()
        #expect(update.title == "<script>alert(1)</script> file:///etc/passwd")
    }

    @Test("The acknowledgement is one JSON line")
    func acknowledgement() throws {
        let ok = LiveActivitySanitizer.acknowledgement(error: nil)
        #expect(ok.last == 10)
        let failure = String(decoding: LiveActivitySanitizer.acknowledgement(error: .init("rate limited")), as: UTF8.self)
        #expect(failure.contains("\"ok\":false"))
        #expect(failure.contains("rate limited"))
    }

    @Test("The client message encoder round-trips through validation")
    func messageRoundTrip() throws {
        let message = LiveActivityMessage(command: .update, id: "ffmpeg", progress: 0.5, unit: .bytes, icon: .render)
        let data = try JSONEncoder().encode(message)
        let update = try LiveActivitySanitizer.decode(data).get()
        #expect(update.progress == 0.5)
        #expect(update.icon == .render)
    }

    // MARK: Registry bounds and lifecycle

    private func update(
        _ command: LiveActivityCommand,
        _ id: String = "build",
        title: String? = "Build",
        progress: Double? = nil,
        expiresIn: TimeInterval? = nil
    ) -> LiveActivityUpdate {
        LiveActivityUpdate(command: command, id: id, title: title, progress: progress, expiresIn: expiresIn)
    }

    @Test("Start, update, finish keeps one identity and lingers briefly before history")
    func lifecycle() {
        var registry = ExternalActivityRegistry()
        let value1 = registry.apply(update(.start), now: Self.t0)
        #expect((value1 == nil))
        let value2 = registry.apply(update(.update, title: nil, progress: 0.42), now: Self.t0.addingTimeInterval(1))
        #expect((value2 == nil))
        #expect(registry.live.count == 1)
        #expect(registry.live[0].progress == 0.42)
        #expect(registry.live[0].startedAt == Self.t0)

        let value3 = registry.apply(update(.finish, title: nil), now: Self.t0.addingTimeInterval(2))
        #expect((value3 == nil))
        #expect(registry.live[0].lifecycle == .succeeded)
        #expect(registry.live[0].progress == 1)
        registry.expire(now: Self.t0.addingTimeInterval(3))
        #expect(registry.live.count == 1, "success stays visible briefly")
        registry.expire(now: Self.t0.addingTimeInterval(10))
        #expect(registry.live.isEmpty)
        #expect(registry.history.first?.id == "build")
    }

    @Test("Dismiss removes without recording history")
    func dismiss() {
        var registry = ExternalActivityRegistry()
        registry.apply(update(.start), now: Self.t0)
        registry.apply(update(.dismiss, title: nil), now: Self.t0)
        #expect(registry.live.isEmpty)
        #expect(registry.history.isEmpty)
    }

    @Test("An update for an unknown id without a title is refused")
    func unknownUpdate() {
        var registry = ExternalActivityRegistry()
        let value4 = registry.apply(update(.update, title: nil, progress: 0.5), now: Self.t0)
        #expect((value4 != nil))
    }

    @Test("Live activity count is bounded")
    func countBounded() {
        var registry = ExternalActivityRegistry()
        let limit = registry.limits.maximumLiveActivities
        for index in 0 ..< limit {
            let value5 = registry.apply(update(.start, "a\(index)"), now: Self.t0.addingTimeInterval(Double(index)))
            #expect((value5 == nil))
        }
        let value6 = registry.apply(update(.start, "overflow"), now: Self.t0.addingTimeInterval(100))
        #expect((value6 != nil))
        #expect(registry.live.count == limit)
    }

    @Test("Message rate is bounded by a token bucket that refills")
    func rateLimited() {
        var limits = ExternalActivityRegistry.Limits()
        limits.burst = 5
        limits.messagesPerSecond = 1
        var registry = ExternalActivityRegistry(limits: limits)
        registry.apply(update(.start), now: Self.t0)
        for _ in 0 ..< 4 { registry.apply(update(.update, title: nil, progress: 0.1), now: Self.t0) }
        let value7 = registry.apply(update(.update, title: nil, progress: 0.2), now: Self.t0)
        #expect((value7 == .init("rate limited")))
        let value8 = registry.apply(update(.update, title: nil, progress: 0.3), now: Self.t0.addingTimeInterval(2))
        #expect((value8 == nil))
    }

    @Test("Stale, expired, and over-age activities leave on their own")
    func staleAndLifetime() {
        var registry = ExternalActivityRegistry()
        registry.apply(update(.start, "stale"), now: Self.t0)
        registry.apply(update(.start, "expiring", expiresIn: 10), now: Self.t0)
        registry.expire(now: Self.t0.addingTimeInterval(11))
        #expect(registry.live.map(\.id) == ["stale"])
        registry.expire(now: Self.t0.addingTimeInterval(registry.limits.staleInterval + 1))
        #expect(registry.live.isEmpty)

        var busy = ExternalActivityRegistry()
        busy.apply(update(.start, "forever"), now: Self.t0)
        var time = Self.t0
        while time.timeIntervalSince(Self.t0) < busy.limits.maximumLifetime + 60 {
            time = time.addingTimeInterval(600)
            busy.apply(update(.update, "forever", title: nil, progress: 0.5), now: time)
        }
        busy.expire(now: time)
        #expect(busy.live.isEmpty, "regular updates cannot keep an activity alive past its lifetime")
    }

    @Test("History is bounded and clearable")
    func historyBounded() {
        var registry = ExternalActivityRegistry()
        for index in 0 ..< 50 {
            registry.apply(update(.finish, "done\(index)"), now: Self.t0.addingTimeInterval(Double(index)))
        }
        #expect(registry.history.count == registry.limits.maximumHistory)
        #expect(registry.history.first?.id == "done49")
        registry.clearHistory()
        #expect(registry.history.isEmpty)
    }

    @Test("A deadline is always scheduled while anything is live")
    func deadline() {
        var registry = ExternalActivityRegistry()
        #expect(registry.nextDeadline == nil)
        registry.apply(update(.start, expiresIn: 30), now: Self.t0)
        #expect(registry.nextDeadline == Self.t0.addingTimeInterval(30))
    }

    // MARK: Socket

    @Test("The socket path is per-user and fits sockaddr_un")
    func socketPath() {
        let path = LiveActivitySocket.path
        #expect(path.contains("notchshot-activity-\(getuid())"))
        #expect(path.utf8.count < 104)
    }
}

/// Real Unix socket round trip against the server, on a private path.
@Suite("Live Activity socket", .serialized)
struct LiveActivitySocketTests {
    private static func temporarySocketPath() -> String {
        "/tmp/ns-la-\(getpid())-\(UInt32.random(in: 0 ... .max)).sock"
    }

    private static func send(_ payload: Data, to path: String) -> String? {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) {
                strcpy(UnsafeMutableRawPointer($0).assumingMemoryBound(to: CChar.self), source)
            }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        _ = payload.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        shutdown(descriptor, SHUT_WR)
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = read(descriptor, &buffer, buffer.count)
        guard count > 0 else { return nil }
        return String(decoding: buffer.prefix(count), as: UTF8.self)
    }

    private static func waitForSocket(_ path: String) async {
        for _ in 0 ..< 100 {
            if FileManager.default.fileExists(atPath: path) { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("A valid message reaches the handler once validated and is acknowledged")
    func roundTrip() async throws {
        let path = Self.temporarySocketPath()
        let server = LiveActivitySocketServer(socketPath: path)
        let received = LockedBox<[LiveActivityUpdate]>([])
        server.start { update in
            received.mutate { $0.append(update) }
            return nil
        }
        defer { server.stop() }
        await Self.waitForSocket(path)

        var info = stat()
        #expect(lstat(path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600, "owner-only socket")

        let message = try JSONEncoder().encode(LiveActivityMessage(command: .start, id: "build", title: "Build", icon: .build)) + Data([10])
        let reply = await Task.detached { Self.send(message, to: path) }.value
        #expect(reply?.contains("\"ok\":true") == true)
        #expect(received.value.map(\.id) == ["build"])
    }

    @Test("Invalid input is rejected before the app ever sees it")
    func rejectsBeforeHandler() async {
        let path = Self.temporarySocketPath()
        let server = LiveActivitySocketServer(socketPath: path)
        let received = LockedBox<Int>(0)
        server.start { _ in
            received.mutate { $0 += 1 }
            return nil
        }
        defer { server.stop() }
        await Self.waitForSocket(path)

        let bad = Data(#"{"command":"start","id":"../../etc","title":"x"}"#.utf8) + Data([10])
        let reply = await Task.detached { Self.send(bad, to: path) }.value
        #expect(reply?.contains("\"ok\":false") == true)
        #expect(received.value == 0)
    }

    @Test("A regular file planted at the socket path is never unlinked or reused")
    func refusesPlantedFile() async throws {
        let path = Self.temporarySocketPath()
        #expect(FileManager.default.createFile(atPath: path, contents: Data("keep".utf8)))
        defer { unlink(path) }
        let server = LiveActivitySocketServer(socketPath: path)
        server.start { _ in nil }
        try? await Task.sleep(for: .milliseconds(100))
        server.stop()
        try? await Task.sleep(for: .milliseconds(50))
        #expect((try? String(contentsOfFile: path, encoding: .utf8)) == "keep")
    }

    @Test("Every descriptor is retired exactly once across repeated connect/disconnect cycles")
    func descriptorsRetiredExactlyOnce() async throws {
        let path = Self.temporarySocketPath()
        let retired = LockedBox<[Int32]>([])
        let server = LiveActivitySocketServer(socketPath: path)
        server.onDescriptorRetired = { descriptor in
            retired.mutate { $0.append(descriptor) }
        }
        server.start { _ in nil }
        await Self.waitForSocket(path)

        let message = try JSONEncoder().encode(
            LiveActivityMessage(command: .start, id: "cycle", title: "Cycle", icon: .build)
        ) + Data([10])
        for _ in 0 ..< 24 {
            let before = retired.value.count
            let reply = await Task.detached { Self.send(message, to: path) }.value
            #expect(reply?.contains("\"ok\":true") == true)
            // One retirement per connection: a double close would move the
            // count by two here.
            try await Self.waitUntil { retired.value.count == before + 1 }
        }

        let beforeStop = retired.value.count
        server.stop()
        // The listening socket's source retires once as well.
        try await Self.waitUntil { retired.value.count == beforeStop + 1 }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(retired.value.count == beforeStop + 1, "nothing retires twice")
        #expect(server.snapshotForTesting().clients.isEmpty)
        #expect(server.snapshotForTesting().serverFileDescriptor == -1)
    }

    @Test("A handler from a previous generation cannot answer or close a newer client")
    func staleHandlerCannotCrossGenerations() async throws {
        let path = Self.temporarySocketPath()
        let retired = LockedBox<[Int32]>([])
        let server = LiveActivitySocketServer(socketPath: path)
        server.onDescriptorRetired = { descriptor in
            retired.mutate { $0.append(descriptor) }
        }

        let gateA = HandlerGate()
        server.start { _ in
            await gateA.wait()
            return nil
        }
        await Self.waitForSocket(path)

        let message = try JSONEncoder().encode(
            LiveActivityMessage(command: .start, id: "a", title: "A", icon: .build)
        ) + Data([10])
        let replyA = Task.detached { Self.send(message, to: path) }
        try await Self.waitUntil { await gateA.enteredCount >= 1 }

        let snapshotA = server.snapshotForTesting()
        #expect(snapshotA.clients.count == 1)
        let clientA = try #require(snapshotA.clients.first)

        // Retire the whole first server generation while A's handler is stuck.
        server.stop()
        try await Self.waitUntil { retired.value.count == 2 }
        #expect(retired.value.contains(clientA))
        #expect(await replyA.value == nil, "A's connection was retired with its generation")

        // Restart with a different handler. A's descriptor number is now free,
        // and connecting B should reuse it.
        let gateB = HandlerGate()
        server.start { _ in
            await gateB.wait()
            return .init("b")
        }
        await Self.waitForSocket(path)

        let replyB = Task.detached { Self.send(message, to: path) }
        try await Self.waitUntil { await gateB.enteredCount >= 1 }
        let snapshotB = server.snapshotForTesting()
        #expect(snapshotB.clients.count == 1)
        let clientB = try #require(snapshotB.clients.first)
        // The OS usually reuses the retired descriptor number — the risky case
        // where a stale handler could touch the wrong client — but reuse is not
        // guaranteed. The generation and client-identity checks must hold
        // either way, and the assertions below pin exactly that.

        // Release the old handler while B is still waiting. It must not answer
        // or close B.
        await gateA.release()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(server.snapshotForTesting().clients.contains(clientB), "B survives A's completion")

        await gateB.release()
        let reply = await replyB.value
        #expect(reply?.contains("\"ok\":false") == true, "B gets its own generation's answer")
        #expect(reply?.contains("\"b\"") == true)
        #expect(reply?.contains("\"ok\":true") != true, "A's stale success never crosses generations")

        server.stop()
        try await Self.waitUntil { retired.value.count == 4 }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(retired.value.count == 4, "two generations retire exactly two descriptors each")
    }

    private static func waitUntil(_ condition: @escaping @Sendable () async -> Bool, timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        throw StaleHandlerTimeout()
    }

    private struct StaleHandlerTimeout: Error {}
}

/// A one-shot rendezvous for the stale-handler test: the handler blocks until
/// the test releases it, after optionally reporting that it entered.
actor HandlerGate {
    private var entered = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    var enteredCount: Int { entered }

    func wait() async {
        entered += 1
        await withCheckedContinuation { continuations.append($0) }
    }

    func release() {
        let pending = continuations
        continuations = []
        for continuation in pending { continuation.resume() }
    }
}

/// Minimal thread-safe box for values written from the server's queue.
final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}
