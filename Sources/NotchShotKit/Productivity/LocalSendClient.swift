import CryptoKit
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
            return host == "::1"
                || host.hasPrefix("fe8") || host.hasPrefix("fe9")
                || host.hasPrefix("fea") || host.hasPrefix("feb")
                || host.hasPrefix("fc") || host.hasPrefix("fd")
        }
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10
            || (parts[0] == 172 && (16 ... 31).contains(parts[1]))
            || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 169 && parts[1] == 254)
            || parts[0] == 127
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

    private struct PreparedFile: Sendable {
        var id: String
        var url: URL
        var size: Int64
        var mimeType: String
    }

    public func send(
        files urls: [URL],
        to peer: LocalSendPeer,
        progress: @escaping @Sendable (LocalSendProgress) async -> Void
    ) async throws {
        let prepared = try prepareFiles(urls)
        guard !prepared.isEmpty else { throw LocalSendError.noFilesAccepted }
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
                        fileName: file.url.lastPathComponent,
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
            if http.statusCode == 204 { return }
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
                    currentFilename: file.url.lastPathComponent,
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
                let filename = file.url.lastPathComponent
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
                    fromFile: file.url,
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

    private func prepareFiles(_ urls: [URL]) throws -> [PreparedFile] {
        try urls.prefix(100).map { url in
            let standardized = url.standardizedFileURL
            let values = try standardized.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ])
            let size = Int64(values.fileSize ?? -1)
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  size >= 0,
                  size <= Self.maximumFileBytes else {
                throw LocalSendError.unsafeFile(standardized.lastPathComponent)
            }
            let type = UTType(filenameExtension: standardized.pathExtension)
            return PreparedFile(
                id: UUID().uuidString,
                url: standardized,
                size: size,
                mimeType: type?.preferredMIMEType ?? "application/octet-stream"
            )
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
