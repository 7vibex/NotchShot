import CryptoKit
import Darwin
import Foundation
import Security
import UniformTypeIdentifiers

public struct LocalSendPeer: Equatable, Sendable {
    public var host: String
    public var port: Int
    public var usesHTTPS: Bool
    public var trustedCertificateSHA256: String?

    public init(
        host: String,
        port: Int = 53_317,
        usesHTTPS: Bool = true,
        trustedCertificateSHA256: String? = nil
    ) {
        self.host = host
        self.port = port
        self.usesHTTPS = usesHTTPS
        self.trustedCertificateSHA256 = trustedCertificateSHA256
    }
}

public enum LocalNetworkHostPolicy {
    public static func isAllowed(_ rawHost: String) -> Bool {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty, !host.contains("/"), !host.contains("@") else { return false }
        if host == "localhost" || host.hasSuffix(".local") { return true }
        if host.contains(":") {
            return isAllowedIPv6(host)
        }
        guard let octets = ipv4Octets(host) else { return false }
        return octets[0] == 10
            || (octets[0] == 172 && (16 ... 31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
            || (octets[0] == 169 && octets[1] == 254)
            || octets[0] == 127
    }

    /// Exactly four numeric components, each `0...255`, with no empty, extra,
    /// or non-numeric components. Leading zeros are refused because a resolver
    /// may read `010` as octal, which would send the transfer somewhere other
    /// than the address that was validated.
    private static func ipv4Octets(_ host: String) -> [UInt8]? {
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return nil }
        var octets: [UInt8] = []
        octets.reserveCapacity(4)
        for component in components {
            guard !component.isEmpty,
                  component.count <= 3,
                  component.allSatisfy({ $0.isASCII && $0.isNumber }),
                  component.count == 1 || component.first != "0",
                  let value = UInt8(component) else { return nil }
            octets.append(value)
        }
        return octets
    }

    /// A real parser decides whether the text is an address at all; only the
    /// parsed bytes decide the range. Prefix matching on the text accepted
    /// malformed non-addresses that merely started like a local prefix.
    private static func isAllowedIPv6(_ host: String) -> Bool {
        var address = in6_addr()
        // A zone identifier is not part of an address a URL can carry; letting
        // `inet_pton` strip it would validate one string and fetch another.
        guard !host.contains("%"),
              host.utf8.count < Int(INET6_ADDRSTRLEN),
              host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
            return false
        }
        let bytes = withUnsafeBytes(of: address) { Array($0) }
        guard bytes.count == 16 else { return false }
        let isLoopback = bytes[0 ..< 15].allSatisfy { $0 == 0 } && bytes[15] == 1
        let isLinkLocal = bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80
        let isUniqueLocal = (bytes[0] & 0xFE) == 0xFC
        return isLoopback || isLinkLocal || isUniqueLocal
    }
}

public enum LocalSendError: LocalizedError, Equatable {
    case invalidPeer
    case unsafeFile(String)
    case certificateNeedsApproval(String)
    case certificateMismatch(expected: String, actual: String)
    case rejected(Int)
    case invalidResponse
    case noFilesAccepted

    public var errorDescription: String? {
        switch self {
        case .invalidPeer:
            "Enter a private-network IP address or a .local host and a port from 1 to 65535."
        case .unsafeFile(let name):
            "\(name) is not a current regular file that can be sent safely."
        case .certificateNeedsApproval(let fingerprint):
            "Verify this LocalSend certificate fingerprint on the receiving device, then approve it: \(fingerprint)"
        case .certificateMismatch(let expected, let actual):
            "The receiver certificate changed. Expected \(expected), received \(actual)."
        case .rejected(let status):
            "The LocalSend receiver rejected the transfer (HTTP \(status))."
        case .invalidResponse:
            "The LocalSend receiver returned an invalid response."
        case .noFilesAccepted:
            "The receiver did not accept any of the selected files."
        }
    }
}

public struct LocalSendProgress: Equatable, Sendable {
    public var completedFiles: Int
    public var totalFiles: Int
    public var currentFilename: String?
    /// Bytes URLSession reports as sent across every accepted file, when known.
    public var bytesSent: Int64?
    /// Sum of the accepted files' sizes.
    public var totalBytes: Int64?

    public init(
        completedFiles: Int,
        totalFiles: Int,
        currentFilename: String?,
        bytesSent: Int64? = nil,
        totalBytes: Int64? = nil
    ) {
        self.completedFiles = completedFiles
        self.totalFiles = totalFiles
        self.currentFilename = currentFilename
        self.bytesSent = bytesSent
        self.totalBytes = totalBytes
    }

    public var fraction: Double {
        guard totalFiles > 0 else { return 0 }
        return Double(completedFiles) / Double(totalFiles)
    }
}

/// A file chosen for LocalSend, pinned to the identity it had when it was
/// chosen. The device picker, the fingerprint prompt and the receiver's answer
/// all come before the upload, so a pathname replaced in between is refused
/// instead of sent.
public struct LocalSendSelection: Equatable, Sendable {
    public var url: URL
    var identity: ExternalFileIdentity

    /// Nil unless the item is a regular file within LocalSend's limit;
    /// symbolic links are refused.
    public init?(url: URL) {
        let source = url.standardizedFileURL
        guard let identity = SafeAssetFile.identity(
            at: source,
            maximumBytes: LocalSendClient.maximumFileBytes
        ) else { return nil }
        self.init(url: source, identity: identity)
    }

    /// A shelf item whose identity was recorded when it entered the shelf.
    init?(asset: CaptureAsset) {
        guard let identity = SafeAssetFile.selectionIdentity(of: asset),
              identity.size <= LocalSendClient.maximumFileBytes else { return nil }
        self.init(url: asset.url.standardizedFileURL, identity: identity)
    }

    init(url: URL, identity: ExternalFileIdentity) {
        self.url = url
        self.identity = identity
    }
}

public actor LocalSendClient {
    public static let shared = LocalSendClient()
    public static let maximumFileBytes: Int64 = 5 * 1_024 * 1_024 * 1_024
    /// A receiver answers these with a little JSON or nothing. A device that
    /// keeps sending must not fill memory with it.
    static let maximumResponseBytes = 1_024 * 1_024
    /// A receiver answers prepare-upload only once its user accepts.
    private static let prepareTimeout: TimeInterval = 300
    private static let snapshotDirectoryPrefix = "notchshot-localsend-"

    /// Whether a prepare-upload status accepted the transfer at all. LocalSend
    /// answers 204 No Content when the receiver declined it, which is the exact
    /// "accepted none" case and must never be reported as a completed send.
    nonisolated static func prepareAccepted(statusCode: Int) -> Bool {
        statusCode != 204
    }

    private struct DeviceInfo: Codable {
        var alias: String
        var version = "2.0"
        var deviceModel = "Mac"
        var deviceType = "desktop"
        var fingerprint: String
        var port: Int
        var transport: String
        var download = false

        enum CodingKeys: String, CodingKey {
            case alias, version, deviceModel, deviceType, fingerprint, port, download
            case transport = "protocol"
        }
    }

    private struct FileInfo: Codable {
        var id: String
        var fileName: String
        var size: Int64
        var fileType: String
        var sha256: String?
        var preview: String?
    }

    private struct PrepareRequest: Codable {
        var info: DeviceInfo
        var files: [String: FileInfo]
    }

    private struct PrepareResponse: Codable {
        var sessionId: String
        var files: [String: String]
    }

    struct PreparedFile: Sendable {
        var id: String
        /// Original filename for the wire metadata. The bytes come from the
        /// private snapshot, never from this name's path again.
        var fileName: String
        /// Immutable private copy of the exact file authorized here.
        var snapshotURL: URL
        var size: Int64
        var mimeType: String
    }

    @discardableResult
    public func send(
        files selections: [LocalSendSelection],
        to peer: LocalSendPeer,
        progress: @escaping @Sendable (LocalSendProgress) async -> Void
    ) async throws -> Int {
        // Everything that can refuse the send comes before the copy, which can
        // be up to 5 GB a file.
        let base = try Self.baseURL(for: peer)
        let sessionDelegate = LocalSendTrustDelegate(expectedFingerprint: peer.trustedCertificateSHA256)
        let session = URLSession(configuration: .ephemeral, delegate: sessionDelegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        if peer.usesHTTPS, peer.trustedCertificateSHA256 == nil,
           let fingerprint = await Self.untrustedFingerprint(at: base, session: session, delegate: sessionDelegate) {
            throw LocalSendError.certificateNeedsApproval(fingerprint)
        }
        try Task.checkCancellation()

        let prepared = try await prepareFiles(selections)
        guard !prepared.isEmpty else { throw LocalSendError.noFilesAccepted }
        // The snapshots are private copies; they leave with this call on every
        // path — success, thrown error, or cancellation.
        defer { Self.discardSnapshots(prepared) }

        // Set once the receiver has opened a session, until the last file is in.
        var openSessionID: String?
        do {
            let device = DeviceInfo(
                alias: Host.current().localizedName ?? "NotchShot Mac",
                fingerprint: UUID().uuidString,
                port: 0,
                transport: peer.usesHTTPS ? "https" : "http"
            )
            let requestBody = PrepareRequest(
                info: device,
                files: Dictionary(uniqueKeysWithValues: prepared.map { file in
                    (file.id, FileInfo(
                        id: file.id,
                        fileName: file.fileName,
                        size: file.size,
                        fileType: file.mimeType,
                        sha256: nil,
                        preview: nil
                    ))
                })
            )
            var prepareRequest = URLRequest(url: base.appendingPathComponent("api/localsend/v2/prepare-upload"))
            prepareRequest.httpMethod = "POST"
            prepareRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            prepareRequest.httpBody = try JSONEncoder().encode(requestBody)
            prepareRequest.timeoutInterval = Self.prepareTimeout
            let (data, response) = try await Self.boundedResponse(to: prepareRequest, in: session)
            guard let http = response as? HTTPURLResponse else { throw LocalSendError.invalidResponse }
            guard Self.prepareAccepted(statusCode: http.statusCode) else {
                throw LocalSendError.noFilesAccepted
            }
            guard (200 ..< 300).contains(http.statusCode) else { throw LocalSendError.rejected(http.statusCode) }
            let accepted = try JSONDecoder().decode(PrepareResponse.self, from: data)
            openSessionID = accepted.sessionId
            let acceptedFiles = prepared.filter { accepted.files[$0.id] != nil }
            guard !acceptedFiles.isEmpty else { throw LocalSendError.noFilesAccepted }

            let totalBytes = acceptedFiles.reduce(Int64(0)) { $0 + $1.size }
            var completedBytes: Int64 = 0
            for (index, file) in acceptedFiles.enumerated() {
                try Task.checkCancellation()
                await progress(LocalSendProgress(
                    completedFiles: index,
                    totalFiles: acceptedFiles.count,
                    currentFilename: file.fileName,
                    bytesSent: completedBytes,
                    totalBytes: totalBytes
                ))
                guard let token = accepted.files[file.id] else { continue }
                var components = URLComponents(
                    url: base.appendingPathComponent("api/localsend/v2/upload"),
                    resolvingAgainstBaseURL: false
                )
                components?.queryItems = [
                    URLQueryItem(name: "sessionId", value: accepted.sessionId),
                    URLQueryItem(name: "fileId", value: file.id),
                    URLQueryItem(name: "token", value: token),
                ]
                guard let uploadURL = components?.url else { throw LocalSendError.invalidResponse }
                var uploadRequest = URLRequest(url: uploadURL)
                uploadRequest.httpMethod = "POST"
                uploadRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                // Measured, not estimated: URLSession reports the body bytes it
                // has actually written for this file.
                let baseBytes = completedBytes
                let fileCount = acceptedFiles.count
                let filename = file.fileName
                let uploadProgress = LocalSendUploadProgress { sent in
                    Task {
                        await progress(LocalSendProgress(
                            completedFiles: index,
                            totalFiles: fileCount,
                            currentFilename: filename,
                            bytesSent: baseBytes + sent,
                            totalBytes: totalBytes
                        ))
                    }
                }
                let uploadResponse = try await uploadProgress.upload(
                    uploadRequest,
                    fromFile: file.snapshotURL,
                    in: session
                )
                guard let uploadHTTP = uploadResponse as? HTTPURLResponse,
                      (200 ..< 300).contains(uploadHTTP.statusCode) else {
                    throw LocalSendError.rejected((uploadResponse as? HTTPURLResponse)?.statusCode ?? 0)
                }
                completedBytes += file.size
            }
            openSessionID = nil
            await progress(LocalSendProgress(
                completedFiles: acceptedFiles.count,
                totalFiles: acceptedFiles.count,
                currentFilename: nil,
                bytesSent: totalBytes,
                totalBytes: totalBytes
            ))
            return acceptedFiles.count
        } catch {
            if let openSessionID {
                Self.cancelReceiverSession(openSessionID, at: base, peer: peer)
            }
            if peer.usesHTTPS, let actual = sessionDelegate.observedFingerprint {
                if let expected = peer.trustedCertificateSHA256,
                   LocalSendTrustDelegate.normalized(expected) != LocalSendTrustDelegate.normalized(actual) {
                    throw LocalSendError.certificateMismatch(expected: expected, actual: actual)
                }
                if peer.trustedCertificateSHA256 == nil {
                    throw LocalSendError.certificateNeedsApproval(actual)
                }
            }
            throw error
        }
    }

    nonisolated static func baseURL(for peer: LocalSendPeer) throws -> URL {
        guard LocalNetworkHostPolicy.isAllowed(peer.host), (1 ... 65_535).contains(peer.port) else {
            throw LocalSendError.invalidPeer
        }
        let host = peer.host.trimmingCharacters(in: .whitespacesAndNewlines)
        var components = URLComponents()
        components.scheme = peer.usesHTTPS ? "https" : "http"
        // URLComponents takes an IPv6 address only in its URL form.
        components.host = host.contains(":") ? "[\(host)]" : host
        components.port = peer.port
        guard let url = components.url else { throw LocalSendError.invalidPeer }
        return url
    }

    /// With no approved fingerprint a TLS send can only fail, so this asks for
    /// the certificate before copying anything. The handshake decides, whatever
    /// the receiver would make of the request. Nil falls through to the send,
    /// which reports its own error.
    private nonisolated static func untrustedFingerprint(
        at base: URL,
        session: URLSession,
        delegate: LocalSendTrustDelegate
    ) async -> String? {
        var request = URLRequest(url: base.appendingPathComponent("api/localsend/v2/info"))
        request.timeoutInterval = 5
        _ = try? await session.data(for: request)
        return delegate.observedFingerprint
    }

    /// `session.data(for:)` holds however much the peer sends.
    private nonisolated static func boundedResponse(
        to request: URLRequest,
        in session: URLSession
    ) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else { throw LocalSendError.invalidResponse }
            data.append(byte)
        }
        return (data, response)
    }

    /// A receiver still counting files answers later sends with 409 until its
    /// user clears it, so say the session is over. Best effort: the send's own
    /// session is about to be cancelled, and nothing waits on this one.
    private nonisolated static func cancelReceiverSession(_ sessionID: String, at base: URL, peer: LocalSendPeer) {
        var components = URLComponents(
            url: base.appendingPathComponent("api/localsend/v2/cancel"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "sessionId", value: sessionID)]
        guard let url = components?.url else { return }
        let fingerprint = peer.trustedCertificateSHA256
        Task.detached(priority: .utility) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 2
            let delegate = LocalSendTrustDelegate(expectedFingerprint: fingerprint)
            let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            _ = try? await boundedResponse(to: request, in: session)
        }
    }

    /// Copies each selected file into a private transfer snapshot before any
    /// file data goes out.
    ///
    /// The identity pinned at selection is re-checked through an `O_NOFOLLOW`
    /// descriptor during the copy, so a pathname replaced since then is
    /// refused, and the bytes uploaded are the snapshot's. The 5 GB per-file
    /// limit is enforced on both the selection and the copy. Runs off the actor
    /// so a long copy holds nothing else up, and stops between files on Cancel.
    func prepareFiles(_ selections: [LocalSendSelection]) async throws -> [PreparedFile] {
        let copy = Task.detached(priority: .userInitiated) {
            var prepared: [PreparedFile] = []
            do {
                for selection in selections.prefix(100) {
                    try Task.checkCancellation()
                    prepared.append(try Self.prepareFile(selection))
                }
            } catch {
                Self.discardSnapshots(prepared)
                throw error
            }
            return prepared
        }
        return try await withTaskCancellationHandler {
            try await copy.value
        } onCancel: {
            copy.cancel()
        }
    }

    /// Removes what a crash or force quit left behind mid-send. Old ones only,
    /// since another running copy of the app could be sending right now.
    public nonisolated static func removeStaleSnapshots(
        in temporary: URL = FileManager.default.temporaryDirectory,
        olderThan age: TimeInterval = 24 * 60 * 60
    ) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: temporary.path) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for name in names where name.hasPrefix(snapshotDirectoryPrefix) {
            let directory = temporary.appendingPathComponent(name, isDirectory: true)
            guard let modified = try? directory.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate, modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private nonisolated static func prepareFile(_ selection: LocalSendSelection) throws -> PreparedFile {
        let source = selection.url.standardizedFileURL
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(snapshotDirectoryPrefix)\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let snapshot = directory.appendingPathComponent(source.lastPathComponent)
            try SafeAssetFile.copyVerified(
                from: source,
                expectedIdentity: selection.identity,
                maximumBytes: Self.maximumFileBytes,
                to: snapshot
            )
            let measured = (try? snapshot.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
            guard let measured, measured >= 0, Int64(measured) <= Self.maximumFileBytes else {
                throw LocalSendError.unsafeFile(source.lastPathComponent)
            }
            let type = UTType(filenameExtension: source.pathExtension)
            return PreparedFile(
                id: UUID().uuidString,
                fileName: source.lastPathComponent,
                snapshotURL: snapshot,
                size: Int64(measured),
                mimeType: type?.preferredMIMEType ?? "application/octet-stream"
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            if error is LocalSendError { throw error }
            throw LocalSendError.unsafeFile(source.lastPathComponent)
        }
    }

    /// Removes the private snapshot directory for each prepared file. Called on
    /// success, error, and cancellation; safe to call more than once.
    nonisolated static func discardSnapshots(_ prepared: [PreparedFile]) {
        var removed = Set<String>()
        for file in prepared {
            let directory = file.snapshotURL.deletingLastPathComponent().standardizedFileURL
            guard removed.insert(directory.path).inserted else { continue }
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

/// Per-upload task delegate that forwards URLSession's sent-byte count, at
/// most ~10 times a second plus the final value, and stops a reply that runs
/// past `maximumResponseBytes`. The reply's body is not used, so it is counted
/// and dropped; only delegate callbacks can do that, which is why this runs the
/// task itself instead of `session.upload(for:fromFile:delegate:)`.
final class LocalSendUploadProgress: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var lastReport: TimeInterval = 0
    private var receivedBytes = 0
    private var replyTooLarge = false
    private var completion: CheckedContinuation<URLResponse, Error>?
    /// A task cancelled before it started can finish before anyone waits.
    private var finished: Result<URLResponse, Error>?
    private let report: @Sendable (Int64) -> Void

    init(report: @escaping @Sendable (Int64) -> Void) {
        self.report = report
    }

    /// Challenges and redirects this type does not handle still go to the
    /// session's delegate.
    func upload(_ request: URLRequest, fromFile file: URL, in session: URLSession) async throws -> URLResponse {
        let task = session.uploadTask(with: request, fromFile: file)
        task.delegate = self
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let early = lock.withLock { () -> Result<URLResponse, Error>? in
                    if finished == nil { completion = continuation }
                    return finished
                }
                if let early {
                    continuation.resume(with: early)
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let tooLarge = lock.withLock {
            receivedBytes += data.count
            replyTooLarge = replyTooLarge || receivedBytes > LocalSendClient.maximumResponseBytes
            return replyTooLarge
        }
        if tooLarge { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: Result<URLResponse, Error>
        if lock.withLock({ replyTooLarge }) {
            result = .failure(LocalSendError.invalidResponse)
        } else if let error {
            result = .failure(error)
        } else if let response = task.response {
            result = .success(response)
        } else {
            result = .failure(LocalSendError.invalidResponse)
        }
        let continuation = lock.withLock { () -> CheckedContinuation<URLResponse, Error>? in
            defer { completion = nil }
            if completion == nil { finished = result }
            return completion
        }
        continuation?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        let isFinal = totalBytesExpectedToSend > 0 && totalBytesSent >= totalBytesExpectedToSend
        lock.lock()
        let due = isFinal || now - lastReport >= 0.1
        if due { lastReport = now }
        lock.unlock()
        guard due else { return }
        report(totalBytesSent)
    }
}

final class LocalSendTrustDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let expectedFingerprint: String?
    private let lock = NSLock()
    private var storedFingerprint: String?

    init(expectedFingerprint: String?) {
        self.expectedFingerprint = expectedFingerprint.map(Self.normalized)
    }

    var observedFingerprint: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedFingerprint
    }

    static func normalized(_ fingerprint: String) -> String {
        fingerprint.uppercased().filter(\.isHexDigit)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificate = SecTrustCopyCertificateChain(trust).flatMap({ $0 as? [SecCertificate] })?.first else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let digest = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
        let fingerprint = digest.map { String(format: "%02X", $0) }.joined()
        lock.lock()
        storedFingerprint = fingerprint
        lock.unlock()
        guard expectedFingerprint == Self.normalized(fingerprint) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // The peer was validated as a private-network destination. Following a
        // redirect would let it move the upload and its bearer tokens to an
        // unrelated host after that check.
        completionHandler(nil)
    }
}
