import CryptoKit
import Foundation
import Security
import UniformTypeIdentifiers

/// Where share links upload to: any S3-compatible bucket the user owns —
/// AWS S3, Cloudflare R2, Backblaze B2, Wasabi, MinIO.
///
/// NotchShot has no backend and keeps it that way: a link exists only because
/// the user pointed the app at storage they already pay for. The secret key
/// never touches UserDefaults; it lives in the login Keychain.
public struct ShareLinkConfiguration: Codable, Equatable, Sendable {
    /// Service endpoint, e.g. `https://s3.eu-west-1.amazonaws.com` or
    /// `https://<account>.r2.cloudflarestorage.com`.
    public var endpoint = ""
    /// Signing region. R2 accepts `auto`.
    public var region = "auto"
    public var bucket = ""
    public var accessKeyID = ""
    /// Folder inside the bucket. Empty puts files at the bucket root.
    public var pathPrefix = "notchshot"
    /// Public address the bucket is served from (a custom domain, an R2
    /// `r2.dev` URL, a CDN). Empty means links point at the endpoint itself.
    public var publicBaseURL = ""
    /// `endpoint/bucket/key` instead of `bucket.endpoint/key`. Most
    /// S3-compatible services want path style; AWS accepts both.
    public var usesPathStyle = true
    /// Random file names, so a link can't be guessed from its neighbour and
    /// doesn't leak the original file name.
    public var randomizesNames = true

    public init() {}

    public var endpointURL: URL? {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    /// Enough to attempt an upload; the secret is checked separately.
    public var isComplete: Bool {
        endpointURL != nil && !bucket.isEmpty && !accessKeyID.isEmpty && !region.isEmpty
    }

    /// The object key for an upload.
    public func objectKey(for fileURL: URL, date: Date = Date(), randomID: String = ShareLinkConfiguration.randomID()) -> String {
        let ext = fileURL.pathExtension.lowercased()
        let name: String
        if randomizesNames {
            name = ext.isEmpty ? randomID : "\(randomID).\(ext)"
        } else {
            let base = fileURL.deletingPathExtension().lastPathComponent
            let safe = base.unicodeScalars.map { scalar -> Character in
                CharacterSet.alphanumerics.contains(scalar) || "-_.".unicodeScalars.contains(scalar) ? Character(scalar) : "-"
            }
            name = "\(randomID)-\(String(safe).prefix(80))" + (ext.isEmpty ? "" : ".\(ext)")
        }
        let prefix = pathPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return prefix.isEmpty ? name : "\(prefix)/\(name)"
    }

    /// The URL the PUT goes to.
    public func uploadURL(forKey key: String) -> URL? {
        guard let endpointURL, var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false),
              let host = components.host else { return nil }
        let encodedKey = S3Signer.encodePath(key)
        if usesPathStyle {
            components.percentEncodedPath = "/" + S3Signer.encodePath(bucket) + "/" + encodedKey
        } else {
            components.host = "\(bucket).\(host)"
            components.percentEncodedPath = "/" + encodedKey
        }
        return components.url
    }

    /// The link handed to the user.
    public func publicURL(forKey key: String) -> URL? {
        let base = publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.isEmpty, let baseURL = URL(string: base), baseURL.scheme == "https" {
            let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
            return URL(string: trimmed + "/" + S3Signer.encodePath(key))
        }
        return uploadURL(forKey: key)
    }

    public static func randomID(length: Int = 12) -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet[Int(generator.next(upperBound: UInt32(alphabet.count)))] })
    }
}

/// AWS Signature Version 4 for S3 requests. Pure, so it can be checked
/// against AWS's published test vector.
public enum S3Signer {
    public static let emptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    /// RFC 3986 encoding of each path segment, keeping the slashes.
    public static func encodePath(_ path: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: unreserved) ?? String($0) }
            .joined(separator: "/")
    }

    public static func amzDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    /// The `Authorization` header for a request whose headers already carry
    /// `x-amz-date` and `x-amz-content-sha256`. Every header passed is signed,
    /// plus `host`.
    public static func authorization(
        method: String,
        url: URL,
        headers: [String: String],
        payloadHash: String,
        accessKeyID: String,
        secretKey: String,
        region: String,
        service: String = "s3"
    ) -> String? {
        guard let host = url.host, let amzDate = headers.first(where: { $0.key.lowercased() == "x-amz-date" })?.value else {
            return nil
        }
        let dateStamp = String(amzDate.prefix(8))
        var canonicalHeaders: [String: String] = ["host": url.port.map { "\(host):\($0)" } ?? host]
        for (key, value) in headers {
            canonicalHeaders[key.lowercased()] = value.trimmingCharacters(in: .whitespaces)
        }
        let sortedKeys = canonicalHeaders.keys.sorted()
        let signedHeaders = sortedKeys.joined(separator: ";")
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
        let canonicalRequest = [
            method,
            path.isEmpty ? "/" : path,
            query,
            sortedKeys.map { "\($0):\(canonicalHeaders[$0]!)\n" }.joined(),
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            hex(SHA256.hash(data: Data(canonicalRequest.utf8))),
        ].joined(separator: "\n")

        var key = SymmetricKey(data: Data("AWS4\(secretKey)".utf8))
        for part in [dateStamp, region, service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        let signature = hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key))
        return "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
    }

    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 of a file, read in 1 MB chunks rather than all at once.
    static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }
}

/// The share-link secret in the login Keychain.
public enum ShareLinkKeychain {
    static let service = "com.notchshot.share-link"

    public static func secret(for accessKeyID: String) -> String? {
        guard !accessKeyID.isEmpty else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accessKeyID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func setSecret(_ secret: String, for accessKeyID: String) -> Bool {
        guard !accessKeyID.isEmpty else { return false }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accessKeyID,
        ]
        SecItemDelete(base as CFDictionary)
        guard !secret.isEmpty else { return true }
        var item = base
        item[kSecValueData as String] = Data(secret.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        item[kSecAttrLabel as String] = "NotchShot share links"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

/// Uploads one file and returns its public link.
public enum ShareLinkUploader {
    public static let maximumBytes: Int64 = 500 * 1_024 * 1_024

    public enum UploadError: LocalizedError {
        case notConfigured
        case missingSecret
        case tooLarge
        case unsafeFile
        case rejected(status: Int, message: String?)

        public var errorDescription: String? {
            switch self {
            case .notConfigured: "Set up share links in Settings → Sharing first."
            case .missingSecret: "The share-link secret key is missing. Add it in Settings → Sharing."
            case .tooLarge: "Share links are limited to files under 500 MB."
            case .unsafeFile: "That file changed or is no longer safely readable."
            case .rejected(let status, let message):
                "The storage service refused the upload (\(status))" + (message.map { ": \($0)" } ?? ".")
            }
        }
    }

    public static func upload(
        _ fileURL: URL,
        configuration: ShareLinkConfiguration,
        secret: String?,
        session: URLSession = .shared
    ) async throws -> URL {
        try await upload(
            fileURL,
            expectedIdentity: nil,
            configuration: configuration,
            secret: secret,
            transport: { request, snapshot in
                try await session.upload(for: request, fromFile: snapshot)
            }
        )
    }

    /// Shelf uploads retain the identity recorded when the asset was selected,
    /// including across the asynchronous wait before upload begins.
    public static func upload(
        _ asset: CaptureAsset,
        configuration: ShareLinkConfiguration,
        secret: String?,
        session: URLSession = .shared
    ) async throws -> URL {
        guard let identity = asset.externalFileIdentity else {
            throw UploadError.unsafeFile
        }
        return try await upload(
            asset.url,
            expectedIdentity: identity,
            configuration: configuration,
            secret: secret,
            transport: { request, snapshot in
                try await session.upload(for: request, fromFile: snapshot)
            }
        )
    }

    /// Capture a legacy owned file's identity synchronously at selection,
    /// before a caller enqueues asynchronous upload work. The asset overload
    /// never supplies missing authority after suspension.
    static func assetForSelection(_ asset: CaptureAsset) throws -> CaptureAsset {
        guard SafeAssetFile.isCurrentAndSafe(asset) else { throw UploadError.unsafeFile }
        guard asset.externalFileIdentity == nil else { return asset }
        guard asset.ownership != .externalReference,
              let identity = SafeAssetFile.identity(
                at: asset.url,
                maximumBytes: SafeAssetFile.maximumOwnedBytes
              ) else { throw UploadError.unsafeFile }
        var selected = asset
        selected.externalFileIdentity = identity
        return selected
    }

    /// A per-call transport lets tests inspect the exact file handed to the
    /// network without network access, shared overrides, or Keychain state.
    typealias Transport = @Sendable (URLRequest, URL) async throws -> (Data, URLResponse)

    static func upload(
        _ fileURL: URL,
        expectedIdentity: ExternalFileIdentity?,
        configuration: ShareLinkConfiguration,
        secret: String?,
        transport: Transport
    ) async throws -> URL {
        guard configuration.isComplete else { throw UploadError.notConfigured }
        guard let secret, !secret.isEmpty else { throw UploadError.missingSecret }
        try Task.checkCancellation()
        let preparation = Task.detached(priority: .userInitiated) {
            try prepareSnapshot(fileURL, expectedIdentity: expectedIdentity)
        }
        let prepared = try await withTaskCancellationHandler {
            try await preparation.value
        } onCancel: {
            preparation.cancel()
        }
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        try Task.checkCancellation()

        let key = configuration.objectKey(for: fileURL)
        guard let uploadURL = configuration.uploadURL(forKey: key),
              let publicURL = configuration.publicURL(forKey: key) else { throw UploadError.notConfigured }

        let payloadHash = prepared.payloadHash
        let contentType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        var headers = [
            "x-amz-date": S3Signer.amzDate(Date()),
            "x-amz-content-sha256": payloadHash,
            "content-type": contentType,
        ]
        guard let authorization = S3Signer.authorization(
            method: "PUT",
            url: uploadURL,
            headers: headers,
            payloadHash: payloadHash,
            accessKeyID: configuration.accessKeyID,
            secretKey: secret,
            region: configuration.region
        ) else { throw UploadError.notConfigured }
        headers["authorization"] = authorization
        headers["content-length"] = String(prepared.size)

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.timeoutInterval = 120
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }

        try Task.checkCancellation()
        let (data, response) = try await transport(request, prepared.snapshot)
        try Task.checkCancellation()
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw UploadError.rejected(status: status, message: errorCode(in: data))
        }
        return publicURL
    }

    private struct PreparedUpload: Sendable {
        var directory: URL
        var snapshot: URL
        var size: Int64
        var payloadHash: String
    }

    private static func prepareSnapshot(
        _ source: URL,
        expectedIdentity: ExternalFileIdentity?
    ) throws -> PreparedUpload {
        try Task.checkCancellation()
        guard let current = SafeAssetFile.identity(at: source, maximumBytes: Int64.max) else {
            throw UploadError.unsafeFile
        }
        guard current.size <= maximumBytes else { throw UploadError.tooLarge }
        guard expectedIdentity == nil || expectedIdentity == current else {
            throw UploadError.unsafeFile
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-share-link-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let snapshot = directory.appendingPathComponent("payload")
            try SafeAssetFile.copyVerified(
                from: source,
                expectedIdentity: expectedIdentity ?? current,
                maximumBytes: maximumBytes,
                to: snapshot
            )
            try Task.checkCancellation()
            guard let copied = SafeAssetFile.identity(at: snapshot, maximumBytes: maximumBytes),
                  copied.size == current.size,
                  SafeAssetFile.identity(at: source, maximumBytes: maximumBytes) == current else {
                throw UploadError.unsafeFile
            }
            // Only this private copy is hashed and uploaded. Its measured size
            // also supplies Content-Length, so all three describe the same bytes.
            return PreparedUpload(
                directory: directory,
                snapshot: snapshot,
                size: copied.size,
                payloadHash: try S3Signer.sha256(ofFileAt: snapshot)
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// The `<Code>` from an S3 XML error body, which says more than the status.
    static func errorCode(in data: Data) -> String? {
        guard let text = String(data: data.prefix(4_096), encoding: .utf8),
              let start = text.range(of: "<Code>"),
              let end = text.range(of: "</Code>", range: start.upperBound..<text.endIndex) else { return nil }
        return String(text[start.upperBound..<end.lowerBound])
    }
}
