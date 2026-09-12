import Foundation
import UniformTypeIdentifiers

public enum URLCaptureAction: String, Sendable, Equatable {
    case defaultBehavior
    case copy
    case save
    case annotate
}

public enum OCRClipboardFormat: String, Sendable, Equatable {
    case text
    case markdown
    case tsv
}

public struct URLCaptureCommand: Sendable, Equatable {
    public var intent: CaptureIntent
    /// Main display is 1; remaining displays are ordered left-to-right, then top-to-bottom.
    public var displayNumber: Int?
    public var presetID: String?
    public var action: URLCaptureAction
}

public enum NotchShotURLCommand: Sendable, Equatable {
    case capture(URLCaptureCommand)
    case recordArea
    case ocrClipboard(OCRClipboardFormat)
    case openLatest
    case pinFile(URL)

    /// Custom URL schemes have no trustworthy caller identity. Commands that
    /// can read or create user data therefore need a foreground confirmation
    /// when they arrive through `application(_:open:)`. App Intents are a
    /// separate, system-authorized entry point and do not consult this policy.
    public var requiresExternalURLConsent: Bool {
        switch self {
        case .capture, .recordArea, .ocrClipboard, .openLatest, .pinFile: true
        }
    }

    public var externalURLConsentDescription: String {
        switch self {
        case .capture(let command):
            let destination = switch command.action {
            case .copy: " and copy it to the clipboard"
            case .save: " and save it"
            case .annotate: " and open it for annotation"
            case .defaultBehavior: " using your current destination setting"
            }
            return "Another app or webpage requested a screen capture\(destination)."
        case .recordArea:
            return "Another app or webpage requested a screen recording."
        case .ocrClipboard:
            return "Another app or webpage requested access to read and recognize the current clipboard image."
        case .pinFile(let url):
            let displayPath = Self.abbreviatedPath(for: url)
            let kind = Self.fileKindDescription(for: url)
            let resolved = url.resolvingSymlinksInPath()
            let resolutionNote = resolved.standardizedFileURL.path != url.standardizedFileURL.path
                ? "\nIt resolves to:\n\(Self.abbreviatedPath(for: resolved))"
                : ""
            return "Another app or webpage requested permission to pin “\(url.lastPathComponent)” (\(kind)) from:\n\(displayPath)\(resolutionNote)\n\nOnly a regular file under 500 MB can be pinned, and it will appear in the shelf as a reference without copying its contents."
        case .openLatest:
            return "Another app or webpage requested permission to open the latest capture."
        }
    }

    private static func abbreviatedPath(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private static func fileKindDescription(for url: URL) -> String {
        guard let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey]),
              let type = values.contentType else {
            return "file"
        }
        if type.conforms(to: .image) { return "image" }
        if type.conforms(to: .movie) { return "movie" }
        if type.conforms(to: .pdf) { return "PDF" }
        return type.localizedDescription ?? "file"
    }
}

public enum NotchShotURLRouterError: LocalizedError, Equatable {
    case invalidScheme
    case credentialsNotAllowed
    case fragmentNotAllowed
    case malformedRoute
    case unsupportedRoute
    case unsupportedParameter(String)
    case duplicateParameter(String)
    case invalidParameter(String)
    case requestTooLong

    public var errorDescription: String? {
        switch self {
        case .invalidScheme: "Only notchshot:// links are accepted"
        case .credentialsNotAllowed: "Automation links cannot contain credentials"
        case .fragmentNotAllowed: "Automation links cannot contain fragments"
        case .malformedRoute: "That NotchShot automation link is malformed"
        case .unsupportedRoute: "That NotchShot automation action is not supported"
        case .unsupportedParameter(let name): "Unsupported automation parameter: \(name)"
        case .duplicateParameter(let name): "Automation parameter appears more than once: \(name)"
        case .invalidParameter(let name): "Invalid automation parameter: \(name)"
        case .requestTooLong: "That automation link is too long"
        }
    }
}

public enum NotchShotURLRouter {
    public static let maximumURLLength = 2_048
    private static let presetIDs: Set<String> = [
        "standard", "github-issue", "app-store", "documentation", "social-post", "bug-report",
    ]

    public static func parse(_ url: URL) throws -> NotchShotURLCommand {
        guard url.absoluteString.utf8.count <= maximumURLLength else {
            throw NotchShotURLRouterError.requestTooLong
        }
        guard url.scheme?.lowercased() == "notchshot" else {
            throw NotchShotURLRouterError.invalidScheme
        }
        guard url.user == nil, url.password == nil else {
            throw NotchShotURLRouterError.credentialsNotAllowed
        }
        guard url.fragment == nil else {
            throw NotchShotURLRouterError.fragmentNotAllowed
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(), !host.isEmpty else {
            throw NotchShotURLRouterError.malformedRoute
        }

        let query = try queryDictionary(components.queryItems ?? [])
        let path = components.path.split(separator: "/").map(String.init)

        switch host {
        case "capture":
            guard path.count == 1 else { throw NotchShotURLRouterError.malformedRoute }
            return .capture(try captureCommand(mode: path[0], query: query))

        case "record":
            try rejectUnknown(query, allowed: [])
            guard path == ["area"] else { throw NotchShotURLRouterError.unsupportedRoute }
            return .recordArea

        case "ocr":
            try rejectUnknown(query, allowed: ["source", "format"])
            guard path.isEmpty else { throw NotchShotURLRouterError.malformedRoute }
            guard query["source"] == "clipboard" else {
                throw NotchShotURLRouterError.invalidParameter("source")
            }
            let format = OCRClipboardFormat(rawValue: query["format"] ?? "text")
            guard let format else { throw NotchShotURLRouterError.invalidParameter("format") }
            return .ocrClipboard(format)

        case "open":
            try rejectUnknown(query, allowed: [])
            guard path == ["latest"] else { throw NotchShotURLRouterError.unsupportedRoute }
            return .openLatest

        case "pin":
            try rejectUnknown(query, allowed: ["file"])
            guard path.isEmpty, let value = query["file"] else {
                throw NotchShotURLRouterError.invalidParameter("file")
            }
            return .pinFile(try canonicalFileURL(value))

        default:
            throw NotchShotURLRouterError.unsupportedRoute
        }
    }

    private static func captureCommand(
        mode: String,
        query: [String: String]
    ) throws -> URLCaptureCommand {
        try rejectUnknown(query, allowed: ["action", "display", "preset"])
        let intent: CaptureIntent = switch mode {
        case "area": .area
        case "window": .window
        case "display": .display
        case "previous": .previousArea
        case "scrolling": .scrolling
        default: throw NotchShotURLRouterError.unsupportedRoute
        }

        let action: URLCaptureAction
        if let rawAction = query["action"] {
            guard let parsed = URLCaptureAction(rawValue: rawAction), parsed != .defaultBehavior else {
                throw NotchShotURLRouterError.invalidParameter("action")
            }
            action = parsed
        } else {
            action = .defaultBehavior
        }

        let displayNumber: Int?
        if let rawDisplay = query["display"] {
            guard intent == .display,
                  let number = Int(rawDisplay), (1 ... 16).contains(number) else {
                throw NotchShotURLRouterError.invalidParameter("display")
            }
            displayNumber = number
        } else {
            displayNumber = nil
        }

        let presetID = query["preset"]
        if let presetID, !presetIDs.contains(presetID) {
            throw NotchShotURLRouterError.invalidParameter("preset")
        }

        return URLCaptureCommand(
            intent: intent,
            displayNumber: displayNumber,
            presetID: presetID,
            action: action
        )
    }

    private static func queryDictionary(
        _ items: [URLQueryItem]
    ) throws -> [String: String] {
        var result: [String: String] = [:]
        for item in items {
            let name = item.name.lowercased()
            guard result[name] == nil else {
                throw NotchShotURLRouterError.duplicateParameter(name)
            }
            guard let value = item.value, !value.isEmpty else {
                throw NotchShotURLRouterError.invalidParameter(name)
            }
            result[name] = value
        }
        return result
    }

    private static func rejectUnknown(
        _ query: [String: String],
        allowed: Set<String>
    ) throws {
        if let unknown = query.keys.first(where: { !allowed.contains($0) }) {
            throw NotchShotURLRouterError.unsupportedParameter(unknown)
        }
    }

    private static func canonicalFileURL(_ value: String) throws -> URL {
        let candidate: URL
        if let parsed = URL(string: value), parsed.isFileURL {
            candidate = parsed
        } else {
            guard value.hasPrefix("/") else {
                throw NotchShotURLRouterError.invalidParameter("file")
            }
            candidate = URL(fileURLWithPath: value)
        }
        guard candidate.host == nil || candidate.host?.isEmpty == true
                || candidate.host?.lowercased() == "localhost" else {
            throw NotchShotURLRouterError.invalidParameter("file")
        }
        let standardized = candidate.standardizedFileURL
        // Resolving the link before the consent dialog is built showed the user
        // the *target's* name, so a link named after something harmless could
        // stand in for any readable file elsewhere and the alert would never
        // mention the indirection. The rest of the pin path already refuses
        // anything that is not a regular file, so refusing the link outright
        // costs nothing a direct path cannot express.
        var info = stat()
        if lstat(standardized.path, &info) == 0,
           info.st_mode & S_IFMT == S_IFLNK {
            throw NotchShotURLRouterError.invalidParameter("file")
        }
        return standardized
    }
}

/// A small local abuse boundary for links opened by browsers or other apps.
/// It limits both immediate double-fires and sustained bursts.
@MainActor
public final class URLCommandRateLimiter {
    private let minimumInterval: TimeInterval
    private let window: TimeInterval
    private let maximumInWindow: Int
    private var accepted: [Date] = []

    public init(
        minimumInterval: TimeInterval = 0.35,
        window: TimeInterval = 10,
        maximumInWindow: Int = 5
    ) {
        self.minimumInterval = minimumInterval
        self.window = window
        self.maximumInWindow = maximumInWindow
    }

    public func accept(now: Date = Date()) -> Bool {
        accepted.removeAll { now.timeIntervalSince($0) > window }
        guard accepted.count < maximumInWindow else { return false }
        guard accepted.last.map({ now.timeIntervalSince($0) >= minimumInterval }) ?? true else {
            return false
        }
        accepted.append(now)
        return true
    }
}
