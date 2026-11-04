import AppKit
import Foundation
import Observation
import SystemConfiguration

public enum CrewlineLinkState: Equatable, Sendable {
    /// The integration is switched off in Settings.
    case off
    /// No Crewline server is running on this Mac.
    case notRunning
    /// Crewline is running but NotchShot has not been paired with it yet.
    case needsPairing
    case connecting
    case connected
    case failed(String)

    public var title: String {
        switch self {
        case .off: "Off"
        case .notRunning: "Crewline isn't running"
        case .needsPairing: "Not connected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .failed(let message): message
        }
    }
}

/// Mirrors Crewline's live runs, pending approvals, open questions and
/// provider limits into NotchShot, and sends the user's answers back.
///
/// Everything goes through Crewline's own RPC surface as a paired device, the
/// same way its iPhone app talks to it, so NotchShot needs no access to
/// Crewline's database or transcripts.
@MainActor
@Observable
public final class CrewlineMonitor {
    public static let shared = CrewlineMonitor()

    static let requestedScopes = ["workspace:read", "runs:control", "workspace:write"]

    public private(set) var state: CrewlineLinkState = .off
    public private(set) var workspace = CrewlineWorkspace()
    /// Pause, resume or stop commands sent and not yet answered, by run.
    public private(set) var pendingControls: [String: AgentRunCommand] = [:]
    /// The open question per run ID, fetched for runs in `awaiting_input`.
    public private(set) var questions: [String: AgentInteraction] = [:]
    public private(set) var usageAccounts: [CrewlineUsageAccount] = []
    public private(set) var isPairing = false
    public private(set) var lastError: String?
    /// Interactions answered locally whose server echo has not arrived yet,
    /// so a stale refresh cannot bring the card back for a moment.
    private var answeredInteractionIDs: Set<String> = []
    private var approvalFirstSeen: [String: Date] = [:]

    public var onChange: (() -> Void)?

    private var supervisor: Task<Void, Never>?
    private var connection: CrewlineConnection?
    private var connectedPort: Int?
    private var refreshTask: Task<Void, Never>?
    /// An event that arrived while a refresh was already under way, whose
    /// bootstrap may predate it. A run blocked on a new approval sends nothing
    /// more, so dropping that event could leave its card missing indefinitely.
    private var refreshAgainAfter: Duration?
    private var lastNoisyRefresh = Date.distantPast
    private var generation = 0

    public init() {}

    private var credentialStored = false
    @ObservationIgnored private var credentialLookupStarted = false
    /// Bumped by every save and delete so a lookup that started earlier can't
    /// overwrite the newer answer.
    @ObservationIgnored private var credentialRevision = 0

    /// Whether a pairing is stored, as last read. A Keychain read can wait on
    /// securityd or on an access prompt until the user answers, so it never
    /// happens here: the first read starts a lookup and observers hear the answer.
    public var hasCredential: Bool {
        if !credentialLookupStarted {
            credentialLookupStarted = true
            let revision = credentialRevision
            Task { [weak self] in
                let stored = await Self.keychain { CrewlineCredentialStore.load() != nil }
                self?.noteCredential(stored, ifStillAt: revision)
            }
        }
        return credentialStored
    }

    /// Every Keychain call runs here, in order, so a read queued after a delete
    /// sees the delete.
    private nonisolated static let keychainQueue = DispatchQueue(
        label: "com.notchshot.crewline.keychain",
        qos: .userInitiated
    )

    private nonisolated static func keychain<Value: Sendable>(
        _ work: @escaping @Sendable () -> Value
    ) async -> Value {
        await withCheckedContinuation { continuation in
            keychainQueue.async { continuation.resume(returning: work()) }
        }
    }

    private func noteCredential(_ stored: Bool, ifStillAt revision: Int) {
        guard revision == credentialRevision else { return }
        credentialLookupStarted = true
        credentialStored = stored
    }

    private func credentialWritten(stored: Bool) {
        credentialRevision += 1
        noteCredential(stored, ifStillAt: credentialRevision)
    }

    private func forgetCredential() {
        credentialWritten(stored: false)
        Self.keychainQueue.async { CrewlineCredentialStore.delete() }
    }

    public var activities: [AIActivitySnapshot] {
        guard state == .connected else { return [] }
        return CrewlineActivityMapper.activities(from: workspace, questions: questions)
    }

    public var interactions: [AgentInteraction] {
        guard state == .connected else { return [] }
        let approvals = CrewlineActivityMapper.approvalInteractions(
            from: workspace,
            firstSeen: approvalFirstSeen
        )
        return (approvals + questions.values)
            .filter { !answeredInteractionIDs.contains($0.id) }
            .sorted { $0.receivedAt < $1.receivedAt }
    }

    // MARK: Lifecycle

    public func start() {
        guard supervisor == nil else { return }
        generation += 1
        let generation = generation
        state = .connecting
        supervisor = Task { [weak self] in
            await self?.supervise(generation: generation)
        }
    }

    public func stop() {
        generation += 1
        supervisor?.cancel()
        supervisor = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshAgainAfter = nil
        let connection = connection
        self.connection = nil
        connectedPort = nil
        Task { await connection?.close() }
        workspace = CrewlineWorkspace()
        questions = [:]
        usageAccounts = []
        answeredInteractionIDs = []
        approvalFirstSeen = [:]
        setState(.off)
    }

    /// Keeps one connection alive while Crewline runs: waits for the server,
    /// connects with the stored device token, and starts over whenever the
    /// socket drops.
    private func supervise(generation: Int) async {
        while !Task.isCancelled, generation == self.generation {
            let port = await Task.detached(priority: .utility) {
                CrewlineLocalHost.running()?.port()
            }.value
            guard generation == self.generation else { return }
            guard let port else {
                clearLiveData()
                setState(.notRunning)
                try? await Task.sleep(for: .seconds(5))
                continue
            }
            let revision = credentialRevision
            let stored = await Self.keychain { CrewlineCredentialStore.load() }
            guard generation == self.generation else { return }
            noteCredential(stored != nil, ifStillAt: revision)
            guard let credential = stored else {
                clearLiveData()
                setState(.needsPairing)
                try? await Task.sleep(for: .seconds(5))
                continue
            }

            setState(.connecting)
            let closed = await runConnection(port: port, credential: credential, generation: generation)
            guard generation == self.generation else { return }
            clearLiveData()
            if closed.invalidatesCredential {
                forgetCredential()
                lastError = "Crewline revoked NotchShot's access. Connect again to restore it."
                setState(.needsPairing)
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    /// Runs until the socket closes and reports why.
    private func runConnection(
        port: Int,
        credential: CrewlineCredential,
        generation: Int
    ) async -> CrewlineConnectionError {
        let connection = CrewlineConnection(port: port, token: credential.token)
        let (closedStream, closedContinuation) = AsyncStream<CrewlineConnectionError>.makeStream()
        await connection.open { error in
            closedContinuation.yield(error)
            closedContinuation.finish()
        }
        // stop() may have run during the wait above, and it can't close what
        // it hasn't been given.
        guard generation == self.generation else {
            await connection.close()
            return .closed
        }
        self.connection = connection
        connectedPort = port
        defer {
            if self.connection === connection {
                self.connection = nil
                connectedPort = nil
            }
        }

        do {
            try await refreshWorkspace(on: connection)
        } catch let error as CrewlineConnectionError {
            await connection.close()
            if generation == self.generation, !error.invalidatesCredential {
                setState(.failed(error.localizedDescription))
            }
            return error
        } catch {
            await connection.close()
            return .closed
        }
        lastError = nil
        setState(.connected)

        let watchers = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self?.watch("runs.subscribeActive", on: connection) }
                group.addTask { await self?.watch("approvals.subscribe", on: connection) }
                group.addTask { await self?.pollUsage(on: connection) }
            }
        }
        defer { watchers.cancel() }

        for await reason in closedStream { return reason }
        return .closed
    }

    private func watch(_ method: String, on connection: CrewlineConnection) async {
        var retryDelay = Self.minimumResubscribeSeconds
        var isResubscribing = false
        while !Task.isCancelled {
            // Fails once the socket has closed, and supervise handles that.
            guard let stream = try? await connection.subscribe(method) else { return }
            // Whatever happened while no stream was open is only in a bootstrap.
            if isResubscribing { scheduleRefresh(after: .milliseconds(150)) }
            var delivered = false
            for await item in stream {
                guard !Task.isCancelled else { return }
                delivered = true
                handleStreamItem(item, from: method)
            }
            // The server ended this stream, maybe with the socket still up.
            // A server that keeps refusing it costs a bootstrap each time, so
            // those retries back off.
            retryDelay = delivered
                ? Self.minimumResubscribeSeconds
                : min(retryDelay * 2, Self.maximumResubscribeSeconds)
            isResubscribing = true
            try? await Task.sleep(for: .seconds(retryDelay))
        }
    }

    private static let minimumResubscribeSeconds = 3
    private static let maximumResubscribeSeconds = 60

    private func pollUsage(on connection: CrewlineConnection) async {
        while !Task.isCancelled {
            if let data = try? await connection.request("usage.limits.remote"),
               let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) {
                let accounts = CrewlineParser.usageAccounts(from: object)
                if accounts != usageAccounts {
                    usageAccounts = accounts
                    onChange?()
                }
            }
            try? await Task.sleep(for: .seconds(90))
        }
    }

    // MARK: Refresh

    private static let noisyEventTypes: Set<String> = [
        "text.delta", "reasoning.delta", "tool.output.delta", "usage.tokens", "diff.updated",
    ]

    private func handleStreamItem(_ item: CrewlineStreamItem, from method: String) {
        if item.type == "input.requested" || item.type == "input.resolved",
           let runID = item.runID {
            questions[runID] = nil
        }

        if Self.noisyEventTypes.contains(item.type) {
            // Token streams arrive many times a second; the island only needs
            // the latest line every few seconds.
            guard Date().timeIntervalSince(lastNoisyRefresh) > 8 else { return }
            lastNoisyRefresh = Date()
        }
        scheduleRefresh(after: method == "approvals.subscribe" ? .milliseconds(150) : .milliseconds(450))
    }

    private func scheduleRefresh(after delay: Duration) {
        guard let connection else { return }
        guard refreshTask == nil else {
            refreshAgainAfter = min(refreshAgainAfter ?? delay, delay)
            return
        }
        let generation = generation
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            // The request below covers everything up to here; only what
            // arrives after it can be missing from the reply.
            self?.refreshAgainAfter = nil
            try? await self?.refreshWorkspace(on: connection)
            guard let self, generation == self.generation else { return }
            self.refreshTask = nil
            if let again = self.refreshAgainAfter {
                self.refreshAgainAfter = nil
                self.scheduleRefresh(after: again)
            }
        }
    }

    private func refreshWorkspace(on connection: CrewlineConnection) async throws {
        let data = try await connection.request("workspace.bootstrap")
        // A bootstrap runs to megabytes and comes up to twice a second during
        // a busy run. Decoding and comparing it stay off the main actor.
        let current = workspace
        let (updated, isUnchanged) = try await Task.detached(priority: .userInitiated) {
            () throws -> (CrewlineWorkspace, Bool) in
            let object = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
            let updated = CrewlineParser.workspace(from: object)
            return (updated, updated == current)
        }.value
        guard self.connection === connection else { throw CrewlineConnectionError.closed }

        let waitingRuns = Set(updated.runs.filter { $0.status == .awaitingInput }.map(\.id))
        var nextQuestions = questions.filter { waitingRuns.contains($0.key) }
        for runID in waitingRuns where nextQuestions[runID] == nil {
            if let question = try? await fetchQuestion(runID: runID, on: connection) {
                nextQuestions[runID] = question
            }
        }
        guard self.connection === connection else { throw CrewlineConnectionError.closed }

        let liveIDs = Set(updated.approvals.map(\.id)).union(nextQuestions.values.map(\.id))
        answeredInteractionIDs.formIntersection(liveIDs)
        let seenAt = Date()
        approvalFirstSeen = Dictionary(
            updated.approvals.map { ($0.id, approvalFirstSeen[$0.id] ?? seenAt) },
            uniquingKeysWith: { first, _ in first }
        )

        guard !isUnchanged || nextQuestions != questions else { return }
        workspace = updated
        questions = nextQuestions
        onChange?()
    }

    private func fetchQuestion(runID: String, on connection: CrewlineConnection) async throws -> AgentInteraction? {
        let data = try await connection.request("runs.get", payload: [
            "runId": runID,
            "includeEvents": true,
            "recentTurns": 1,
        ])
        return try await Task.detached(priority: .userInitiated) { () throws -> AgentInteraction? in
            let object = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
            return CrewlineParser.pendingQuestion(inRunEvents: object, runID: runID)
        }.value
    }

    private func clearLiveData() {
        guard !workspace.runs.isEmpty || !questions.isEmpty || !usageAccounts.isEmpty else { return }
        workspace = CrewlineWorkspace()
        questions = [:]
        usageAccounts = []
        answeredInteractionIDs = []
        approvalFirstSeen = [:]
        onChange?()
    }

    private func setState(_ newState: CrewlineLinkState) {
        guard state != newState else { return }
        state = newState
        onChange?()
    }

    // MARK: Pairing

    /// Pairs with the Crewline running on this Mac. The root token in
    /// Crewline's private home is read once, used only to ask Crewline for a
    /// pairing code with exactly the scopes NotchShot needs, and dropped.
    public func pairWithLocalCrewline() async {
        guard !isPairing else { return }
        isPairing = true
        defer { isPairing = false }
        let local = await Task.detached(priority: .userInitiated) { () -> (port: Int, rootToken: String?)? in
            guard let host = CrewlineLocalHost.running(), let port = host.port() else { return nil }
            return (port, host.rootToken())
        }.value
        guard let local else {
            lastError = "Open Crewline first, then connect."
            onChange?()
            return
        }
        let port = local.port
        guard let rootToken = local.rootToken else {
            lastError = "NotchShot couldn't read Crewline's local token. Paste a pairing code instead."
            onChange?()
            return
        }

        let admin = CrewlineConnection(port: port, token: rootToken)
        await admin.open { _ in }
        defer { Task { await admin.close() } }
        do {
            let data = try await admin.request("remote.startPairing", payload: ["scopes": Self.requestedScopes])
            guard let offer = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let code = offer["code"] as? String
            else { throw CrewlineConnectionError.badResponse }
            await completePairing(port: port, code: code)
        } catch {
            lastError = error.localizedDescription
            onChange?()
        }
    }

    /// Pairs with a code or `crewline://pair?...` link the user copied from
    /// Crewline's Remote settings.
    public func pair(code rawCode: String) async {
        guard !isPairing else { return }
        isPairing = true
        defer { isPairing = false }
        let port = await Task.detached(priority: .userInitiated) {
            CrewlineLocalHost.running()?.port()
        }.value
        guard let port else {
            lastError = "Open Crewline first, then connect."
            onChange?()
            return
        }
        await completePairing(port: port, code: Self.pairingCode(from: rawCode))
    }

    private func completePairing(port: Int, code: String) async {
        do {
            let device = try await CrewlineHTTP.pair(
                port: port,
                code: code,
                // Not Host.current(), which can wait on name resolution.
                deviceName: "NotchShot on \(SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "this Mac")",
                scopes: Self.requestedScopes
            )
            let credential = CrewlineCredential(
                deviceID: device.id,
                token: device.token,
                scopes: device.scopes,
                pairedAt: Date()
            )
            let saved = await Self.keychain { CrewlineCredentialStore.save(credential) }
            guard saved else {
                lastError = "NotchShot couldn't save the pairing to the Keychain."
                onChange?()
                return
            }
            credentialWritten(stored: true)
            lastError = nil
            restart()
        } catch {
            lastError = error.localizedDescription
            onChange?()
        }
    }

    /// Forgets this Mac's pairing. The device stays listed in Crewline until
    /// the user revokes it there.
    public func unpair() {
        forgetCredential()
        restart()
    }

    private func restart() {
        guard supervisor != nil else { return }
        stop()
        start()
    }

    /// Accepts a bare code or a `crewline://pair?code=…` link.
    static func pairingCode(from input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: trimmed),
           let code = components.queryItems?.first(where: { $0.name == "code" })?.value {
            return code
        }
        return trimmed
    }

    // MARK: Actions

    public func respond(to interaction: AgentInteraction, with response: AgentInteractionResponse) {
        guard let connection else { return }
        let runID = runID(for: interaction)
        guard let runID else { return }

        let method: String
        let payload: [String: any Sendable]
        switch (interaction.kind, response) {
        case (.approval, .allowOnce), (.approval, .allowForSession), (.approval, .deny):
            let decision = switch response {
            case .allowForSession: "allow_session"
            case .deny: "deny"
            default: "allow_once"
            }
            method = "runs.respondApproval"
            payload = ["runId": runID, "approvalId": interaction.id, "decision": decision]
        case (.question(let form), .answer(let answers)):
            guard let encoded = AgentAnswerEncoder.encode(answers, for: form) else { return }
            method = "runs.respondInput"
            payload = [
                "runId": runID,
                "requestId": interaction.id,
                "answers": CrewlineSendableJSON(AgentAnswerEncoder.jsonObject(encoded)),
            ]
        default:
            return
        }

        answeredInteractionIDs.insert(interaction.id)
        onChange?()
        Task { [weak self] in
            do {
                _ = try await connection.request(method, payload: payload)
                self?.scheduleRefresh(after: .milliseconds(200))
            } catch {
                self?.answeredInteractionIDs.remove(interaction.id)
                self?.lastError = error.localizedDescription
                self?.onChange?()
            }
        }
    }

    /// Pauses, resumes or stops a run, as Crewline's own run controls do.
    /// The command shows as pending until Crewline answers.
    public func control(runID: String, _ command: AgentRunCommand) {
        guard let connection, pendingControls[runID] == nil else { return }
        let method = switch command {
        case .pause: "runs.pause"
        case .resume: "runs.resume"
        case .stop: "runs.stop"
        }
        pendingControls[runID] = command
        onChange?()
        Task { [weak self] in
            do {
                _ = try await connection.request(method, payload: ["runId": runID])
                self?.scheduleRefresh(after: .milliseconds(200))
            } catch {
                self?.lastError = error.localizedDescription
            }
            self?.pendingControls[runID] = nil
            self?.onChange?()
        }
    }

    /// Uploads files and queues them, with an optional note, as the next turn
    /// of a run. The run keeps its own permission mode.
    public func sendFollowUp(runID: String, note: String, files: [AgentAttachment]) async throws {
        guard let connection, let port = connectedPort else { throw CrewlineConnectionError.notRunning }
        guard let credential = await Self.keychain({ CrewlineCredentialStore.load() }) else {
            throw CrewlineConnectionError.notRunning
        }
        guard let run = workspace.run(runID) else {
            throw CrewlineConnectionError.server(code: "not_found", message: "That run is no longer in Crewline.")
        }

        var attachments: [any Sendable] = []
        for file in files.prefix(8) {
            let attachment = try await CrewlineHTTP.upload(
                port: port,
                token: credential.token,
                fileURL: file.url,
                expectedIdentity: file.identity,
                mimeType: Self.mimeType(for: file.url)
            )
            attachments.append(CrewlineSendableJSON(attachment as [String: Any]))
        }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = trimmed.isEmpty
            ? (files.count == 1 ? "Here's a screenshot." : "Here are some screenshots.")
            : trimmed
        _ = try await connection.request("runs.queueFollowUp", payload: [
            "runId": run.id,
            "prompt": prompt,
            "runtimeMode": run.runtimeMode ?? "approval-required",
            "attachments": CrewlineSendableJSON(attachments as [Any]),
            "idempotencyKey": UUID().uuidString,
        ])
        scheduleRefresh(after: .milliseconds(300))
    }

    /// Brings Crewline forward on the run. Crewline handles
    /// `crewline://run/<id>`; an older build that does not still comes to the
    /// front.
    public func openRun(_ runID: String?) {
        guard let appURL = AgentIconCatalog.applicationURL(for: .crewline) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let runID,
           let encoded = runID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "crewline://run/\(encoded)") {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration)
        } else {
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        }
    }

    private func runID(for interaction: AgentInteraction) -> String? {
        switch interaction.kind {
        case .approval:
            workspace.approvals.first { $0.id == interaction.id }?.runID
        case .question:
            questions.first { $0.value.id == interaction.id }?.key
        }
    }

    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "heic": "image/heic"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "pdf": "application/pdf"
        case "mp4": "video/mp4"
        case "mov": "video/quicktime"
        case "txt", "md": "text/plain"
        default: "application/octet-stream"
        }
    }
}

/// Carries an already-JSON-shaped Foundation value across the connection
/// actor. It is immutable once built and only ever read by
/// `JSONSerialization`.
struct CrewlineSendableJSON: @unchecked Sendable {
    let value: Any
    init(_ value: Any) { self.value = value }
}
