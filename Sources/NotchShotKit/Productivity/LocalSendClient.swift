import CryptoKit
import Darwin
import Foundation
import Security
import UniformTypeIdentifiers

public struct LocalSendPeer: Equatable, Sendable {
    public var alias: String
    public var host: String
    public var port: Int
    public var usesHTTPS: Bool
    public var trustedCertificateSHA256: String?

    public init(
        alias: String,
        host: String,
        port: Int = 53_317,
        usesHTTPS: Bool = true,
        trustedCertificateSHA256: String? = nil
    ) {
        self.alias = alias
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

public actor LocalSendClient {
    public static let shared = LocalSendClient()
    public static let maximumFileBytes: Int64 = 5 * 1_024 * 1_024 * 1_024

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
        files urls: [URL],
        to peer: LocalSendPeer,
        progress: @escaping @Sendable (LocalSendProgress) async -> Void
    ) async throws -> Int {
        let prepared = try prepareFiles(urls)
        guard !prepared.isEmpty else { throw LocalSendError.noFilesAccepted }
        // The snapshots are private copies; they leave with this call on every
        // path — success, thrown error, or cancellation.
        defer { Self.discardSnapshots(prepared) }
        let sessionDelegate = LocalSendTrustDelegate(expectedFingerprint: peer.trustedCertificateSHA256)
        let session = URLSession(configuration: .ephemeral, delegate: sessionDelegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        do {
            let base = try baseURL(for: peer)
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
            let (data, response) = try await session.data(for: prepareRequest)
            guard let http = response as? HTTPURLResponse else { throw LocalSendError.invalidResponse }
            guard Self.prepareAccepted(statusCode: http.statusCode) else {
                throw LocalSendError.noFilesAccepted
            }
            guard (200 ..< 300).contains(http.statusCode) else { throw LocalSendError.rejected(http.statusCode) }
            let accepted = try JSONDecoder().decode(PrepareResponse.self, from: data)
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
                let (_, uploadResponse) = try await session.upload(
                    for: uploadRequest,
                    fromFile: file.snapshotURL,
                    delegate: uploadProgress
                )
                guard let uploadHTTP = uploadResponse as? HTTPURLResponse,
                      (200 ..< 300).contains(uploadHTTP.statusCode) else {
                    throw LocalSendError.rejected((uploadResponse as? HTTPURLResponse)?.statusCode ?? 0)
                }
                completedBytes += file.size
            }
            await progress(LocalSendProgress(
                completedFiles: acceptedFiles.count,
                totalFiles: acceptedFiles.count,
                currentFilename: nil,
                bytesSent: totalBytes,
                totalBytes: totalBytes
            ))
            return acceptedFiles.count
        } catch {
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

    private func baseURL(for peer: LocalSendPeer) throws -> URL {
        guard LocalNetworkHostPolicy.isAllowed(peer.host), (1 ... 65_535).contains(peer.port) else {
            throw LocalSendError.invalidPeer
        }
        var components = URLComponents()
        components.scheme = peer.usesHTTPS ? "https" : "http"
        components.host = peer.host.trimmingCharacters(in: .whitespacesAndNewlines)
        components.port = peer.port
        guard let url = components.url else { throw LocalSendError.invalidPeer }
        return url
    }

    /// Validates each source and copies it into a private transfer snapshot
    /// before any network work begins.
    ///
    /// The identity captured here is re-checked through an `O_NOFOLLOW`
    /// descriptor during the copy, so replacing the pathname afterwards cannot
    /// change the bytes that will be uploaded. The 5 GB per-file limit is
    /// enforced on both the validation and the copy.
    func prepareFiles(_ urls: [URL]) throws -> [PreparedFile] {
        var prepared: [PreparedFile] = []
        do {
            for url in urls.prefix(100) {
                prepared.append(try prepareFile(url))
            }
        } catch {
            Self.discardSnapshots(prepared)
            throw error
        }
        return prepared
    }

    private func prepareFile(_ url: URL) throws -> PreparedFile {
        let source = url.standardizedFileURL
        // `lstat`-based: regular file only, symlinks refused, size bounded.
        guard let identity = SafeAssetFile.identity(
            at: source,
            maximumBytes: Self.maximumFileBytes
        ) else {
            throw LocalSendError.unsafeFile(source.lastPathComponent)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-localsend-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let snapshot = directory.appendingPathComponent(source.lastPathComponent)
            try SafeAssetFile.copyVerified(
                from: source,
                expectedIdentity: identity,
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
/// most ~10 times a second plus the final value.
final class LocalSendUploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var lastReport: TimeInterval = 0
    private let report: @Sendable (Int64) -> Void

    init(report: @escaping @Sendable (Int64) -> Void) {
        self.report = report
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
